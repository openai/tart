import Foundation
import XCTest
@testable import tart

#if canImport(DiskImageKit)
  import DiskImageKit
#endif

final class VMStorageOCITests: XCTestCase {
  func testPopulateStandalonePushedImageCachesDiskAndManifest() throws {
    try withTemporaryTartHome {
      let source = try standaloneSource(diskData: Data("disk".utf8))
      let manifest = try flatManifest()
      let name = try digestName(for: manifest)
      let storage = try VMStorageOCI()

      try storage.populate(name, from: source, manifest: manifest)

      let cached = try storage.open(name)
      XCTAssertTrue(cached.isStandalone)
      XCTAssertEqual(try Data(contentsOf: cached.diskURL), Data("disk".utf8))
      XCTAssertEqual(try OCIManifest(fromJSON: Data(contentsOf: cached.manifestURL)), manifest)
    }
  }

  func testStackedCloneRequiresManifestForLegacyStandaloneCachedImage() throws {
    try withTemporaryTartHome {
      let manifest = try flatManifest()
      let name = try digestName(for: manifest)
      let storage = try VMStorageOCI()
      let record = try storage.create(name)
      try config().save(toURL: record.configURL)
      XCTAssertTrue(FileManager.default.createFile(atPath: record.nvramURL.path, contents: Data()))
      XCTAssertTrue(FileManager.default.createFile(atPath: record.diskURL.path, contents: Data()))

      XCTAssertTrue(try storage.hasUsableCachedImageForClone(name))
      XCTAssertFalse(try storage.hasUsableCachedImageForClone(name, requireManifest: true))
      XCTAssertTrue(try storage.hasCompleteCachedImage(name, manifest: manifest))
      XCTAssertFalse(try storage.hasCompleteCachedImage(name, manifest: manifest, requireManifest: true))
    }
  }

  func testCloneCacheCheckRejectsMissingOrWrongSizedStackedContent() throws {
    try withTemporaryTartHome {
      let baseData = Data("base".utf8)
      let overlayData = Data("overlay".utf8)
      let baseDigest = Digest.hash(baseData)
      let overlayDigest = Digest.hash(overlayData)
      let manifest = try stackedManifest(
        baseContentDigest: baseDigest,
        overlayContentDigest: overlayDigest,
        baseUncompressedSize: UInt64(baseData.count),
        overlayUncompressedSize: UInt64(overlayData.count)
      )
      let name = try digestName(for: manifest)
      let storage = try VMStorageOCI()
      let record = try storage.create(name)
      try config().save(toURL: record.configURL)
      XCTAssertTrue(FileManager.default.createFile(atPath: record.nvramURL.path, contents: Data()))
      try manifest.toJSON().write(to: record.manifestURL)

      XCTAssertFalse(try storage.hasUsableCachedImageForClone(name))

      let contentStore = try ContentStore()
      try installContent(baseData, contentDigest: baseDigest, into: contentStore)
      try installContent(overlayData, contentDigest: overlayDigest, into: contentStore)
      XCTAssertTrue(try storage.hasUsableCachedImageForClone(name))

      try Data("bad".utf8).write(to: try contentStore.contentURL(for: overlayDigest))
      XCTAssertFalse(try storage.hasUsableCachedImageForClone(name))
    }
  }

  func testListIncludesStackedCachedImage() throws {
    try withTemporaryTartHome {
      let manifest = try stackedManifest()
      let name = try digestName(for: manifest)
      let storage = try VMStorageOCI()
      let record = try storage.create(name)
      try config().save(toURL: record.configURL)
      XCTAssertTrue(FileManager.default.createFile(atPath: record.nvramURL.path, contents: Data()))
      try manifest.toJSON().write(to: record.manifestURL)

      XCTAssertTrue(try storage.list().contains { $0.0 == name.description })
      XCTAssertEqual(try record.diskSizeBytes(), 4096)
      XCTAssertNoThrow(try record.allocatedSizeBytes())
    }
  }

  func testStackedCacheHitRequiresExpectedContentSizes() throws {
    try withTemporaryTartHome {
      let baseData = Data(repeating: 0x41, count: 10)
      let overlayData = Data(repeating: 0x42, count: 20)
      let baseDigest = Digest.hash(baseData)
      let overlayDigest = Digest.hash(overlayData)
      let manifest = try stackedManifest(
        baseContentDigest: baseDigest,
        overlayContentDigest: overlayDigest,
        baseUncompressedSize: 10,
        overlayUncompressedSize: 20
      )
      let name = try digestName(for: manifest)
      let storage = try VMStorageOCI()
      let record = try storage.create(name)
      try config().save(toURL: record.configURL)
      XCTAssertTrue(FileManager.default.createFile(atPath: record.nvramURL.path, contents: Data()))
      try manifest.toJSON().write(to: record.manifestURL)

      XCTAssertFalse(try storage.hasCompleteCachedImage(name, manifest: manifest))
      XCTAssertEqual(try storage.requiredDiskStorageBytes(for: manifest), 30)

      let contentStore = try ContentStore()
      try installContent(baseData, contentDigest: baseDigest, into: contentStore)
      XCTAssertFalse(try storage.hasCompleteCachedImage(name, manifest: manifest))
      XCTAssertEqual(try storage.requiredDiskStorageBytes(for: manifest), 20)

      try installContent(overlayData, contentDigest: overlayDigest, into: contentStore)
      XCTAssertTrue(try storage.hasCompleteCachedImage(name, manifest: manifest))
      XCTAssertEqual(try storage.requiredDiskStorageBytes(for: manifest), 0)

      let overlayURL = try contentStore.contentURL(for: overlayDigest)
      try Data("corrupt".utf8).write(to: overlayURL)
      XCTAssertFalse(try storage.hasCompleteCachedImage(name, manifest: manifest))
      XCTAssertEqual(try storage.requiredDiskStorageBytes(for: manifest), 20)
    }
  }

