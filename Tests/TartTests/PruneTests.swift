import ArgumentParser
import Foundation
import XCTest
@testable import tart

final class PruneTests: XCTestCase {
  func testDryRunStillRequiresPruningCriteria() throws {
    XCTAssertThrowsError(try Prune.parseAsRoot(["--dry-run"]))
    let command = try XCTUnwrap(try Prune.parseAsRoot(["--older-than", "7", "--dry-run"]) as? Prune)
    XCTAssertTrue(command.dryRun)
    XCTAssertEqual(command.olderThan, 7)
  }

  func testOlderThanDryRunMatchesDeletionOrderAndIncludesBoundary() throws {
    let storage = MockStorage()
    let preview = Prune.PruningOperation(dryRun: true)
    let cutoff = Date(timeIntervalSince1970: 2)

    try Prune.pruneOlderThan(prunableStorages: [storage], olderThanDate: cutoff, operation: preview)

    XCTAssertEqual(preview.entries.map(\.url), [storage.entries[0].url, storage.entries[2].url])
    XCTAssertEqual(preview.estimatedReclaimedBytes, 7)
    XCTAssertTrue(storage.deletedURLs.isEmpty)

    try Prune.pruneOlderThan(prunableStorages: [storage], olderThanDate: cutoff)

    XCTAssertEqual(storage.deletedURLs, preview.entries.map(\.url))
  }

  func testSpaceBudgetDryRunTerminatesAndMatchesDeletionOrder() throws {
    // Rebuilding without excluding simulated deletions throws after at most
    // entry-count + 1 scans, so a regression fails instead of hanging XCTest.
    for budget: UInt64 in [0, 3, 5, 7, 9, 16, 20] {
      let storage = MockStorage()
      let preview = Prune.PruningOperation(dryRun: true)

      try Prune.pruneSpaceBudget(prunableStorages: [storage], spaceBudgetBytes: budget, operation: preview)

      XCTAssertTrue(storage.deletedURLs.isEmpty)
      XCTAssertEqual(storage.scans, preview.entries.count + 1)
      if budget == 5 {
        // The newest entry is too large, but the middle one fits. Removing
        // oldest-first or selecting all overflow entries at once is incorrect.
        XCTAssertEqual(preview.entries.map(\.url), [storage.entries[1].url, storage.entries[0].url])
        XCTAssertEqual(preview.estimatedReclaimedBytes, 12)
      }

      storage.scans = 0
      try Prune.pruneSpaceBudget(prunableStorages: [storage], spaceBudgetBytes: budget)

      XCTAssertEqual(storage.deletedURLs, preview.entries.map(\.url), "budget: \(budget)")
    }
  }

  func testCombinedCriteriaShareSimulatedRemovalsAcrossStorages() throws {
    let first = MockStorage()
    let second = MockStorage(entries: [MockPrunable(name: "other", accessed: 0, allocatedBytes: 2)])
    first.scanLimit = 10
    second.scanLimit = 10
    let preview = Prune.PruningOperation(dryRun: true)
    let cutoff = Date(timeIntervalSince1970: 1)

    try Prune.pruneOlderThan(prunableStorages: [first, second], olderThanDate: cutoff, operation: preview)
    try Prune.pruneSpaceBudget(prunableStorages: [first, second], spaceBudgetBytes: 5, operation: preview)

    XCTAssertEqual(preview.entries.map(\.url), [first.entries[0].url, second.entries[0].url, first.entries[1].url])
    XCTAssertEqual(preview.estimatedReclaimedBytes, 14)
    XCTAssertTrue(first.deletedURLs.isEmpty)
    XCTAssertTrue(second.deletedURLs.isEmpty)

    try Prune.pruneOlderThan(prunableStorages: [first, second], olderThanDate: cutoff)
    try Prune.pruneSpaceBudget(prunableStorages: [first, second], spaceBudgetBytes: 5)

    XCTAssertEqual(first.deletedURLs, [first.entries[0].url, first.entries[1].url])
    XCTAssertEqual(second.deletedURLs, [second.entries[0].url])
  }

  func testEmptyStorage() throws {
    let storage = MockStorage(entries: [])
    let preview = Prune.PruningOperation(dryRun: true)
    try Prune.pruneOlderThan(prunableStorages: [storage], olderThanDate: Date(), operation: preview)
    storage.scans = 0
    try Prune.pruneSpaceBudget(prunableStorages: [storage], spaceBudgetBytes: 0, operation: preview)
    XCTAssertTrue(preview.entries.isEmpty)
    XCTAssertEqual(preview.estimatedReclaimedBytes, 0)
  }

