import Foundation
import Network
import XCTest
@testable import tart

final class RegistryManifestDigestTests: XCTestCase {
  func testPullManifestByDigestRejectsDifferentManifest() async throws {
    let manifestData = try OCIManifest(config: OCIManifestConfig(size: 2, digest: Digest.hash(Data("{}".utf8))), layers: []).toJSON()
    let manifestDigest = Digest.hash(manifestData)
    let otherDigest = Digest.hash(Data("another manifest".utf8))

    let server = try ManifestServer(manifest: manifestData)
    defer { server.stop() }
    let port = try await server.start()
    let registry = try Registry(host: "127.0.0.1:\(port)", namespace: "org/repo", insecure: true, credentialsProviders: [])

    let (_, pulledByDigest) = try await registry.pullManifest(reference: manifestDigest)
    XCTAssertEqual(pulledByDigest, manifestData)

    let (_, pulledByTag) = try await registry.pullManifest(reference: "latest")
    XCTAssertEqual(pulledByTag, manifestData)

    do {
      _ = try await registry.pullManifest(reference: otherDigest)
      XCTFail("a manifest with another digest should be rejected")
    } catch RegistryError.ManifestDigestMismatch(let expected, let actual) {
      XCTAssertEqual(expected, otherDigest)
      XCTAssertEqual(actual, manifestDigest)
    }
  }
}

/// Answers every request with the same manifest, whichever reference was asked for.
private final class ManifestServer {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "registry-manifest-digest-test")
  private let manifest: Data

  init(manifest: Data) throws {
    self.manifest = manifest
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
      guard received.range(of: Data("\r\n\r\n".utf8)) != nil else {
        if error != nil || complete { connection.cancel() }
        else { self.receive(connection, buffered: received) }
        return
      }
      let head = "HTTP/1.1 200 OK\r\nContent-Type: \(ociManifestMediaType)\r\nContent-Length: \(self.manifest.count)\r\nConnection: close\r\n\r\n"
      connection.send(content: Data(head.utf8) + self.manifest, completion: .contentProcessed { _ in connection.cancel() })
    }
  }
}
