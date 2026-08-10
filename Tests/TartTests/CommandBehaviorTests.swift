import Foundation
import ArgumentParser
import XCTest
@testable import tart

final class CommandBehaviorTests: XCTestCase {
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