  func testPreviewPropagatesSizeFailureWithoutDeleting() throws {
    let storage = MockStorage()
    storage.entries[0].sizeFails = true
    let preview = Prune.PruningOperation(dryRun: true)

    XCTAssertThrowsError(try Prune.pruneOlderThan(
      prunableStorages: [storage], olderThanDate: Date(), operation: preview
    ))
    XCTAssertTrue(storage.deletedURLs.isEmpty)
    XCTAssertTrue(preview.entries.isEmpty)
    XCTAssertEqual(preview.estimatedReclaimedBytes, 0)

    // A real age-based prune must not introduce size reads or new failures.
    try Prune.pruneOlderThan(prunableStorages: [storage], olderThanDate: Date())
    XCTAssertEqual(storage.deletedURLs, storage.entries.map(\.url))
  }

  func testDeletionFailureStopsPruning() throws {
    let storage = MockStorage()
    storage.entries[1].deleteFails = true

    XCTAssertThrowsError(try Prune.pruneSpaceBudget(prunableStorages: [storage], spaceBudgetBytes: 0))
    XCTAssertTrue(storage.deletedURLs.isEmpty)
    XCTAssertEqual(storage.scans, 1)
  }

  func testSpaceBudgetPreviewReusesSelectedSizes() throws {
    let storage = MockStorage()
    let preview = Prune.PruningOperation(dryRun: true)
    try Prune.pruneSpaceBudget(prunableStorages: [storage], spaceBudgetBytes: 0, operation: preview)

    // One read for the initial total and one for selection, with no extra
    // read when recording the selected entry. The final storage is empty.
    XCTAssertEqual(storage.entries.map(\.sizeReads), [2, 2, 2])
    XCTAssertEqual(preview.estimatedReclaimedBytes, 16)
  }

  func testDryRunDoesNotCreateMissingHomeOrStorageDirectories() async throws {
    try await withTemporaryTartHome { home in
      for entries in ["caches", "vms"] {
        let command = try Prune.parseAsRoot(["--entries", entries, "--space-budget", "0", "--dry-run"]) as! Prune
        Root.runGarbageCollection(for: command)
        let output = try await captureStandardOutput { try await command.run() }
        XCTAssertTrue(output.contains("No matching entries."))
        XCTAssertFalse(output.contains("Note:"))
        XCTAssertFalse(output.contains("Garbage collection"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
      }
    }
  }

  func testBudgetPreviewReportsTemporaryReferencesAfterResults() async throws {
    try await withTemporaryTartHome { _ in
      let contentStore = try ContentStore()
      let data = Data("temporary-base".utf8)
      let digest = Digest.hash(data)
      let temporaryContent = try contentStore.temporaryContentURL(for: digest)
      try data.write(to: temporaryContent)
      let contentURL = try contentStore.install(temporaryContent, contentDigest: digest)
      let temporaryVM = try VMDirectory.temporary()
      var disk = OCIManifestLayer(
        mediaType: diskV2MediaType, size: data.count, digest: "sha256:transport",
        uncompressedSize: UInt64(data.count), uncompressedContentDigest: digest
      )
      disk.annotations?[diskFileContentDigestAnnotation] = digest
      let manifest = OCIManifest(config: OCIManifestConfig(size: 1, digest: "sha256:config"), layers: [
        OCIManifestLayer(mediaType: configMediaType, size: 1, digest: "sha256:config"),
        disk,
        OCIManifestLayer(mediaType: nvramMediaType, size: 1, digest: "sha256:nvram"),
      ])
      try manifest.toJSON().write(to: temporaryVM.manifestURL)

      let command = try Prune.parseAsRoot(["--space-budget", "0", "--dry-run"]) as! Prune
      let output = try await captureStandardOutput { try await command.run() }
      let result = try XCTUnwrap(output.range(of: "No matching entries."))
      let notice = try XCTUnwrap(output.range(of: "Temporary image files still protect cached data"))
      XCTAssertLessThan(result.lowerBound, notice.lowerBound)
      XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryVM.manifestURL.path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: contentURL.path))
    }
  }

