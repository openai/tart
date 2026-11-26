import Foundation
import Network
import XCTest
@testable import tart

final class PushTests: XCTestCase {
  func testPushCachedImageToRepositoryWithoutItsManifest() async throws {
    let server = try MirrorRegistryServer()
    defer { server.stop() }
    let port = try await server.start()

    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: home) }
    let previousHome = ProcessInfo.processInfo.environment["TART_HOME"]
    setenv("TART_HOME", home.path, 1)
    defer {
      if let previousHome {
        setenv("TART_HOME", previousHome, 1)
      } else {
        unsetenv("TART_HOME")
      }
    }

    // An image pulled from one repository and cached locally
    let digest = "sha256:" + String(repeating: "a", count: 64)
    let cachedName = "127.0.0.1:\(port)/source/vm@\(digest)"
    let vmDir = try VMStorageOCI().create(try RemoteName(cachedName))
    try VMConfig(platform: Linux(), cpuCountMin: 2, memorySizeMin: 512 * 1024 * 1024)
      .save(toURL: vmDir.configURL)
    XCTAssertTrue(FileManager.default.createFile(atPath: vmDir.nvramURL.path, contents: Data("nvram".utf8)))
    XCTAssertTrue(FileManager.default.createFile(atPath: vmDir.diskURL.path, contents: Data("disk".utf8)))

    // Pushing it to another repository, which doesn't have its manifest yet
    let command = try Push.parseAsRoot(["--insecure", cachedName, "127.0.0.1:\(port)/mirror/vm:latest"]) as! Push
    try await command.run()

    let requests = server.requests
    XCTAssertTrue(requests.contains("GET /v2/mirror/vm/manifests/\(digest)"), "\(requests)")
    XCTAssertTrue(requests.contains("POST /v2/mirror/vm/blobs/uploads/"), "\(requests)")
    XCTAssertTrue(requests.contains("PUT /v2/mirror/vm/manifests/latest"), "\(requests)")
  }
}

/// A registry that has no manifests and accepts any blob or manifest upload.
private final class MirrorRegistryServer {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "push-test-registry")
  private var receivedRequests: [String] = []

  var requests: [String] {
    queue.sync { receivedRequests }
  }

  init() throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters)
  }

  func start() async throws -> UInt16 {
    try await withCheckedThrowingContinuation { continuation in
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          self.listener.stateUpdateHandler = nil
          continuation.resume(returning: self.listener.port!.rawValue)
        case .failed(let error):
          self.listener.stateUpdateHandler = nil
          continuation.resume(throwing: error)
        default:
          break
        }
      }
      listener.newConnectionHandler = { connection in
        connection.start(queue: self.queue)
        self.receive(connection, buffered: Data())
      }
      listener.start(queue: queue)
    }
  }

  func stop() { listener.cancel() }

  private func receive(_ connection: NWConnection, buffered: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
      let received = buffered + (data ?? Data())
      guard let headerEnd = received.range(of: Data("\r\n\r\n".utf8)) else {
        if error != nil || complete { connection.cancel() }
        else { self.receive(connection, buffered: received) }
        return
      }

      let head = String(decoding: received[..<headerEnd.lowerBound], as: UTF8.self)
      let contentLength = head.split(separator: "\r\n").compactMap { line -> Int? in
        let parts = line.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
        return Int(parts[1].trimmingCharacters(in: .whitespaces))
      }.first ?? 0
      if received.count - headerEnd.upperBound < contentLength && error == nil && !complete {
        self.receive(connection, buffered: received)
        return
      }

      let requestLine = head.split(separator: " ")
      let method = String(requestLine[0])
      let path = String(requestLine[1].split(separator: "?", maxSplits: 1)[0])
      self.receivedRequests.append("\(method) \(path)")

      var status = "404 Not Found"
      var extraHeaders = ""
      if method == "POST" && path.hasSuffix("/blobs/uploads/") {
        status = "202 Accepted"
        extraHeaders = "Location: \(path)\(UUID().uuidString)\r\n"
      } else if method == "PUT" {
        status = "201 Created"
      }
      let response = "HTTP/1.1 \(status)\r\n\(extraHeaders)Content-Length: 0\r\nConnection: close\r\n\r\n"
      connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
  }
}
