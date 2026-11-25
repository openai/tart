import XCTest
@testable import tart

final class DockerConfigTests: XCTestCase {
  func testHelpers() throws {
    let config = DockerConfig(credHelpers: [
      "(.*).dkr.ecr.(.*).amazonaws.com": "ecr-login",
      "gcr.io": "gcloud"
    ])

    XCTAssertEqual(try config.findCredHelper(host: "gcr.io"), "gcloud")
    XCTAssertEqual(try config.findCredHelper(host: "123.dkr.ecr.eu-west-1.amazonaws.com"), "ecr-login")
    XCTAssertEqual(try config.findCredHelper(host: "456.dkr.ecr.us-east-1.amazonaws.com"), "ecr-login")
    XCTAssertNil(try config.findCredHelper(host: "ghcr.io"))
  }

  func testAuthPasswordWithColons() throws {
    let auth = Data("user:token:with:colons".utf8).base64EncodedString()
    let credentials = try XCTUnwrap(DockerAuthConfig(auth: auth).decodeCredentials())

    XCTAssertEqual(credentials.0, "user")
    XCTAssertEqual(credentials.1, "token:with:colons")
  }

  func testDockerHubAuthUnderIndexServerAddress() throws {
    let auth = Data("user:password".utf8).base64EncodedString()
    let config = DockerConfig(auths: ["https://index.docker.io/v1/": DockerAuthConfig(auth: auth)])

    for host in ["docker.io", "Docker.IO"] {
      let credentials = try XCTUnwrap(config.findAuth(host: host)?.decodeCredentials(), host)

      XCTAssertEqual(credentials.0, "user")
      XCTAssertEqual(credentials.1, "password")
    }

    XCTAssertNil(config.findAuth(host: "ghcr.io"))
    XCTAssertNil(config.findAuth(host: "index.docker.io"))
  }

  func testExactAuthTakesPrecedence() throws {
    let exactAuth = DockerAuthConfig(auth: Data("exact:password".utf8).base64EncodedString())
    let indexAuth = DockerAuthConfig(auth: Data("index:password".utf8).base64EncodedString())
    let config = DockerConfig(auths: [
      "docker.io": exactAuth,
      "https://index.docker.io/v1/": indexAuth,
    ])

    XCTAssertEqual(config.findAuth(host: "docker.io")?.decodeCredentials()?.0, "exact")
  }

  func testHelperStderrIsNotParsed() throws {
    let helperDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: helperDir, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: helperDir)
    }

    let helperURL = helperDir.appendingPathComponent("docker-credential-test")
    try """
    #!/bin/sh
    read host
    echo "WARNING: some warning" >&2
    echo '{"Username":"user","Secret":"secret"}'
    """.write(to: helperURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)

    let previousPath = ProcessInfo.processInfo.environment["PATH"]
    setenv("PATH", "\(helperDir.path):\(previousPath ?? "")", 1)
    defer {
      if let previousPath {
        setenv("PATH", previousPath, 1)
      } else {
        unsetenv("PATH")
      }
    }

    let credentials = try XCTUnwrap(DockerConfigCredentialsProvider().executeHelper(binaryName: "docker-credential-test", host: "example.com"))

    XCTAssertEqual(credentials.0, "user")
    XCTAssertEqual(credentials.1, "secret")
  }
}