  func testStackedPullReusesPreviouslyPulledStandaloneDisk() throws {
    try withTemporaryTartHome {
      let diskData = Data([0])
      let contentDigest = Digest.hash(diskData)
      let flatManifest = try flatManifest()
      let flatName = try digestName(for: flatManifest)
      let storage = try VMStorageOCI()
      let flatRecord = try storage.create(flatName)
      try config().save(toURL: flatRecord.configURL)
      XCTAssertTrue(FileManager.default.createFile(atPath: flatRecord.nvramURL.path, contents: Data()))
      try diskData.write(to: flatRecord.diskURL)
      try flatManifest.toJSON().write(to: flatRecord.manifestURL)

      let stackedManifest = try stackedManifest(baseContentDigest: contentDigest)
      XCTAssertNil(try ContentStore().existingContentURL(for: contentDigest))

      try storage.reuseStandaloneDiskForStackedBaseIfPossible(stackedManifest)

      let reusedURL = try XCTUnwrap(try ContentStore().existingContentURL(for: contentDigest))
      XCTAssertEqual(try Data(contentsOf: reusedURL), diskData)
    }
  }

  func testStackedPullDoesNotRehashInstalledBaseBeforeReuse() throws {
    try withTemporaryTartHome {
      let contentDigest = Digest.hash(Data("base".utf8))
      let manifest = try stackedManifest(baseContentDigest: contentDigest)
      let contentURL = try ContentStore().contentURL(for: contentDigest)

      // Hashing this path would throw. Once an entry is published, this
      // fast path must trust its presence and let normal pull validation
      // repair unusable content later.
      try FileManager.default.createDirectory(at: contentURL, withIntermediateDirectories: false)

      XCTAssertNoThrow(try VMStorageOCI().reuseStandaloneDiskForStackedBaseIfPossible(manifest))
    }
  }

  func testNewTagDoesNotValidateCachedStackBeforeLock() throws {
    try withTemporaryTartHome {
      let baseDigest = Digest.hash(Data("base".utf8))
      let overlayDigest = Digest.hash(Data("overlay".utf8))
      let manifest = try stackedManifest(
        baseContentDigest: baseDigest,
        overlayContentDigest: overlayDigest
      )
      let digestName = try digestName(for: manifest)
      let tagName = RemoteName(
        host: digestName.host,
        namespace: digestName.namespace,
        reference: Reference(tag: "latest")
      )
      let storage = try VMStorageOCI()
      let record = try storage.create(digestName)
      try config().save(toURL: record.configURL)
      XCTAssertTrue(FileManager.default.createFile(atPath: record.nvramURL.path, contents: Data()))
      try manifest.toJSON().write(to: record.manifestURL)

      // Hashing this directory as a disk file throws. A new tag must skip
      // validation until after it has taken the host lock.
      let contentURL = try ContentStore().contentURL(for: baseDigest)
      try FileManager.default.createDirectory(at: contentURL, withIntermediateDirectories: false)
      XCTAssertFalse(try storage.hasCompleteLinkedImage(tagName, digestName: digestName, manifest: manifest))
    }
  }

  func testStandaloneLayerCacheIgnoresStackedCachedImages() async throws {
    try await withTemporaryTartHome {
      var targetManifest = try flatManifest()
      var stackedCandidateManifest = try stackedManifest()
      let sharedDiskSize = 2 * 1024 * 1024 * 1024
      targetManifest.layers[1].size = sharedDiskSize
      stackedCandidateManifest.layers[1] = targetManifest.layers[1]

      let candidateName = try digestName(for: stackedCandidateManifest)
      let storage = try VMStorageOCI()
      let candidate = try storage.create(candidateName)
      try config().save(toURL: candidate.configURL)
      XCTAssertTrue(FileManager.default.createFile(atPath: candidate.nvramURL.path, contents: Data()))
      try stackedCandidateManifest.toJSON().write(to: candidate.manifestURL)

      let targetName = RemoteName(
        host: "example.com",
        namespace: "org/target",
        reference: Reference(digest: try targetManifest.digest())
      )
      let registry = try Registry(host: targetName.host, namespace: targetName.namespace)

      let layerCache = try await storage.chooseLocalLayerCache(targetName, targetManifest, registry)
      XCTAssertNil(layerCache)
    }
  }

  func testGCPrunesOnlyUnreferencedContent() throws {
    try withTemporaryTartHome {
      let contentStore = try ContentStore()
      let referenced = try installContent(Data("referenced".utf8), into: contentStore)
      let unreferenced = try installContent(Data("unreferenced".utf8), into: contentStore)

      let stacked = try VMStorageLocal().create("stacked")
      try config().save(toURL: stacked.configURL)
      XCTAssertTrue(FileManager.default.createFile(atPath: stacked.nvramURL.path, contents: Data()))
      XCTAssertTrue(FileManager.default.createFile(atPath: stacked.overlayURL.path, contents: Data()))
      try pinnedBaseManifest(contentDigest: referenced.digest).toJSON().write(to: stacked.manifestURL)

      try VMStorageOCI().gc()

      XCTAssertTrue(FileManager.default.fileExists(atPath: referenced.url.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: unreferenced.url.path))
    }
  }

