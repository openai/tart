import XCTest
@testable import tart

final class RegistryHostTests: XCTestCase {
  func testDockerHub() throws {
    let credentialsProvider = RecordingCredentialsProvider()
    let registry = try Registry(host: "docker.io", namespace: "org/repo",
                                credentialsProviders: [credentialsProvider])

    // docker.io redirects to Docker's website, so the API
    // requests should go to registry-1.docker.io instead
    XCTAssertEqual(registry.baseURL, URL(string: "https://registry-1.docker.io/v2/"))

    // ...while naming and credentials lookup should still use the host specified by the user
    XCTAssertEqual(registry.host, "docker.io")
    XCTAssertNil(try registry.lookupCredentials())
    XCTAssertEqual(credentialsProvider.requestedHosts, ["docker.io"])
  }

  func testDockerHubIsMatchedCaseInsensitively() throws {
    let credentialsProvider = RecordingCredentialsProvider()
    let registry = try Registry(host: "Docker.IO", namespace: "org/repo",
                                credentialsProviders: [credentialsProvider])

    XCTAssertEqual(registry.baseURL, URL(string: "https://registry-1.docker.io/v2/"))
    XCTAssertEqual(registry.host, "Docker.IO")
    XCTAssertNil(try registry.lookupCredentials())
    XCTAssertEqual(credentialsProvider.requestedHosts, ["Docker.IO"])
  }

  func testOtherHostsAreUnchanged() throws {
    for host in ["ghcr.io", "index.docker.io", "registry-1.docker.io", "registry.hub.docker.com", "127.0.0.1:8080"] {
      let registry = try Registry(host: host, namespace: "org/repo")

      XCTAssertEqual(registry.baseURL, URL(string: "https://\(host)/v2/"))
      XCTAssertEqual(registry.host, host)
    }

    let registry = try Registry(host: "127.0.0.1:5000", namespace: "org/repo", insecure: true)
    XCTAssertEqual(registry.baseURL, URL(string: "http://127.0.0.1:5000/v2/"))
    XCTAssertEqual(registry.host, "127.0.0.1:5000")
  }
}

fileprivate class RecordingCredentialsProvider: CredentialsProvider {
  let userFriendlyName = "recording credentials provider"

  var requestedHosts: [String] = []

  func retrieve(host: String) throws -> (String, String)? {
    requestedHosts.append(host)

    return nil
  }

  func store(host: String, user: String, password: String) throws {
  }
}
