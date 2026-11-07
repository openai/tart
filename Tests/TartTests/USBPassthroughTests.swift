import XCTest
@testable import tart

final class USBPassthroughTests: XCTestCase {
  func testFilterParsing() throws {
    XCTAssertEqual(try USBFilter(parseFrom: "any"), .any)
    XCTAssertEqual(try USBFilter(parseFrom: "05ac:12a8"), .device(vendorID: 0x05ac, productID: 0x12a8))
    XCTAssertEqual(try USBFilter(parseFrom: "05AC:FFFF"), .device(vendorID: 0x05ac, productID: 0xffff))

    for invalid in ["", "05ac", "05ac:", ":12a8", "05ac:12a8:1", "0x05ac:12a8", "10000:12a8", "xyz:12a8"] {
      XCTAssertThrowsError(try USBFilter(parseFrom: invalid), "\"\(invalid)\" should be rejected")
    }
  }

  func testFilterMatching() throws {
    XCTAssertTrue(try USBFilter(parseFrom: "any").matches("1050:0402"))
    XCTAssertTrue(try USBFilter(parseFrom: "1050:402").matches("1050:0402"))
    XCTAssertTrue(try USBFilter(parseFrom: "05AC:12A8").matches("05ac:12a8"))
    XCTAssertFalse(try USBFilter(parseFrom: "1050:0403").matches("1050:0402"))
  }

  @available(macOS 14, *)
  func testSocketRoundTrip() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let workingDirectory = FileManager.default.currentDirectoryPath

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    defer {
      FileManager.default.changeCurrentDirectoryPath(workingDirectory)
      try? FileManager.default.removeItem(at: directory)
    }

    let vmDir = VMDirectory(baseURL: directory)
    let socket = try await USBSocket(vmDir.usbSocketURL) { request in
      USBReply(devices: [USBDeviceInfo(Device: "1050:0402", Name: "YubiKey", Attached: true)], error: request)
    }
    let server = Task { try await socket.run() }

    defer { server.cancel() }

    let reply = try await usbRequest(vmDir, "attach 1050:0402")

    XCTAssertEqual(reply.error, "attach 1050:0402")
    XCTAssertEqual(reply.devices.map(\.Device), ["1050:0402"])
    XCTAssertEqual(reply.devices.map(\.Attached), [true])

    // The working directory still holds that socket, and this request must not reach it
    do {
      _ = try await usbRequest(VMDirectory(baseURL: directory.appendingPathComponent("deleted", isDirectory: true)), "list")
      XCTFail("expected an error")
    } catch {
      XCTAssertTrue("\(error)".contains("has no USB"), "\(error)")
    }
  }

  func testRequestToAVMWithoutUSBFails() async throws {
    let vmDir = VMDirectory(baseURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true))

    do {
      _ = try await usbRequest(vmDir, "list")
      XCTFail("expected an error")
    } catch {
      XCTAssertTrue("\(error)".contains("has no USB"), "\(error)")
    }
  }

  func testDeviceIDFromDescriptor() {
    // The descriptor of a YubiKey, vendor 0x1050 and product 0x0402
    let descriptor = Data([18, 1, 0x00, 0x02, 0, 0, 0, 64, 0x50, 0x10, 0x02, 0x04, 0x74, 0x05, 1, 2, 0, 1])

    XCTAssertEqual(usbDeviceID(descriptor: descriptor), "1050:0402")
    XCTAssertEqual(try USBFilter(parseFrom: usbDeviceID(descriptor: descriptor)), .device(vendorID: 0x1050, productID: 0x0402))
  }
}
