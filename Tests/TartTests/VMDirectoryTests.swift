import Foundation
import Virtualization
import XCTest
@testable import tart

final class VMDirectoryTests: XCTestCase {

  func testRegenerateLinuxMachineIdentifierReplacesIdentifierAndDeletesState() throws {
    let vmDir = try temporaryVMDirectory()
    let originalIdentifier = VZGenericMachineIdentifier()
    let originalConfig = try writeLinuxConfig(machineIdentifier: originalIdentifier, to: vmDir)
    try touch(vmDir.stateURL)

    try vmDir.regenerateLinuxMachineIdentifier()

    let config = try VMConfig(fromURL: vmDir.configURL)
    let linux = try XCTUnwrap(config.platform as? Linux)
    let newIdentifier = try XCTUnwrap(linux.machineIdentifier)
    XCTAssertNotEqual(newIdentifier.dataRepresentation, originalIdentifier.dataRepresentation)
    XCTAssertFalse(FileManager.default.fileExists(atPath: vmDir.stateURL.path))
    XCTAssertEqual(config.macAddress.string, originalConfig.macAddress.string)
  }

  func testRegenerateLinuxMachineIdentifierAssignsMissingIdentifier() throws {
    let vmDir = try temporaryVMDirectory()
    try writeLinuxConfig(machineIdentifier: nil, to: vmDir)

    try vmDir.regenerateLinuxMachineIdentifier()

    let linux = try XCTUnwrap(VMConfig(fromURL: vmDir.configURL).platform as? Linux)
    XCTAssertNotNil(linux.machineIdentifier)
  }

  @discardableResult
  private func writeLinuxConfig(machineIdentifier: VZGenericMachineIdentifier?, to vmDir: VMDirectory) throws -> VMConfig {
    var linux = Linux()
    linux.machineIdentifier = machineIdentifier
    let config = VMConfig(platform: linux, cpuCountMin: 2, memorySizeMin: 1024 * 1024 * 1024)
    try config.save(toURL: vmDir.configURL)
    return config
  }

  private func temporaryVMDirectory() throws -> VMDirectory {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: url)
    }

    return VMDirectory(baseURL: url)
  }

  private func touch(_ url: URL) throws {
    XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
  }
}
