import Foundation
import XCTest
@testable import tart

final class IPSWDownloaderTests: XCTestCase {
  private let remoteURL = URL(string: "https://example.test/restore.ipsw")!
  private let body = Data("hello world!".utf8)

  func testInterruptedDownloadResumesAcrossInvocations() async throws {
    let cacheURL = try temporaryCache()
    defer { try? FileManager.default.removeItem(at: cacheURL) }

    let transport = StubTransport(url: remoteURL)
    let digest = Digest.hash(body)
    transport.replies = [
      head(etag: "\"v1\"", digest: digest),
      get(etag: "\"v1\"", chunks: [body.prefix(6)], error: URLError(.networkConnectionLost)),
    ]
    let downloader = IPSWDownloader(cacheURL: cacheURL, maxAttempts: 1, fetch: transport.fetch)

    await expectInterrupted(downloader, cacheURL: cacheURL)

    transport.replies = [
      head(etag: "\"v1\"", digest: digest),
      get(status: 206, etag: "\"v1\"", length: 6,
          range: "bytes 6-11/12", chunks: [body.suffix(6)]),
    ]
    let result = try await downloader.download(remoteURL)

    XCTAssertEqual(try Data(contentsOf: result), body)
    XCTAssertEqual(result.lastPathComponent, digest + ".ipsw")
    XCTAssertEqual(transport.requests.last?.value(forHTTPHeaderField: "Range"), "bytes=6-")
    XCTAssertEqual(transport.requests.last?.value(forHTTPHeaderField: "If-Range"), "\"v1\"")
  }

  func testIgnoredRangeRestartsWithoutAppendingOldBytes() async throws {
    let cacheURL = try temporaryCache()
    defer { try? FileManager.default.removeItem(at: cacheURL) }

    let transport = StubTransport(url: remoteURL)
    transport.replies = [
      head(etag: "\"v1\""),
      get(etag: "\"v1\"", chunks: [body.prefix(6)], error: URLError(.networkConnectionLost)),
    ]
    let downloader = IPSWDownloader(cacheURL: cacheURL, maxAttempts: 1, fetch: transport.fetch)
    await expectInterrupted(downloader, cacheURL: cacheURL)

    transport.replies = [head(etag: "\"v1\""), get(etag: "\"v1\"", chunks: [body])]
    let result = try await downloader.download(remoteURL)

    XCTAssertEqual(transport.requests.last?.value(forHTTPHeaderField: "Range"), "bytes=6-")
    XCTAssertEqual(try Data(contentsOf: result), body)
  }

  func testChangedValidatorDiscardsPartialBeforeRequest() async throws {
    let cacheURL = try temporaryCache()
    defer { try? FileManager.default.removeItem(at: cacheURL) }

    let transport = StubTransport(url: remoteURL)
    transport.replies = [
      head(etag: "\"v1\""),
      get(etag: "\"v1\"", chunks: [body.prefix(6)], error: URLError(.networkConnectionLost)),
    ]
    let downloader = IPSWDownloader(cacheURL: cacheURL, maxAttempts: 1, fetch: transport.fetch)
    await expectInterrupted(downloader, cacheURL: cacheURL)

    transport.replies = [head(etag: "\"v2\""), get(etag: "\"v2\"", chunks: [body])]
    let result = try await downloader.download(remoteURL)

    XCTAssertNil(transport.requests.last?.value(forHTTPHeaderField: "Range"))
    XCTAssertEqual(try Data(contentsOf: result), body)
  }

  func testInvalidContentRangeRetriesFromZero() async throws {
    let cacheURL = try temporaryCache()
    defer { try? FileManager.default.removeItem(at: cacheURL) }

    let transport = StubTransport(url: remoteURL)
    transport.replies = [
      head(etag: "\"v1\""),
      get(etag: "\"v1\"", chunks: [body.prefix(6)], error: URLError(.networkConnectionLost)),
    ]
    let downloader = IPSWDownloader(cacheURL: cacheURL, maxAttempts: 1, fetch: transport.fetch)
    await expectInterrupted(downloader, cacheURL: cacheURL)

    transport.replies = [
      head(etag: "\"v1\""),
      get(status: 206, etag: "\"v1\"", length: 6,
          range: "bytes 5-10/12", chunks: [body.suffix(6)]),
      get(etag: "\"v1\"", chunks: [body]),
    ]
    let result = try await downloader.download(remoteURL)

    XCTAssertNil(transport.requests.last?.value(forHTTPHeaderField: "Range"))
    XCTAssertEqual(try Data(contentsOf: result), body)
  }