  func testDryRunSkipsBothGarbageCollectorsAndPreservesCache() async throws {
    try await withTemporaryTartHome { home in
      let cache = try IPSWCache()
      var ipswURL = cache.locationFor(fileName: "fixture.ipsw")
      let data = Data(repeating: 0x41, count: 8192)
      try data.write(to: ipswURL)
      let originalAccessDate = Date(timeIntervalSince1970: 1)
      let temporaryURL = try Config().tartTmpDir.appendingPathComponent("keep-me")
      try data.write(to: temporaryURL)
      let ociURL = try VMStorageOCI().baseURL
      try FileManager.default.createDirectory(at: ociURL, withIntermediateDirectories: true)
      let brokenLink = ociURL.appendingPathComponent("broken-tag")
      try FileManager.default.createSymbolicLink(atPath: brokenLink.path, withDestinationPath: "missing")
      let originalPaths = try FileManager.default.subpathsOfDirectory(atPath: home.path).sorted()

      for criteria in [["--gc"], ["--gc", "--older-than", "7", "--space-budget", "0"]] {
        try ipswURL.updateAccessDate(originalAccessDate)
        let command = try Prune.parseAsRoot(criteria + ["--dry-run"]) as! Prune
        Root.runGarbageCollection(for: command)
        let output = try await captureStandardOutput { try await command.run() }
        XCTAssertFalse(output.contains("reattributed"))
        XCTAssertTrue(output.hasSuffix("Garbage collection (--gc) is not included in this preview.\n"))
        if criteria.count == 1 {
          XCTAssertTrue(output.contains("No matching entries."))
        } else {
          let candidate = try XCTUnwrap(cache.prunables().first)
          XCTAssertTrue(output.contains("Would remove \(candidate.url.path)"), output)
        }

        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: home.path).sorted(), originalPaths)
        ipswURL.removeCachedResourceValue(forKey: .contentAccessDateKey)
        XCTAssertEqual(try ipswURL.accessDate(), originalAccessDate)
        XCTAssertEqual(try Data(contentsOf: ipswURL), data)
        XCTAssertEqual(try Data(contentsOf: temporaryURL), data)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: brokenLink.path), "missing")
      }

      // Exercise command dispatch for real deletion only inside this fixture.
      // Reading the fixture above can update its filesystem access time.
      try ipswURL.updateAccessDate(originalAccessDate)
      let command = try Prune.parseAsRoot(["--older-than", "7"]) as! Prune
      try await command.run()
      XCTAssertFalse(FileManager.default.fileExists(atPath: ipswURL.path))
    }
  }

  private func captureStandardOutput(_ body: () async throws -> Void) async throws -> String {
    let pipe = Pipe()
    fflush(stdout)
    let savedOutput = dup(STDOUT_FILENO)
    defer {
      fflush(stdout)
      dup2(savedOutput, STDOUT_FILENO)
      close(savedOutput)
    }
    dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
    try await body()
    fflush(stdout)
    dup2(savedOutput, STDOUT_FILENO)
    try pipe.fileHandleForWriting.close()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(decoding: data, as: UTF8.self)
  }

  private func withTemporaryTartHome(_ body: (URL) async throws -> Void) async throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    let home = parent.appendingPathComponent("home")
    let previousHome = ProcessInfo.processInfo.environment["TART_HOME"]
    setenv("TART_HOME", home.path, 1)
    defer {
      if let previousHome {
        setenv("TART_HOME", previousHome, 1)
      } else {
        unsetenv("TART_HOME")
      }
    }
    addTeardownBlock {
      try FileManager.default.removeItem(at: parent)
    }
    try await body(home)
  }
}

private enum MockPruneError: Error {
  case tooManyScans
  case size
  case deletion
}

private final class MockStorage: PrunableStorage {
  let entries: [MockPrunable]
  var deletedURLs: [URL] = []
  var scans = 0
  var scanLimit: Int

  init(entries: [MockPrunable] = [
    MockPrunable(name: "oldest", accessed: 1, allocatedBytes: 3),
    MockPrunable(name: "newest", accessed: 3, allocatedBytes: 9),
    MockPrunable(name: "middle", accessed: 2, allocatedBytes: 4),
  ]) {
    self.entries = entries
    scanLimit = entries.count + 1
    for entry in entries {
      entry.onDelete = { [weak self] url in self?.deletedURLs.append(url) }
    }
  }

  func prunables() throws -> [Prunable] {
    scans += 1
    guard scans <= scanLimit else {
      throw MockPruneError.tooManyScans
    }
    return entries.filter { !$0.deleted }
  }
}

private final class MockPrunable: Prunable {
  let url: URL
  let accessed: Date
  let allocatedBytes: Int
  var deleted = false
  var sizeFails = false
  var sizeReads = 0
  var deleteFails = false
  var onDelete: ((URL) -> Void)?

  init(name: String, accessed: TimeInterval, allocatedBytes: Int) {
    url = URL(fileURLWithPath: "/prune-test/\(name)")
    self.accessed = Date(timeIntervalSince1970: accessed)
    self.allocatedBytes = allocatedBytes
  }

  func delete() throws {
    if deleteFails {
      throw MockPruneError.deletion
    }
    deleted = true
    onDelete?(url)
  }

  func accessDate() throws -> Date {
    accessed
  }

  func sizeBytes() throws -> Int {
    allocatedBytes * 100
  }

  func allocatedSizeBytes() throws -> Int {
    sizeReads += 1
    if sizeFails {
      throw MockPruneError.size
    }
    return allocatedBytes
  }
}
