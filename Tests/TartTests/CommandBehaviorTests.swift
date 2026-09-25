import Foundation
import ArgumentParser
import XCTest
@testable import tart

final class CommandBehaviorTests: XCTestCase {
  func testListSurvivesUnavailableDiskCapacity() async throws {
    try await withTemporaryTartHome {
      let previousPath = try installUnavailableDiskutil()
      defer { restoreEnvironment("PATH", to: previousPath) }

      let local = try VMStorageLocal()
      let oci = try VMStorageOCI()
      for (name, diskFormat) in [("unavailable", DiskImageFormat.asif), ("healthy", .raw)] {
        let remoteName = try RemoteName("example.com/org/\(name):latest")
        for vmDir in [try local.create(name), try oci.create(remoteName)] {
          var vmConfig = config()
          vmConfig.diskFormat = diskFormat
          try vmConfig.save(toURL: vmDir.configURL)
          XCTAssertTrue(FileManager.default.createFile(atPath: vmDir.nvramURL.path, contents: Data()))
          // The diskutil stub simulates a locked ASIF disk without needing a running VM.
          XCTAssertTrue(FileManager.default.createFile(
            atPath: vmDir.diskURL.path,
            contents: Data(repeating: 0, count: 4096)
          ))
          if diskFormat == .asif {
            XCTAssertThrowsError(try vmDir.diskSizeBytes())
          }
        }
      }

      for sourceArguments in [[], ["--source", "local"], ["--source", "oci"]] {
        let json = try await commandOutput(List.self, sourceArguments + ["--format", "json"])
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        XCTAssertEqual(rows.count, sourceArguments.isEmpty ? 4 : 2)
        for row in rows {
          let name = try XCTUnwrap(row["Name"] as? String)
          if name.contains("unavailable") {
            XCTAssertTrue(row["Disk"] is NSNull)
          } else {
            XCTAssertEqual(row["Disk"] as? Int, 0)
          }
          XCTAssertEqual(row["State"] as? String, "stopped")
          XCTAssertEqual(row["Running"] as? Bool, false)
        }

        let text = try await commandOutput(List.self, sourceArguments)
        XCTAssertTrue(text.contains("unavailable"))
        XCTAssertTrue(text.contains("healthy"))
        XCTAssertTrue(text.contains("-"))

        let quiet = try await commandOutput(List.self, sourceArguments + ["--quiet"])
        XCTAssertEqual(quiet.split(separator: "\n").map(String.init), rows.compactMap { $0["Name"] as? String })
      }
    }
  }

  func testGetSurvivesUnavailableDiskCapacity() async throws {
    try await withTemporaryTartHome {
      let previousPath = try installUnavailableDiskutil()
      defer { restoreEnvironment("PATH", to: previousPath) }

      let vmDir = try VMStorageLocal().create("unavailable")
      var vmConfig = config()
      vmConfig.diskFormat = .asif
      try vmConfig.save(toURL: vmDir.configURL)
      XCTAssertTrue(FileManager.default.createFile(atPath: vmDir.nvramURL.path, contents: Data()))
      XCTAssertTrue(FileManager.default.createFile(
        atPath: vmDir.diskURL.path,
        contents: Data(repeating: 0, count: 4096)
      ))
      XCTAssertThrowsError(try vmDir.diskSizeBytes())

      let json = try await commandOutput(Get.self, ["unavailable", "--format", "json"])
      let info = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
      XCTAssertTrue(info["Disk"] is NSNull)
      XCTAssertEqual(info["DiskFormat"] as? String, "asif")
      XCTAssertEqual(info["State"] as? String, "stopped")

      let text = try await commandOutput(Get.self, ["unavailable"])
      XCTAssertTrue(text.contains("asif"))
      XCTAssertTrue(text.contains("-"))
    }
  }

  func testNoUSBAccessoriesDoesNotEnableSuspendable() throws {
    try withTemporaryTartHome {
      let vmDir = try VMStorageLocal().create("no-usb-accessories")
      try config().save(toURL: vmDir.configURL)
      XCTAssertTrue(FileManager.default.createFile(atPath: vmDir.nvramURL.path, contents: Data()))
      XCTAssertTrue(FileManager.default.createFile(atPath: vmDir.diskURL.path, contents: Data()))

      let command = try Run.parseAsRoot(["no-usb-accessories", "--no-usb-accessories"]) as! Run

      XCTAssertTrue(command.noUSBAccessories)
      XCTAssertFalse(command.suspendable)
      XCTAssertFalse(command.noAudio)
      XCTAssertFalse(command.noGraphics)
    }
  }

  func testStandaloneDeleteDoesNotInitializeContentStore() throws {
    try withTemporaryTartHome {
      let vmDir = try VMStorageLocal().create("standalone")
      try config().save(toURL: vmDir.configURL)
      XCTAssertTrue(FileManager.default.createFile(atPath: vmDir.nvramURL.path, contents: Data()))
      XCTAssertTrue(FileManager.default.createFile(atPath: vmDir.diskURL.path, contents: Data()))

      let contentStoreURL = try Config().tartCacheDir.appendingPathComponent("content", isDirectory: true)
      XCTAssertFalse(FileManager.default.fileExists(atPath: contentStoreURL.path))

      try vmDir.delete()

      XCTAssertFalse(FileManager.default.fileExists(atPath: vmDir.baseURL.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: contentStoreURL.path))
    }
  }