  func testDigestMismatchDoesNotPromoteFile() async throws {
    let cacheURL = try temporaryCache()
    defer { try? FileManager.default.removeItem(at: cacheURL) }

    let transport = StubTransport(url: remoteURL)
    transport.replies = [
      head(etag: "\"v1\"", digest: Digest.hash(Data("different".utf8))),
      get(etag: "\"v1\"", chunks: [body]),
    ]
    let downloader = IPSWDownloader(cacheURL: cacheURL, maxAttempts: 1, fetch: transport.fetch)

    do {
      _ = try await downloader.download(remoteURL)
      XCTFail("The mismatched SHA-256 should fail")
    } catch {
      XCTAssertTrue(String(describing: error).contains("digest"))
    }
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: cacheURL.path)
      .contains { $0.hasSuffix(".ipsw") })
  }

  func testTransientFailureRetriesWithBoundedPause() async throws {
    let cacheURL = try temporaryCache()
    defer { try? FileManager.default.removeItem(at: cacheURL) }

    let transport = StubTransport(url: remoteURL)
    transport.replies = [
      head(etag: "\"v1\""),
      get(etag: "\"v1\"", chunks: [body.prefix(6)], error: URLError(.networkConnectionLost)),
      head(etag: "\"v1\""),
      get(status: 206, etag: "\"v1\"", length: 6,
          range: "bytes 6-11/12", chunks: [body.suffix(6)]),
    ]
    let pauses = PauseRecorder()
    let downloader = IPSWDownloader(cacheURL: cacheURL, maxAttempts: 2,
                                    fetch: transport.fetch, pause: { pauses.delays.append($0) })

    let result = try await downloader.download(remoteURL)

    XCTAssertEqual(try Data(contentsOf: result), body)
    XCTAssertEqual(pauses.delays, [1_000_000_000])
    XCTAssertEqual(transport.requests.last?.value(forHTTPHeaderField: "Range"), "bytes=6-")
  }

  func testStalePartialIsRemoved() async throws {
    let cacheURL = try temporaryCache()
    defer { try? FileManager.default.removeItem(at: cacheURL) }

    let staleURL = cacheURL.appendingPathComponent(".stale.partial")
    let metadataURL = staleURL.appendingPathExtension("json")
    try Data("old".utf8).write(to: staleURL)
    try Data("{}".utf8).write(to: metadataURL)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 24 * 60 * 60)],
                                          ofItemAtPath: staleURL.path)

    let transport = StubTransport(url: remoteURL)
    transport.replies = [head(etag: "\"v1\""), get(etag: "\"v1\"", chunks: [body])]
    let downloader = IPSWDownloader(cacheURL: cacheURL, maxAttempts: 1, fetch: transport.fetch)

    _ = try await downloader.download(remoteURL)

    XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: metadataURL.path))
  }

  private func temporaryCache() throws -> URL {
    let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
    return cacheURL
  }

  private func expectInterrupted(_ downloader: IPSWDownloader, cacheURL: URL) async {
    do {
      _ = try await downloader.download(remoteURL)
      XCTFail("The interrupted transfer should fail")
    } catch let error as URLError {
      XCTAssertEqual(error.code, .networkConnectionLost)
    } catch {
      XCTFail("Expected a network interruption, got \(error)")
    }

    do {
      let partials = try FileManager.default.contentsOfDirectory(at: cacheURL,
                                                                 includingPropertiesForKeys: [.fileSizeKey])
        .filter { $0.lastPathComponent.hasSuffix(".partial") }
      XCTAssertEqual(partials.count, 1)
      XCTAssertEqual(try partials.first?.resourceValues(forKeys: [.fileSizeKey]).fileSize, 6)
    } catch {
      XCTFail("Could not inspect partial download: \(error)")
    }
  }

  private func head(etag: String, digest: String? = nil) -> StubTransport.Reply {
    var headers = ["ETag": etag, "Content-Length": "12"]
    if let digest { headers["x-amz-meta-digest-sha256"] = String(digest.dropFirst("sha256:".count)) }
    return .init(status: 200, headers: headers)
  }

  private func get(status: Int = 200, etag: String, length: Int = 12,
                   range: String? = nil, chunks: [Data], error: Error? = nil) -> StubTransport.Reply {
    var headers = ["ETag": etag, "Content-Length": String(length)]
    if let range { headers["Content-Range"] = range }
    return .init(status: status, headers: headers, chunks: chunks, error: error)
  }
}

private final class PauseRecorder {
  var delays: [UInt64] = []
}

private final class StubTransport {
  struct Reply {
    let status: Int
    let headers: [String: String]
    let chunks: [Data]
    let error: Error?

    init(status: Int, headers: [String: String], chunks: [Data] = [], error: Error? = nil) {
      self.status = status
      self.headers = headers
      self.chunks = chunks
      self.error = error
    }
  }

  let url: URL
  var requests: [URLRequest] = []
  var replies: [Reply] = []

  init(url: URL) { self.url = url }

  func fetch(_ request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
    requests.append(request)
    let reply = replies.removeFirst()
    let response = HTTPURLResponse(url: url, statusCode: reply.status,
                                   httpVersion: "HTTP/1.1", headerFields: reply.headers)!
    let stream = AsyncThrowingStream<Data, Error> { continuation in
      for chunk in reply.chunks { continuation.yield(chunk) }
      if let error = reply.error {
        continuation.finish(throwing: error)
      } else {
        continuation.finish()
      }
    }
    return (stream, response)
  }
}
