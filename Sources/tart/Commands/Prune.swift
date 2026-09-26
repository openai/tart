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

  @Flag(help: "Show entries that would be removed and their estimated allocated size without making changes.")
  var dryRun: Bool = false

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
    if gc && !dryRun {
      try VMStorageOCI().gc()
    }

    // Build a list of prunable storages that we're going to prune based on user's request
    let prunableStorages: [PrunableStorage]

    switch entries {
    case "caches":
      prunableStorages = [try VMStorageOCI(readOnly: dryRun), try IPSWCache(readOnly: dryRun)]
    case "vms":
      prunableStorages = [try VMStorageLocal(readOnly: dryRun)]
    default:
      throw ValidationError("unsupported --entries value, please specify either \"caches\" or \"vms\"")
    }

    let operation = PruningOperation(dryRun: dryRun)

    // Clean up cache entries based on last accessed date
    if let olderThan = olderThan {
      let olderThanInterval = Int(exactly: olderThan)!.days.timeInterval
      let olderThanDate = Date() - olderThanInterval

      try Prune.pruneOlderThan(prunableStorages: prunableStorages, olderThanDate: olderThanDate, operation: operation)
    }

    // Clean up cache entries based on imposed cache size limit and entry's last accessed date
    if let spaceBudget = spaceBudget {
      try Prune.pruneSpaceBudget(prunableStorages: prunableStorages, spaceBudgetBytes: UInt64(spaceBudget) * 1024 * 1024 * 1024, operation: operation)
    }

    if dryRun {
      print("Dry run: no changes will be made.")
      for entry in operation.entries {
        let size = ByteCountFormatter.string(fromByteCount: entry.allocatedSizeBytes, countStyle: .file)
        print("Would remove \(entry.url.path) (\(size))")
      }
      if operation.entries.isEmpty {
        print("No matching entries.")
      }
      let total = ByteCountFormatter.string(fromByteCount: operation.estimatedReclaimedBytes, countStyle: .file)
      print("Total estimated space reclaimed: \(total) (allocated size).")
      if gc {
        print("Garbage collection (--gc) is not included in this preview.")
      }
      // Not gated on --space-budget: Root's temporary-directory cleanup is
      // skipped for every dry run, so an age-only preview can omit content
      // that a real prune releases and then collects too.
      if try prunableStorages.compactMap({ $0 as? VMStorageOCI }).contains(where: { try !$0.temporaryContentDigests().isEmpty }) {
        print("Temporary image files still protect cached data in this preview. Cleanup before a real prune may release them, so a real run can remove more than is listed here.")
      }
    }
  }

  /// Shares selection between deletion and preview, including across criteria.
  /// Only previews remember removals; real runs always observe the live storage.
  final class PruningOperation {
    let dryRun: Bool
    private(set) var removedURLs = Swift.Set<URL>()
    private(set) var entries: [(url: URL, allocatedSizeBytes: Int64)] = []
    private(set) var estimatedReclaimedBytes: Int64 = 0

    init(dryRun: Bool = false) {
      self.dryRun = dryRun
    }

    func remove(_ prunable: Prunable, allocatedSizeBytes: Int? = nil) throws {
      if dryRun {
        // Only the per-entry size is recorded here. updateEstimate() is the
        // sole writer of estimatedReclaimedBytes, since summing these would
        // double-count content that merely changes owner.
        let size = Int64(try allocatedSizeBytes ?? prunable.allocatedSizeBytes())
        removedURLs.insert(prunable.url)
        entries.append((prunable.url, size))
      } else {
        try prunable.delete()
      }
    }

    func allocatedSize(of prunables: [Prunable]) throws -> Int64? {
      guard dryRun else {
        return nil
      }
      return try prunables.reduce(0) { try $0 + Int64($1.allocatedSizeBytes()) }
    }

    func updateEstimate(from initialSize: Int64?, to prunables: [Prunable], previousEstimate: Int64) throws {
      guard let initialSize, let remainingSize = try allocatedSize(of: prunables) else {
        return
      }
      // Shared content can move between owners without being freed. Measure
      // the change in total usage instead of summing successive ownerships.
      estimatedReclaimedBytes = previousEstimate + initialSize - remainingSize
    }
  }

  static func pruneOlderThan(prunableStorages: [PrunableStorage], olderThanDate: Date,
                             operation: PruningOperation = PruningOperation()) throws {
    let prunables: [Prunable] = try prunableStorages.flatMap { try $0.prunables(simulatingRemovalOf: operation.removedURLs) }
    let matchingPrunables = try prunables.filter { try $0.accessDate() <= olderThanDate }
    guard !matchingPrunables.isEmpty else {
      return
    }
    let initialSize = try operation.allocatedSize(of: prunables)
    let previousEstimate = operation.estimatedReclaimedBytes

    try matchingPrunables.forEach { try operation.remove($0) }
    if operation.dryRun {
      let remaining = try prunableStorages.flatMap { try $0.prunables(simulatingRemovalOf: operation.removedURLs) }
      try operation.updateEstimate(from: initialSize, to: remaining, previousEstimate: previousEstimate)
    }
  }

  static func pruneSpaceBudget(prunableStorages: [PrunableStorage], spaceBudgetBytes: UInt64,
                               operation: PruningOperation = PruningOperation()) throws {
    var initialSize: Int64?
    let previousEstimate = operation.estimatedReclaimedBytes
    while true {
      let prunables: [Prunable] = try prunableStorages
        .flatMap { try $0.prunables(simulatingRemovalOf: operation.removedURLs) }
        .sorted { try $0.accessDate() > $1.accessDate() }
      if initialSize == nil {
        initialSize = try operation.allocatedSize(of: prunables)
      }

      var remainingBudgetBytes = spaceBudgetBytes
      var prunableToDelete: (prunable: Prunable, allocatedSizeBytes: Int)?

      for prunable in prunables {
        let prunableSizeBytes = UInt64(try prunable.allocatedSizeBytes())

        if prunableSizeBytes <= remainingBudgetBytes {
          // Don't mark for deletion as there is budget available
          remainingBudgetBytes -= prunableSizeBytes
        } else {
          prunableToDelete = (prunable, Int(prunableSizeBytes))
          break
        }
      }

      guard let prunableToDelete else {
        try operation.updateEstimate(from: initialSize, to: prunables, previousEstimate: previousEstimate)
        return
      }

      // Deleting one cached stacked image can change which remaining image
      // owns shared immutable content. Rebuild before choosing another.
      try operation.remove(prunableToDelete.prunable, allocatedSizeBytes: prunableToDelete.allocatedSizeBytes)
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