  func testGCPrunesContentWithoutOCIStorageDirectory() throws {
    try withTemporaryTartHome {
      let contentStore = try ContentStore()
      let unreferenced = try installContent(Data("unreferenced".utf8), into: contentStore)
      let storage = try VMStorageOCI()

      XCTAssertFalse(FileManager.default.fileExists(atPath: storage.baseURL.path))

      try storage.gc()

      XCTAssertFalse(FileManager.default.fileExists(atPath: unreferenced.url.path))
    }
  }

  func testGCDoesNotPruneContentReferencedByInProgressManifest() throws {
    try withTemporaryTartHome {
      let contentStore = try ContentStore()
      let referenced = try installContent(Data("in-progress".utf8), into: contentStore)
      let temporaryVMDir = try VMDirectory.temporary()

      // Pull and clone publish the manifest before config, NVRAM, or a
      // writable overlay necessarily exist.
      try pinnedBaseManifest(contentDigest: referenced.digest).toJSON().write(to: temporaryVMDir.manifestURL)

      try VMStorageOCI().gc()

      XCTAssertTrue(FileManager.default.fileExists(atPath: referenced.url.path))
    }
  }

  func testStalePrunableDoesNotDeleteNewlyReferencedContent() throws {
    try withTemporaryTartHome {
      let contentStore = try ContentStore()
      let content = try installContent(Data("new-reference".utf8), into: contentStore)
      let storage = try VMStorageOCI()
      let candidate = try XCTUnwrap(storage.prunables().first {
        $0.url.resolvingSymlinksInPath() == content.url.resolvingSymlinksInPath()
      })

      // Simulate a clone or pull publishing its manifest after prune built
      // the candidate list but before deletion starts.
      let temporaryVMDir = try VMDirectory.temporary()
      try contentStore.withPruneLock {
        try pinnedBaseManifest(contentDigest: content.digest).toJSON().write(to: temporaryVMDir.manifestURL)
      }

      try candidate.delete()

      XCTAssertTrue(FileManager.default.fileExists(atPath: content.url.path))
    }
  }

  func testVMDirectoryDeletionOfStackedOCIRecordWaitsForPruneLock() throws {
    try withTemporaryTartHome {
      let storage = try VMStorageOCI()
      let record = try createRecord(for: stackedManifest(), in: storage)

      try assertDeletionWaitsForPruneLock(record: record) {
        try record.delete()
      }
    }
  }

  func testStorageDeletionOfStackedOCIRecordWaitsForPruneLock() throws {
    try withTemporaryTartHome {
      let storage = try VMStorageOCI()
      let manifest = try stackedManifest()
      let name = try digestName(for: manifest)
      let record = try createRecord(for: manifest, in: storage)

      try assertDeletionWaitsForPruneLock(record: record) {
        try storage.delete(name)
      }
    }
  }

  func testStorageDeletionOfIncompleteManifestRecordWaitsForPruneLock() throws {
    try withTemporaryTartHome {
      let storage = try VMStorageOCI()
      let name = RemoteName(
        host: "example.com",
        namespace: "org/image",
        reference: Reference(digest: "sha256:incomplete")
      )
      let record = try storage.create(name)
      try Data("{}".utf8).write(to: record.manifestURL)

      try assertDeletionWaitsForPruneLock(record: record) {
        try storage.delete(name)
      }
    }
  }

  func testVMDirectoryDeletionOfUnpublishedRecordWaitsForPruneLock() throws {
    try withTemporaryTartHome {
      let storage = try VMStorageOCI()
      let record = try storage.create(RemoteName(
        host: "example.com",
        namespace: "org/image",
        reference: Reference(digest: "sha256:unpublished")
      ))

      try assertDeletionWaitsForPruneLock(record: record) {
        try record.removeFromDisk()
      }
    }
  }

  func testTagReplacementWaitsForPruneLock() throws {
    try withTemporaryTartHome {
      let storage = try VMStorageOCI()
      let firstManifest = try stackedManifest(baseContentDigest: "sha256:first")
      let secondManifest = try stackedManifest(baseContentDigest: "sha256:second")
      let firstName = try digestName(for: firstManifest)
      let secondName = try digestName(for: secondManifest)
      _ = try createRecord(for: firstManifest, in: storage)
      _ = try createRecord(for: secondManifest, in: storage)
      let tagName = RemoteName(
        host: secondName.host,
        namespace: secondName.namespace,
        reference: Reference(tag: "latest")
      )

      let contentStore = try ContentStore()
      let lockHeld = DispatchSemaphore(value: 0)
      let releaseLock = DispatchSemaphore(value: 0)
      let replacementStarted = DispatchSemaphore(value: 0)
      let replacementFinished = DispatchSemaphore(value: 0)

      DispatchQueue.global().async {
        try? contentStore.withPruneLock {
          lockHeld.signal()
          releaseLock.wait()
        }
      }
      XCTAssertEqual(lockHeld.wait(timeout: .now() + 1), .success)

      DispatchQueue.global().async {
        replacementStarted.signal()
        try? storage.link(from: tagName, to: secondName)
        replacementFinished.signal()
      }
      XCTAssertEqual(replacementStarted.wait(timeout: .now() + 1), .success)
      XCTAssertEqual(replacementFinished.wait(timeout: .now() + 0.1), .timedOut)

      releaseLock.signal()
      XCTAssertEqual(replacementFinished.wait(timeout: .now() + 1), .success)
      XCTAssertTrue(storage.linked(from: tagName, to: secondName))
      XCTAssertFalse(storage.linked(from: tagName, to: firstName))
    }
  }