  func testSetDiskRejectsStackedVMBeforeSavingConfig() async throws {
    try await withTemporaryTartHome {
      let vmDir = try VMStorageLocal().create("stacked")
      let originalConfig = config()
      try originalConfig.save(toURL: vmDir.configURL)
      XCTAssertTrue(FileManager.default.createFile(atPath: vmDir.nvramURL.path, contents: Data()))
      XCTAssertTrue(FileManager.default.createFile(atPath: vmDir.manifestURL.path, contents: Data()))
      XCTAssertTrue(FileManager.default.createFile(atPath: vmDir.overlayURL.path, contents: Data()))

      let replacementURL = try temporaryDirectory().appendingPathComponent("replacement.img")
      XCTAssertTrue(FileManager.default.createFile(atPath: replacementURL.path, contents: Data("replacement".utf8)))

      let command = try Set.parseAsRoot([
        "stacked",
        "--cpu", "4",
        "--disk", replacementURL.path,
      ]) as! Set

      do {
        try await command.run()
        XCTFail("expected stacked disk replacement to be rejected")
      } catch let error as ValidationError {
        XCTAssertEqual(error.message, "--disk is not supported for VMs with a stacked disk")
      }

      XCTAssertEqual(try VMConfig(fromURL: vmDir.configURL).cpuCount, originalConfig.cpuCount)
      XCTAssertFalse(FileManager.default.fileExists(atPath: vmDir.diskURL.path))
    }
  }

  func testRemoteAdditionalDiskRetainsTemporaryBackingFileLock() throws {
    try withTemporaryTartHome {
      let storage = try VMStorageOCI()
      let name = try RemoteName("example.com/org/image:latest")
      let cachedImage = try storage.create(name)
      try config().save(toURL: cachedImage.configURL)
      XCTAssertTrue(FileManager.default.createFile(atPath: cachedImage.nvramURL.path, contents: Data()))
      XCTAssertTrue(FileManager.default.createFile(
        atPath: cachedImage.diskURL.path,
        contents: Data(repeating: 0, count: 4096)
      ))

      do {
        let additionalDisk = try AdditionalDisk(parseFrom: name.description)
        let entriesBeforeGC = try temporaryEntries()
        XCTAssertEqual(entriesBeforeGC.count, 1)

        try Config().gc()
        XCTAssertEqual(try temporaryEntries(), entriesBeforeGC)

        withExtendedLifetime(additionalDisk) {}
      }

      try Config().gc()
      XCTAssertTrue(try temporaryEntries().isEmpty)
    }
  }

  func testGarbageCollectionPreservesLockedTemporaryDirectory() throws {
    try withTemporaryTartHome {
      let temporaryVMDir = try VMDirectory.temporary()
      let lock = try FileLock(lockURL: temporaryVMDir.baseURL)
      try lock.lock()
      XCTAssertTrue(FileManager.default.createFile(
        atPath: temporaryVMDir.overlayURL.path,
        contents: Data("overlay".utf8)
      ))

      try Config().gc()
      XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryVMDir.overlayURL.path))

      try lock.unlock()
      try Config().gc()
      XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryVMDir.baseURL.path))
    }
  }

  private func config() -> VMConfig {
    VMConfig(
      platform: Linux(),
      cpuCountMin: 2,
      memorySizeMin: 512 * 1024 * 1024,
      diskFormat: .raw
    )
  }

  private func temporaryEntries() throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: Config().tartTmpDir,
      includingPropertiesForKeys: nil
    )
  }

  private func installUnavailableDiskutil() throws -> String? {
    let binDirectory = try temporaryDirectory()
    let diskutilURL = binDirectory.appendingPathComponent("diskutil")
    let script = """
    #!/bin/sh
    echo 'Resource temporarily unavailable' >&2
    exit 1
    """
    try script.write(to: diskutilURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: diskutilURL.path)
    let previousPath = ProcessInfo.processInfo.environment["PATH"]
    setenv("PATH", binDirectory.path, 1)
    return previousPath
  }

  private func commandOutput<Command: AsyncParsableCommand>(
    _ commandType: Command.Type,
    _ arguments: [String]
  ) async throws -> String {
    let outputURL = try temporaryDirectory().appendingPathComponent("stdout")
    XCTAssertTrue(FileManager.default.createFile(atPath: outputURL.path, contents: nil))
    let output = try FileHandle(forWritingTo: outputURL)
    defer { try? output.close() }

    fflush(stdout)
    let savedStdout = dup(STDOUT_FILENO)
    defer {
      fflush(stdout)
      dup2(savedStdout, STDOUT_FILENO)
      close(savedStdout)
    }
    dup2(output.fileDescriptor, STDOUT_FILENO)
    var command = try Command.parseAsRoot(arguments) as! Command
    try await command.run()
    fflush(stdout)
    return try String(contentsOf: outputURL, encoding: .utf8)
  }

  private func withTemporaryTartHome(_ body: () throws -> Void) throws {
    let home = try temporaryDirectory()
    let previousHome = ProcessInfo.processInfo.environment["TART_HOME"]
    setenv("TART_HOME", home.path, 1)
    defer { restoreEnvironment("TART_HOME", to: previousHome) }

    try body()
  }

  private func withTemporaryTartHome(_ body: () async throws -> Void) async throws {
    let home = try temporaryDirectory()
    let previousHome = ProcessInfo.processInfo.environment["TART_HOME"]
    setenv("TART_HOME", home.path, 1)
    defer { restoreEnvironment("TART_HOME", to: previousHome) }

    try await body()
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: url)
    }

    return url
  }

  private func restoreEnvironment(_ name: String, to value: String?) {
    if let value {
      setenv(name, value, 1)
    } else {
      unsetenv(name)
    }
  }
}
