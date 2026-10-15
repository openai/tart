import Foundation
import Network
import XCTest
@testable import tart

final class RegistryRealmTests: XCTestCase {
  func testPreservesRealmQueryParameters() async throws {
    try await checkAuthentication(mode: "preserve")
  }

  func testChallengeReplacesOnlyItsOwnQueryParameters() async throws {
    try await checkAuthentication(mode: "replace")
  }

  func testRealmWithoutQueryParameters() async throws {
    try await checkAuthentication(mode: "plain")
  }

  func testPreservesOriginalPercentEncodingAndReplacesEncodedChallengeKeys() async throws {
    try await checkAuthentication(mode: "encoded")
  }

  private func checkAuthentication(mode: String) async throws {
    let server = try RealmTokenServer(mode: mode)
    defer { server.stop() }
    let port = try await server.start()
    let registry = try Registry(host: "127.0.0.1:\(port)", namespace: "org/repo", insecure: true, credentialsProviders: [])
    try await registry.ping()
  }
}

private final class RealmTokenServer {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "registry-realm-test")
  private let mode: String

  init(mode: String) throws {
    self.mode = mode
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
      let request = String(decoding: received, as: UTF8.self)
      let target = request.split(separator: " ")[1]
      let url = URL(string: "http://127.0.0.1:\(self.listener.port!.rawValue)\(target)")!
      var status = "200 OK"
      var extraHeaders = ""
      var body = "{}"
      if url.path == "/v2" || url.path == "/v2/" {
        if !request.lowercased().contains("authorization: bearer test-token\r\n") {
          let query: String
          switch self.mode {
          case "plain": query = ""
          case "encoded": query = "?tenant=alpha%2Bbeta&escape=%7e%2f&mode=one&mode=two&empty="
          default: query = "?tenant=alpha%26beta&mode=one&mode=two&empty="
          }
          let stale = self.mode == "replace" ? "&scope=old&service=old" :
            (self.mode == "encoded" ? "&sc%6Fpe=old&service=old" : "")
          let realm = "http://127.0.0.1:\(self.listener.port!.rawValue)/token\(query)\(stale)"
          status = "401 Unauthorized"
          extraHeaders = "WWW-Authenticate: Bearer realm=\"\(realm)\",service=\"registry\",scope=\"repository:org/repo:pull\"\r\n"
        }
      } else if url.path == "/token" {
        let receivedURL = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let items = receivedURL.queryItems ?? []
        let values = { (name: String) in items.filter { $0.name == name }.map { $0.value ?? "" } }
        let expectedRaw = "tenant=alpha%2Bbeta&escape=%7e%2f&mode=one&mode=two&empty=&"
        let encodedValid = receivedURL.percentEncodedQuery?.hasPrefix(expectedRaw) == true &&
          values("tenant") == ["alpha+beta"] && values("escape") == ["~/"]
        let normalValid = values("tenant") == ["alpha&beta"]
        let valid = values("service") == ["registry"] && values("scope") == ["repository:org/repo:pull"] &&
          (self.mode == "plain" || ((self.mode == "encoded" ? encodedValid : normalValid) &&
              values("mode") == ["one", "two"] && values("empty") == [""]))
        status = valid ? "200 OK" : "400 Bad Request"
        body = valid ? "{\"token\":\"test-token\"}" : "{\"error\":\"missing or changed realm parameters\"}"
      } else {
        status = "404 Not Found"
      }
      let response = "HTTP/1.1 \(status)\r\n\(extraHeaders)Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
      connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
  }
}
