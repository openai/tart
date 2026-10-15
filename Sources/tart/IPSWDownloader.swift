import Foundation

struct IPSWDownloader {
  typealias Fetch = (URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse)
  typealias Pause = (UInt64) async throws -> Void

  private struct Partial: Codable {
    let validator: String
    let length: Int64
    let digest: String?
  }

  private let cacheURL: URL
  private let fetch: Fetch
  private let pause: Pause
  private let maxAttempts: Int
  private let staleAfter: TimeInterval = 7 * 24 * 60 * 60

  init(
    cacheURL: URL,
    maxAttempts: Int = 4,
    fetch: @escaping Fetch = { request in try await Fetcher.fetch(request, viaFile: request.httpMethod != "HEAD") },
    pause: @escaping Pause = { try await Task.sleep(nanoseconds: $0) }
  ) {
    self.cacheURL = cacheURL
    self.maxAttempts = maxAttempts
    self.fetch = fetch
    self.pause = pause
  }

  func download(_ remoteURL: URL) async throws -> URL {
    try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
    try removeStalePartials()

    let key = String(Digest.hash(Data(remoteURL.absoluteString.utf8)).dropFirst("sha256:".count))
    let partialURL = cacheURL.appendingPathComponent(".\(key).partial")
    let metadataURL = partialURL.appendingPathExtension("json")
    let lockURL = partialURL.appendingPathExtension("lock")
    if !FileManager.default.fileExists(atPath: lockURL.path) {
      FileManager.default.createFile(atPath: lockURL.path, contents: nil)
    }
    let lock = try FileLock(lockURL: lockURL)
    try lock.lock()
    defer { try? lock.unlock() }

    for attempt in 0..<maxAttempts {
      try Task.checkCancellation()
      do {
        return try await downloadAttempt(remoteURL, partialURL: partialURL, metadataURL: metadataURL)
      } catch {
        guard attempt + 1 < maxAttempts, Self.isTransient(error) else { throw error }
        try await pause(UInt64(1 << attempt) * 1_000_000_000)
      }
    }

    throw RuntimeError.Generic("IPSW download exhausted its retry limit")
  }

  private func downloadAttempt(_ remoteURL: URL, partialURL: URL, metadataURL: URL) async throws -> URL {
    var headRequest = URLRequest(url: remoteURL, cachePolicy: .reloadIgnoringLocalCacheData)
    headRequest.httpMethod = "HEAD"
    let (_, head) = try await fetch(headRequest)
    // Some download servers reject HEAD while serving GET. Keep those URLs usable,
    // but do not resume without a validator confirmed by HEAD.
    let headIsUsable = (200..<300).contains(head.statusCode)
    let headLength = headIsUsable ? Self.contentLength(head) : nil
    let headValidator = headIsUsable ? Self.validator(head) : nil
    let headDigest = headIsUsable ? Self.expectedDigest(head) : nil

    if let headDigest {
      let cachedURL = cacheURL.appendingPathComponent(headDigest + ".ipsw")
      if FileManager.default.fileExists(atPath: cachedURL.path) {
        defaultLogger.appendNewLine("Using cached *.ipsw file...")
        try cachedURL.updateAccessDate()
        return cachedURL
      }
    }

    var partial = (try? Data(contentsOf: metadataURL)).flatMap { try? JSONDecoder().decode(Partial.self, from: $0) }
    var offset = (try? fileLength(partialURL)) ?? 0
    if offset > 0 && (partial == nil || partial?.validator != headValidator ||
      (headLength != nil && partial?.length != headLength) ||
      (headDigest != nil && partial?.digest != headDigest) || offset > (partial?.length ?? 0)) {
      try discard(partialURL, metadataURL)
      partial = nil
      offset = 0
    }

    if offset > 0, let partial, offset == partial.length {
      return try promote(partialURL, metadataURL, length: partial.length, expectedDigest: partial.digest ?? headDigest)
    }

    defaultLogger.appendNewLine("Fetching \(remoteURL.lastPathComponent)...")
    for _ in 0..<2 {
      var request = URLRequest(url: remoteURL, cachePolicy: .reloadIgnoringLocalCacheData)
      if offset > 0, let partial {
        request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        request.setValue(partial.validator, forHTTPHeaderField: "If-Range")
      }

      let (channel, response) = try await fetch(request)
      if offset > 0 && response.statusCode == 200 {
        // If-Range was not satisfied or the server ignored Range. The body is a complete replacement.
        try discard(partialURL, metadataURL)
        offset = 0
        partial = nil
      } else if offset > 0 && response.statusCode == 206 {
        guard let partial,
              Self.validRange(response, offset: offset, length: partial.length),
              Self.validator(response) == partial.validator else {
          try discard(partialURL, metadataURL)
          offset = 0
          partial = nil
          continue
        }
      } else if offset > 0 && response.statusCode == 416 {
        try discard(partialURL, metadataURL)
        offset = 0
        partial = nil
        continue
      } else if response.statusCode != 200 {
        throw RuntimeError.Generic("IPSW GET request returned HTTP \(response.statusCode)")
      }

      let length = partial?.length ?? Self.contentLength(response) ?? headLength
      guard let length, length > 0, offset <= length else {
        throw RuntimeError.Generic("IPSW response has no valid content length")
      }
      let responseDigest = Self.expectedDigest(response) ?? headDigest

      if offset == 0 {
        guard let validator = Self.validator(response) else {
          // Without a validator, the partial file cannot be safely reused across attempts.
          try discard(partialURL, metadataURL)
          let digest = try await write(channel, to: partialURL, offset: 0, length: length)
          return try promote(partialURL, metadataURL, length: length,
                             expectedDigest: responseDigest, computedDigest: digest)
        }
        partial = Partial(validator: validator, length: length, digest: responseDigest)
        try JSONEncoder().encode(partial).write(to: metadataURL, options: .atomic)
      }

      let digest = try await write(channel, to: partialURL, offset: offset, length: length)
      return try promote(partialURL, metadataURL, length: length,
                         expectedDigest: responseDigest, computedDigest: digest)
    }

    throw RuntimeError.Generic("IPSW server returned an invalid range response")
  }

