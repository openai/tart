import ArgumentParser
import Dispatch
import OpenTelemetryApi
import SwiftUI
import SwiftDate

struct Prune: AsyncParsableCommand {
  static var configuration = CommandConfiguration(abstract: "Prune OCI and IPSW caches or local VMs")

  @Option(help: ArgumentHelp("Entries to remove: \"caches\" targets OCI and IPSW caches and \"vms\" targets local VMs."), completion: .list(["caches", "vms"]))
  var entries: String = "caches"

  @Option(help: ArgumentHelp("Remove entries that were last accessed more than n days ago",
                             discussion: "For example, --older-than=7 will remove entries that weren't accessed by Tart in the last 7 days.",
                             valueName: "n"))
  var olderThan: UInt?

  @Option(help: .hidden)
  var cacheBudget: UInt?

  @Option(help: ArgumentHelp("Remove the least recently used entries that do not fit the specified space size budget n, expressed in gigabytes",
                             discussion: "For example, --space-budget=50 will effectively shrink all entries to a total size of 50 gigabytes.",
                             valueName: "n"))
  var spaceBudget: UInt?

  @Flag(help: .hidden)
  var gc: Bool = false

  mutating func validate() throws {
    // --cache-budget deprecation logic
    if let cacheBudget = cacheBudget {
      fputs("--cache-budget is deprecated, please use --space-budget\n", stderr)

      if spaceBudget != nil {
        throw ValidationError("--cache-budget is deprecated, please use --space-budget")
      }

      spaceBudget = cacheBudget
    }

    if olderThan == nil && spaceBudget == nil && !gc {
      throw ValidationError("at least one pruning criteria must be specified")
    }
  }

  func run() async throws {
    if gc {
      try VMStorageOCI().gc()
    }

    // Build a list of prunable storages that we're going to prune based on user's request
    let prunableStorages: [PrunableStorage]

    switch entries {
    case "caches":
      prunableStorages = [try VMStorageOCI(), try IPSWCache()]
    case "vms":
      prunableStorages = [try VMStorageLocal()]
    default:
      throw ValidationError("unsupported --entries value, please specify either \"caches\" or \"vms\"")
    }

    // Clean up cache entries based on last accessed date
    if let olderThan = olderThan {
      let olderThanInterval = Int(exactly: olderThan)!.days.timeInterval
      let olderThanDate = Date() - olderThanInterval

      try Prune.pruneOlderThan(prunableStorages: prunableStorages, olderThanDate: olderThanDate)
    }

    // Clean up cache entries based on imposed cache size limit and entry's last accessed date
    if let spaceBudget = spaceBudget {
      try Prune.pruneSpaceBudget(prunableStorages: prunableStorages, spaceBudgetBytes: UInt64(spaceBudget) * 1024 * 1024 * 1024)
    }
  }

  static func pruneOlderThan(prunableStorages: [PrunableStorage], olderThanDate: Date) throws {
    while let prunable = try prunableStorages
      .flatMap({ try $0.prunables() })
      .first(where: { try $0.accessDate() <= olderThanDate }) {
      // Deletion may remove derived prunables (for example shared content),
      // so never continue from a stale snapshot.
      try prunable.delete()
    }
  }

  static func pruneSpaceBudget(prunableStorages: [PrunableStorage], spaceBudgetBytes: UInt64) throws {
    while true {
      let prunables: [Prunable] = try prunableStorages
        .flatMap { try $0.prunables() }
        .sorted { try $0.accessDate() > $1.accessDate() }

      var remainingBudgetBytes = spaceBudgetBytes
      var prunableToDelete: Prunable?

      for prunable in prunables {
        let prunableSizeBytes = UInt64(try prunable.allocatedSizeBytes())

        if prunableSizeBytes <= remainingBudgetBytes {
          // Don't mark for deletion as there is budget available
          remainingBudgetBytes -= prunableSizeBytes
        } else {
          prunableToDelete = prunable
          break
        }
      }

      guard let prunableToDelete else {
        return
      }

      // Deleting one cached stacked image can change which remaining image
      // owns shared immutable content. Rebuild before choosing another.
      try prunableToDelete.delete()
    }
  }