  func testGCDeletionOfStackedOCIRecordWaitsForPruneLock() throws {
    try withTemporaryTartHome {
      let storage = try VMStorageOCI()
      let record = try createRecord(for: stackedManifest(), in: storage)

      try assertDeletionWaitsForPruneLock(record: record) {
        try storage.gc()
      }
    }
  }

  func testTemporaryManifestGCWaitsForPruneLock() throws {
    try withTemporaryTartHome {
      let temporaryVMDir = try VMDirectory.temporary()
      try stackedManifest().toJSON().write(to: temporaryVMDir.manifestURL)

      try assertDeletionWaitsForPruneLock(record: temporaryVMDir) {
        try Config().gc()
      }
    }
  }

  func testLockedTemporaryDirectorySurvivesGarbageCollection() throws {
    try withTemporaryTartHome {
      let temporaryVMDir = try VMDirectory.temporary()
      let lock = try FileLock(lockURL: temporaryVMDir.baseURL)
      try lock.lock()

      try Config().gc()
      XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryVMDir.baseURL.path))

      try lock.unlock()
      try Config().gc()
      XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryVMDir.baseURL.path))
    }
  }

  func testMovingStackedOCIRecordWaitsForPruneLock() throws {
    try withTemporaryTartHome {
      let storage = try VMStorageOCI()
      let source = try temporaryVMDirectory()
      let manifest = try stackedManifest()
      let name = try digestName(for: manifest)
      try config().save(toURL: source.configURL)
      XCTAssertTrue(FileManager.default.createFile(atPath: source.nvramURL.path, contents: Data()))
      try manifest.toJSON().write(to: source.manifestURL)

      let contentStore = try ContentStore()
      let lockHeld = DispatchSemaphore(value: 0)
      let releaseLock = DispatchSemaphore(value: 0)
      let moveStarted = DispatchSemaphore(value: 0)
      let moveFinished = DispatchSemaphore(value: 0)

      DispatchQueue.global().async {
        try? contentStore.withPruneLock {
          lockHeld.signal()
          releaseLock.wait()
        }
      }
      XCTAssertEqual(lockHeld.wait(timeout: .now() + 1), .success)

      DispatchQueue.global().async {
        moveStarted.signal()
        try? storage.move(name, from: source)
        moveFinished.signal()
      }
      XCTAssertEqual(moveStarted.wait(timeout: .now() + 1), .success)
      XCTAssertEqual(moveFinished.wait(timeout: .now() + 0.1), .timedOut)
      XCTAssertTrue(FileManager.default.fileExists(atPath: source.baseURL.path))

      releaseLock.signal()
      XCTAssertEqual(moveFinished.wait(timeout: .now() + 1), .success)
      XCTAssertFalse(FileManager.default.fileExists(atPath: source.baseURL.path))
      XCTAssertTrue(try storage.open(name).isStackedCachedImage)
    }
  }

  func testPruningLastStackedOCIRecordReclaimsItsContent() throws {
    try withTemporaryTartHome {
      let contentStore = try ContentStore()
      let baseContent = try installContent(Data("record-only-base".utf8), into: contentStore)
      let overlayContent = try installContent(Data("record-only-overlay".utf8), into: contentStore)
      let manifest = try stackedManifest(
        baseContentDigest: baseContent.digest,
        overlayContentDigest: overlayContent.digest,
        baseUncompressedSize: UInt64(try baseContent.url.sizeBytes()),
        overlayUncompressedSize: UInt64(try overlayContent.url.sizeBytes())
      )
      let name = try digestName(for: manifest)
      let storage = try VMStorageOCI()
      let record = try storage.create(name)
      try config().save(toURL: record.configURL)
      XCTAssertTrue(FileManager.default.createFile(atPath: record.nvramURL.path, contents: Data()))
      try manifest.toJSON().write(to: record.manifestURL)

      let candidate = try XCTUnwrap(storage.prunables().first {
        $0.url.lastPathComponent == record.url.lastPathComponent
      })
      XCTAssertGreaterThanOrEqual(
        try candidate.allocatedSizeBytes(),
        try baseContent.url.allocatedSizeBytes() + overlayContent.url.allocatedSizeBytes()
      )

      // The record itself fits in this budget, so pruning only succeeds if it
      // accounts for the immutable content released with the final reference.
      try Prune.pruneSpaceBudget(
        prunableStorages: [storage],
        spaceBudgetBytes: UInt64(try record.allocatedSizeBytes())
      )

      XCTAssertFalse(FileManager.default.fileExists(atPath: record.url.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: baseContent.url.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: overlayContent.url.path))
    }
  }

  func testMalformedStackedOCIRecordDoesNotBlockPruning() throws {
    try withTemporaryTartHome {
      let contentStore = try ContentStore()
      let baseContent = try installContent(Data("valid-base".utf8), into: contentStore)
      let overlayContent = try installContent(Data("valid-overlay".utf8), into: contentStore)
      let storage = try VMStorageOCI()
      let validRecord = try createRecord(for: stackedManifest(
        baseContentDigest: baseContent.digest,
        overlayContentDigest: overlayContent.digest,
        baseUncompressedSize: UInt64(try baseContent.url.sizeBytes()),
        overlayUncompressedSize: UInt64(try overlayContent.url.sizeBytes())
      ), in: storage)

      let malformedRecord = try storage.create(RemoteName(
        host: "example.com",
        namespace: "org/image",
        reference: Reference(digest: "sha256:malformed")
      ))
      try config().save(toURL: malformedRecord.configURL)
      XCTAssertTrue(FileManager.default.createFile(atPath: malformedRecord.nvramURL.path, contents: Data()))
      try Data("{".utf8).write(to: malformedRecord.manifestURL)

      XCTAssertNoThrow(try storage.prunables())
      try Prune.pruneSpaceBudget(prunableStorages: [storage], spaceBudgetBytes: 0)

      XCTAssertFalse(FileManager.default.fileExists(atPath: validRecord.url.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: malformedRecord.url.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: baseContent.url.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: overlayContent.url.path))
    }
  }

  func testPruningOneStackedOCIRecordPreservesSharedContent() throws {
    try withTemporaryTartHome {
      let contentStore = try ContentStore()
      let baseContent = try installContent(Data("shared-base".utf8), into: contentStore)
      let firstOverlay = try installContent(Data("first-overlay".utf8), into: contentStore)
      let secondOverlay = try installContent(Data("second-overlay".utf8), into: contentStore)
      let storage = try VMStorageOCI()

      let firstManifest = try stackedManifest(
        baseContentDigest: baseContent.digest,
        overlayContentDigest: firstOverlay.digest,
        baseUncompressedSize: UInt64(try baseContent.url.sizeBytes()),
        overlayUncompressedSize: UInt64(try firstOverlay.url.sizeBytes())
      )
      let secondManifest = try stackedManifest(
        baseContentDigest: baseContent.digest,
        overlayContentDigest: secondOverlay.digest,
        baseUncompressedSize: UInt64(try baseContent.url.sizeBytes()),
        overlayUncompressedSize: UInt64(try secondOverlay.url.sizeBytes())
      )
      let firstRecord = try createRecord(for: firstManifest, in: storage)
      let secondRecord = try createRecord(for: secondManifest, in: storage)

      let firstCandidate = try XCTUnwrap(storage.prunables().first {
        $0.url.lastPathComponent == firstRecord.url.lastPathComponent
      })
      try firstCandidate.delete()

      XCTAssertTrue(FileManager.default.fileExists(atPath: baseContent.url.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: firstOverlay.url.path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: secondOverlay.url.path))

      let secondCandidate = try XCTUnwrap(storage.prunables().first {
        $0.url.lastPathComponent == secondRecord.url.lastPathComponent
      })
      try secondCandidate.delete()

      XCTAssertFalse(FileManager.default.fileExists(atPath: baseContent.url.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: secondOverlay.url.path))
    }
  }

  func testSpaceBudgetRecomputesSharedContentAfterOwnerDeletion() throws {
    try withTemporaryTartHome {
      let contentStore = try ContentStore()
      let baseContent = try installContent(Data("shared-base".utf8), into: contentStore)
      let firstOverlay = try installContent(Data("first-overlay".utf8), into: contentStore)
      let secondOverlay = try installContent(Data("second-overlay".utf8), into: contentStore)
      let storage = try VMStorageOCI()

      let firstManifest = try stackedManifest(
        baseContentDigest: baseContent.digest,
        overlayContentDigest: firstOverlay.digest,
        baseUncompressedSize: UInt64(try baseContent.url.sizeBytes()),
        overlayUncompressedSize: UInt64(try firstOverlay.url.sizeBytes())
      )
      let secondManifest = try stackedManifest(
        baseContentDigest: baseContent.digest,
        overlayContentDigest: secondOverlay.digest,
        baseUncompressedSize: UInt64(try baseContent.url.sizeBytes()),
        overlayUncompressedSize: UInt64(try secondOverlay.url.sizeBytes())
      )
      let olderRecord = try createRecord(for: firstManifest, in: storage)
      let newerRecord = try createRecord(for: secondManifest, in: storage)
      try olderRecord.url.updateAccessDate(Date(timeIntervalSince1970: 1))
      try newerRecord.url.updateAccessDate(Date(timeIntervalSince1970: 2))

      let olderCandidate = try XCTUnwrap(storage.prunables().first {
        $0.url.lastPathComponent == olderRecord.url.lastPathComponent
      })
      let budget = UInt64(try olderCandidate.allocatedSizeBytes())

      // On the first pass the newer record owns the shared base and is
      // selected for deletion, while the older record fits this budget.
      // Recomputing must then charge the surviving record for the base and
      // prune it too.
      try Prune.pruneSpaceBudget(
        prunableStorages: [storage],
        spaceBudgetBytes: budget
      )

      XCTAssertFalse(FileManager.default.fileExists(atPath: olderRecord.url.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: newerRecord.url.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: baseContent.url.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: firstOverlay.url.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: secondOverlay.url.path))
    }
  }

  func testSpaceBudgetRecomputesBeforeDeletingAnotherCandidate() throws {
    try withTemporaryTartHome {
      let contentStore = try ContentStore()
      let sharedBase = try installContent(Data(repeating: 0x41, count: 128 * 1024), into: contentStore)
      let newestOverlay = try installContent(Data("newest-overlay".utf8), into: contentStore)
      let middleOverlay = try installContent(Data("middle-overlay".utf8), into: contentStore)
      let retainedBase = try installContent(Data(repeating: 0x42, count: 32 * 1024), into: contentStore)
      let retainedOverlay = try installContent(Data("retained-overlay".utf8), into: contentStore)
      let storage = try VMStorageOCI()

      let newest = try createRecord(for: stackedManifest(
        baseContentDigest: sharedBase.digest,
        overlayContentDigest: newestOverlay.digest,
        baseUncompressedSize: UInt64(try sharedBase.url.sizeBytes()),
        overlayUncompressedSize: UInt64(try newestOverlay.url.sizeBytes())
      ), in: storage)
      let middle = try createRecord(for: stackedManifest(
        baseContentDigest: sharedBase.digest,
        overlayContentDigest: middleOverlay.digest,
        baseUncompressedSize: UInt64(try sharedBase.url.sizeBytes()),
        overlayUncompressedSize: UInt64(try middleOverlay.url.sizeBytes())
      ), in: storage)
      let retained = try createRecord(for: stackedManifest(
        baseContentDigest: retainedBase.digest,
        overlayContentDigest: retainedOverlay.digest,
        baseUncompressedSize: UInt64(try retainedBase.url.sizeBytes()),
        overlayUncompressedSize: UInt64(try retainedOverlay.url.sizeBytes())
      ), in: storage)
      try newest.url.updateAccessDate(Date(timeIntervalSince1970: 3))
      try middle.url.updateAccessDate(Date(timeIntervalSince1970: 2))
      try retained.url.updateAccessDate(Date(timeIntervalSince1970: 1))

      let retainedCandidate = try XCTUnwrap(storage.prunables().first {
        $0.url.lastPathComponent == retained.url.lastPathComponent
      })

      // Initially the newest record owns the shared base and is too large.
      // The middle record appears small enough to retain, making the oldest
      // unrelated record look like a second deletion candidate. After the
      // first deletion, ownership moves to the middle record; recomputing
      // before selecting again must delete it and preserve the unrelated one.
      try Prune.pruneSpaceBudget(
        prunableStorages: [storage],
        spaceBudgetBytes: UInt64(try retainedCandidate.allocatedSizeBytes())
      )

      XCTAssertFalse(FileManager.default.fileExists(atPath: newest.url.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: middle.url.path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: retained.url.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: sharedBase.url.path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: retainedBase.url.path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: retainedOverlay.url.path))
    }
  }

  func testAutomaticReclaimRecomputesSharedContentAfterOwnerDeletion() throws {
    try withTemporaryTartHome {
      let contentStore = try ContentStore()
      let sharedBase = try installContent(Data(repeating: 0x41, count: 128 * 1024), into: contentStore)
      let initiatorOverlay = try installContent(Data("initiator-overlay".utf8), into: contentStore)
      let ownerOverlay = try installContent(Data("owner-overlay".utf8), into: contentStore)
      let unrelatedBase = try installContent(Data("unrelated-base".utf8), into: contentStore)
      let unrelatedOverlay = try installContent(Data("unrelated-overlay".utf8), into: contentStore)
      let storage = try VMStorageOCI()

      let initiatorManifest = try stackedManifest(
        baseContentDigest: sharedBase.digest,
        overlayContentDigest: initiatorOverlay.digest,
        baseUncompressedSize: UInt64(try sharedBase.url.sizeBytes()),
        overlayUncompressedSize: UInt64(try initiatorOverlay.url.sizeBytes())
      )
      let ownerManifest = try stackedManifest(
        baseContentDigest: sharedBase.digest,
        overlayContentDigest: ownerOverlay.digest,
        baseUncompressedSize: UInt64(try sharedBase.url.sizeBytes()),
        overlayUncompressedSize: UInt64(try ownerOverlay.url.sizeBytes())
      )
      let unrelatedManifest = try stackedManifest(
        baseContentDigest: unrelatedBase.digest,
        overlayContentDigest: unrelatedOverlay.digest,
        baseUncompressedSize: UInt64(try unrelatedBase.url.sizeBytes()),
        overlayUncompressedSize: UInt64(try unrelatedOverlay.url.sizeBytes())
      )
      let initiator = try createRecord(for: initiatorManifest, in: storage)
      let owner = try createRecord(for: ownerManifest, in: storage)
      let unrelated = try createRecord(for: unrelatedManifest, in: storage)
      try initiator.url.updateAccessDate(Date(timeIntervalSince1970: 1))
      try owner.url.updateAccessDate(Date(timeIntervalSince1970: 2))
      try unrelated.url.updateAccessDate(Date(timeIntervalSince1970: 3))

      let sharedBaseSize = UInt64(try sharedBase.url.allocatedSizeBytes())

      // The owner is the first deletable record and is initially charged for
      // the shared base. Deleting it cannot reclaim that base because the
      // protected initiator still references it, so reclaim must continue.
      try Prune.reclaimIfPossible(sharedBaseSize, initiator)

      XCTAssertTrue(FileManager.default.fileExists(atPath: initiator.url.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: owner.url.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: unrelated.url.path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: sharedBase.url.path))
    }
  }

  func testPruningCachedImageRemovesOnlyItsTagSymlink() throws {
    try withTemporaryTartHome {
      let storage = try VMStorageOCI()
      // Content digests are validated when manifests are scanned for pruning.
      // Use syntactically valid digests here; the test only exercises record
      // and tag-symlink cleanup, not content installation.
      let deletedManifest = try stackedManifest(
        baseContentDigest: "sha256:" + String(repeating: "a", count: 64)
      )
      let retainedManifest = try stackedManifest(
        baseContentDigest: "sha256:" + String(repeating: "b", count: 64)
      )
      let deletedName = try digestName(for: deletedManifest)
      let deletedRecord = try createRecord(for: deletedManifest, in: storage)
      let tagName = RemoteName(host: "example.com", namespace: "org/image", reference: Reference(tag: "deleted"))
      let tagURL = storage.baseURL.appendingRemoteName(tagName)
      try storage.link(from: tagName, to: deletedName)
      let retainedRecord = try createRecord(for: retainedManifest, in: storage)
      try deletedRecord.url.updateAccessDate(Date(timeIntervalSince1970: 1))

      try Prune.pruneOlderThan(
        prunableStorages: [storage],
        olderThanDate: Date(timeIntervalSince1970: 2)
      )

      XCTAssertFalse(FileManager.default.fileExists(atPath: deletedRecord.url.path))
      XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: tagURL.path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: retainedRecord.url.path))
    }
  }

  #if canImport(DiskImageKit)
    @available(macOS 27.0, *)
    func testPopulateStackedPushedImageCachesImmutableTopOverlay() throws {
      if #unavailable(macOS 27.0) {
        throw XCTSkip("DiskImageKit tests require macOS 27 or newer")
      }

      try withTemporaryTartHome {
        let source = try diskImageSource()
        let stacked = try temporaryVMDirectory()
        try source.cloneAsStackedBase(to: stacked, generateMAC: false)

        var manifest = try OCIManifest(fromJSON: Data(contentsOf: stacked.manifestURL))
        let contentDigest = try Digest.hash(stacked.overlayURL)
        var overlay = OCIManifestLayer(
          mediaType: asifOverlayMediaType,
          size: 1,
          digest: "sha256:overlay-transport",
          uncompressedSize: 1,
          uncompressedContentDigest: "sha256:overlay-chunk"
        )
        overlay.annotations?[diskFileContentDigestAnnotation] = contentDigest
        overlay.annotations?[diskFileChunkCountAnnotation] = "1"
        manifest.layers.insert(overlay, at: manifest.layers.count - 1)

        let name = try digestName(for: manifest)
        let storage = try VMStorageOCI()
        try storage.populate(name, from: stacked, manifest: manifest)

        let cached = try storage.open(name)
        XCTAssertTrue(cached.isStackedCachedImage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cached.overlayURL.path))
        XCTAssertEqual(try OCIManifest(fromJSON: Data(contentsOf: cached.manifestURL)), manifest)

        let cachedContent = try XCTUnwrap(try ContentStore().existingContentURL(for: contentDigest))
        XCTAssertEqual(try Digest.hash(cachedContent), contentDigest)
      }
    }
  #endif

  private func standaloneSource(diskData: Data) throws -> VMDirectory {
    let vmDir = try temporaryVMDirectory()
    try config().save(toURL: vmDir.configURL)
    XCTAssertTrue(FileManager.default.createFile(atPath: vmDir.nvramURL.path, contents: Data()))
    try diskData.write(to: vmDir.diskURL)

    return vmDir
  }

  private func createRecord(for manifest: OCIManifest, in storage: VMStorageOCI) throws -> VMDirectory {
    let record = try storage.create(try digestName(for: manifest))
    try config().save(toURL: record.configURL)
    XCTAssertTrue(FileManager.default.createFile(atPath: record.nvramURL.path, contents: Data()))
    try manifest.toJSON().write(to: record.manifestURL)

    return record
  }

  private func assertDeletionWaitsForPruneLock(
    record: VMDirectory,
    deletion: @escaping () throws -> Void
  ) throws {
    let contentStore = try ContentStore()
    let lockHeld = DispatchSemaphore(value: 0)
    let releaseLock = DispatchSemaphore(value: 0)
    let deletionStarted = DispatchSemaphore(value: 0)
    let deletionFinished = DispatchSemaphore(value: 0)

    DispatchQueue.global().async {
      try? contentStore.withPruneLock {
        lockHeld.signal()
        releaseLock.wait()
      }
    }
    XCTAssertEqual(lockHeld.wait(timeout: .now() + 1), .success)

    DispatchQueue.global().async {
      deletionStarted.signal()
      try? deletion()
      deletionFinished.signal()
    }
    XCTAssertEqual(deletionStarted.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(deletionFinished.wait(timeout: .now() + 0.1), .timedOut)
    XCTAssertTrue(FileManager.default.fileExists(atPath: record.baseURL.path))

    releaseLock.signal()
    XCTAssertEqual(deletionFinished.wait(timeout: .now() + 1), .success)
    XCTAssertFalse(FileManager.default.fileExists(atPath: record.baseURL.path))
  }

  #if canImport(DiskImageKit)
    @available(macOS 27.0, *)
    private func diskImageSource() throws -> VMDirectory {
      let vmDir = try temporaryVMDirectory()
      try config().save(toURL: vmDir.configURL)
      XCTAssertTrue(FileManager.default.createFile(atPath: vmDir.nvramURL.path, contents: Data()))
      _ = try DiskImage(creating: .raw(url: vmDir.diskURL, blockCount: 8))
      try flatManifest().toJSON().write(to: vmDir.manifestURL)

      return vmDir
    }
  #endif

  private func config() -> VMConfig {
    VMConfig(
      platform: Linux(),
      cpuCountMin: 2,
      memorySizeMin: 512 * 1024 * 1024,
      diskFormat: .raw
    )
  }

  private func flatManifest() throws -> OCIManifest {
    let disk = OCIManifestLayer(
      mediaType: diskV2MediaType,
      size: 1,
      digest: "sha256:disk-transport",
      uncompressedSize: 1,
      uncompressedContentDigest: "sha256:disk-chunk"
    )

    return OCIManifest(
      config: OCIManifestConfig(size: 1, digest: "sha256:oci-config"),
      layers: [
        OCIManifestLayer(mediaType: configMediaType, size: 1, digest: "sha256:config"),
        disk,
        OCIManifestLayer(mediaType: nvramMediaType, size: 1, digest: "sha256:nvram"),
      ]
    )
  }

  private func stackedManifest(
    baseContentDigest: String = "sha256:base",
    overlayContentDigest: String = "sha256:overlay",
    baseUncompressedSize: UInt64 = 1,
    overlayUncompressedSize: UInt64 = 1
  ) throws -> OCIManifest {
    var manifest = try flatManifest()
    manifest.annotations?[diskBlockSizeAnnotation] = "512"
    manifest.annotations?[uncompressedDiskSizeAnnotation] = "4096"
    manifest.layers[1].annotations?[diskFileContentDigestAnnotation] = baseContentDigest
    manifest.layers[1].annotations?[uncompressedSizeAnnotation] = String(baseUncompressedSize)
    var overlay = OCIManifestLayer(
      mediaType: asifOverlayMediaType,
      size: 1,
      digest: "sha256:overlay-transport",
      uncompressedSize: overlayUncompressedSize,
      uncompressedContentDigest: "sha256:overlay-chunk"
    )
    overlay.annotations?[diskFileContentDigestAnnotation] = overlayContentDigest
    overlay.annotations?[diskFileChunkCountAnnotation] = "1"
    manifest.layers.insert(overlay, at: manifest.layers.count - 1)

    return manifest
  }

  private func installContent(_ data: Data, contentDigest: String, into contentStore: ContentStore) throws {
    let temporaryURL = try contentStore.temporaryContentURL(for: contentDigest)
    try data.write(to: temporaryURL)
    _ = try contentStore.install(temporaryURL, contentDigest: contentDigest)
  }

  private func pinnedBaseManifest(contentDigest: String) -> OCIManifest {
    var disk = OCIManifestLayer(
      mediaType: diskV2MediaType,
      size: 1,
      digest: "sha256:disk-transport",
      uncompressedSize: 1,
      uncompressedContentDigest: "sha256:disk-chunk"
    )
    disk.annotations?[diskFileContentDigestAnnotation] = contentDigest

    return OCIManifest(
      config: OCIManifestConfig(size: 1, digest: "sha256:oci-config"),
      layers: [
        OCIManifestLayer(mediaType: configMediaType, size: 1, digest: "sha256:config"),
        disk,
        OCIManifestLayer(mediaType: nvramMediaType, size: 1, digest: "sha256:nvram"),
      ]
    )
  }

  private func installContent(_ data: Data, into contentStore: ContentStore) throws -> (digest: String, url: URL) {
    let digest = Digest.hash(data)
    let temporaryURL = try contentStore.temporaryContentURL(for: digest)
    try data.write(to: temporaryURL)

    return (digest, try contentStore.install(temporaryURL, contentDigest: digest))
  }

  private func digestName(for manifest: OCIManifest) throws -> RemoteName {
    RemoteName(
      host: "example.com",
      namespace: "org/image",
      reference: Reference(digest: try manifest.digest())
    )
  }

  private func withTemporaryTartHome(_ body: () throws -> Void) throws {
    let home = try temporaryDirectory()
    let previousHome = ProcessInfo.processInfo.environment["TART_HOME"]
    setenv("TART_HOME", home.path, 1)
    defer {
      if let previousHome {
        setenv("TART_HOME", previousHome, 1)
      } else {
        unsetenv("TART_HOME")
      }
    }

    try body()
  }

  private func withTemporaryTartHome(_ body: () async throws -> Void) async throws {
    let home = try temporaryDirectory()
    let previousHome = ProcessInfo.processInfo.environment["TART_HOME"]
    setenv("TART_HOME", home.path, 1)
    defer {
      if let previousHome {
        setenv("TART_HOME", previousHome, 1)
      } else {
        unsetenv("TART_HOME")
      }
    }

    try await body()
  }

  private func temporaryVMDirectory() throws -> VMDirectory {
    VMDirectory(baseURL: try temporaryDirectory())
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: url)
    }

    return url
  }
}