  private func write(_ channel: AsyncThrowingStream<Data, Error>, to url: URL, offset: Int64, length: Int64) async throws -> String {
    let digest = Digest()
    if offset > 0 {
      let reader = try FileHandle(forReadingFrom: url)
      defer { try? reader.close() }
      var remaining = offset
      while remaining > 0 {
        guard let chunk = try reader.read(upToCount: Int(min(remaining, 4 * 1024 * 1024))), !chunk.isEmpty else {
          throw RuntimeError.Generic("IPSW partial file ended before its recorded length")
        }
        digest.update(chunk)
        remaining -= Int64(chunk.count)
      }
    }

    if offset == 0 {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(offset))

    let progress = Progress(totalUnitCount: length)
    progress.completedUnitCount = offset
    ProgressObserver(progress).log(defaultLogger)

    for try await chunk in channel {
      guard Int64(chunk.count) <= length - progress.completedUnitCount else {
        throw RuntimeError.Generic("IPSW response exceeded its advertised length")
      }
      try handle.write(contentsOf: chunk)
      digest.update(chunk)
      progress.completedUnitCount += Int64(chunk.count)
    }
    guard progress.completedUnitCount == length else {
      throw RuntimeError.Generic("IPSW response ended before its advertised length")
    }
    return digest.finalize()
  }

  private func promote(_ partialURL: URL, _ metadataURL: URL, length: Int64,
                       expectedDigest: String?, computedDigest: String? = nil) throws -> URL {
    guard try fileLength(partialURL) == length else {
      throw RuntimeError.Generic("IPSW file length does not match its response")
    }
    let digest = try computedDigest ?? Digest.hash(partialURL)
    if let expectedDigest, digest != expectedDigest {
      try discard(partialURL, metadataURL)
      throw RuntimeError.Generic("IPSW digest does not match the server's SHA-256")
    }

    let finalURL = cacheURL.appendingPathComponent(digest + ".ipsw")
    _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: partialURL)
    try? FileManager.default.removeItem(at: metadataURL)
    return finalURL
  }

  private func discard(_ partialURL: URL, _ metadataURL: URL) throws {
    if FileManager.default.fileExists(atPath: partialURL.path) {
      try FileManager.default.removeItem(at: partialURL)
    }
    if FileManager.default.fileExists(atPath: metadataURL.path) {
      try FileManager.default.removeItem(at: metadataURL)
    }
  }

  private func fileLength(_ url: URL) throws -> Int64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let size = attributes[.size] as? NSNumber else {
      throw RuntimeError.Generic("Could not read IPSW file size")
    }
    return size.int64Value
  }

  private func removeStalePartials() throws {
    let cutoff = Date().addingTimeInterval(-staleAfter)
    for partialURL in try FileManager.default.contentsOfDirectory(at: cacheURL,
                                                                  includingPropertiesForKeys: [.contentModificationDateKey])
      where partialURL.lastPathComponent.hasSuffix(".partial") {
      let modified = try partialURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
      guard let modified, modified < cutoff else { continue }

      let lockURL = partialURL.appendingPathExtension("lock")
      if !FileManager.default.fileExists(atPath: lockURL.path) {
        FileManager.default.createFile(atPath: lockURL.path, contents: nil)
      }
      let lock = try FileLock(lockURL: lockURL)
      if try lock.trylock() {
        defer { try? lock.unlock() }
        try discard(partialURL, partialURL.appendingPathExtension("json"))
      }
    }
  }

  private static func contentLength(_ response: HTTPURLResponse) -> Int64? {
    response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
  }

  private static func validator(_ response: HTTPURLResponse) -> String? {
    if let etag = response.value(forHTTPHeaderField: "ETag"), !etag.hasPrefix("W/") {
      return etag
    }
    return response.value(forHTTPHeaderField: "Last-Modified")
  }

  private static func expectedDigest(_ response: HTTPURLResponse) -> String? {
    guard var value = response.value(forHTTPHeaderField: "x-amz-meta-digest-sha256")?.lowercased() else { return nil }
    if value.hasPrefix("sha256:") { value.removeFirst("sha256:".count) }
    guard value.count == 64, value.allSatisfy({ $0.isHexDigit }) else { return nil }
    return "sha256:" + value
  }

  private static func validRange(_ response: HTTPURLResponse, offset: Int64, length: Int64) -> Bool {
    guard let header = response.value(forHTTPHeaderField: "Content-Range"), header.hasPrefix("bytes ") else { return false }
    let values = header.dropFirst("bytes ".count).split(omittingEmptySubsequences: false) { $0 == "-" || $0 == "/" }
    guard values.count == 3,
          let start = Int64(values[0]), let end = Int64(values[1]), let total = Int64(values[2]),
          start == offset, end == length - 1, total == length else { return false }
    return contentLength(response) == length - offset
  }

  private static func isTransient(_ error: Error) -> Bool {
    guard let urlError = error as? URLError else { return false }
    switch urlError.code {
    case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
         .cannotFindHost, .secureConnectionFailed, .dnsLookupFailed:
      return true
    default:
      return false
    }
  }
}