  static func reclaimIfNeeded(_ requiredBytes: UInt64, _ initiator: Prunable? = nil) throws {
    if ProcessInfo.processInfo.environment.keys.contains("TART_NO_AUTO_PRUNE") {
      return
    }

    OpenTelemetry.instance.contextProvider.activeSpan?.setAttribute(
      key: "prune.required-bytes",
      value: .int(Int(requiredBytes))
    )

    // Figure out how much disk space is available
    let attrs = try Config().tartCacheDir.resourceValues(forKeys: [
      .volumeAvailableCapacityKey,
      .volumeAvailableCapacityForImportantUsageKey
    ])
    let volumeAvailableCapacityCalculated = max(
      UInt64(attrs.volumeAvailableCapacity!),
      UInt64(attrs.volumeAvailableCapacityForImportantUsage!)
    )

    OpenTelemetry.instance.contextProvider.activeSpan?.setAttributes([
      "prune.volume-available-capacity-bytes": .int(Int(attrs.volumeAvailableCapacity!)),
      "prune.volume-available-capacity-for-important-usage-bytes": .int(Int(attrs.volumeAvailableCapacityForImportantUsage!)),
      "prune.volume-available-capacity-calculated": .int(Int(volumeAvailableCapacityCalculated)),
    ])

    if volumeAvailableCapacityCalculated <= 0 {
      OpenTelemetry.instance.contextProvider.activeSpan?.addEvent(name: "Zero volume capacity reported")

      return
    }

    // Now that we know how much free space is left,
    // check if we even need to reclaim anything
    if requiredBytes < volumeAvailableCapacityCalculated {
      return
    }

    try Prune.reclaimIfPossible(requiredBytes - volumeAvailableCapacityCalculated, initiator)
  }

  static func reclaimIfPossible(_ reclaimBytes: UInt64, _ initiator: Prunable? = nil) throws {
    let span = OTel.shared.tracer.spanBuilder(spanName: "prune").startSpan()
    defer { span.end() }

    let prunableStorages: [PrunableStorage] = [try VMStorageOCI(), try IPSWCache()]
    let prunables = {
      try prunableStorages
        .flatMap { try $0.prunables() }
        .sorted { try $0.accessDate() < $1.accessDate() }
    }

    // Does it even make sense to start?
    let initialPrunables = try prunables()
    let initialCacheUsedBytes = try initialPrunables.map { try $0.allocatedSizeBytes() }.reduce(0, +)
    guard let reclaimBytes = Int(exactly: reclaimBytes), initialCacheUsedBytes >= reclaimBytes else {
      return
    }

    let targetCacheUsedBytes = initialCacheUsedBytes - reclaimBytes
    var currentCacheUsedBytes = initialCacheUsedBytes
    let initiatorPath = initiator.map {
      $0.url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    while currentCacheUsedBytes > targetCacheUsedBytes {
      // Deleting one cached stacked image can transfer ownership of shared
      // immutable content to another record without reclaiming those bytes.
      // Rebuild the candidates after every deletion so automatic pruning
      // measures the cache that remains rather than a stale ownership snapshot.
      guard let prunable = try prunables().first(where: {
        $0.url.resolvingSymlinksInPath().standardizedFileURL.path != initiatorPath
      }) else {
        break
      }

      let allocatedSizeBytes = try prunable.allocatedSizeBytes()

      OpenTelemetry.instance.contextProvider.activeSpan?
        .addEvent(name: "Pruned \(allocatedSizeBytes) bytes for \(prunable.url.path)")

      try prunable.delete()
      currentCacheUsedBytes = try prunables().map { try $0.allocatedSizeBytes() }.reduce(0, +)
    }

    OpenTelemetry.instance.contextProvider.activeSpan?
      .addEvent(name: "Reclaimed \(initialCacheUsedBytes - currentCacheUsedBytes) bytes")
  }
}
