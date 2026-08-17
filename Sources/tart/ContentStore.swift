import Foundation

enum ContentStoreError: Error, Equatable {
  case invalidContentDigest(String)
  case contentDigestMismatch(expected: String, actual: String)
}

/// Opaque content-addressed storage for immutable reconstructed files.
///
/// Stacked disks currently use it for complete base disks and published ASIF
/// overlays reconstructed from Tart disk chunks. OCI blob digests may differ
/// across registries, so the key is the full reconstructed-file digest.
struct ContentStore {
  private static let digestAlgorithm = "sha256"
  private static let digestPrefix = "\(digestAlgorithm):"

  let baseURL: URL
  private let digestDirectoryURL: URL
  private let pruneLockURL: URL

  init() throws {
    try self.init(baseURL: Config().tartCacheDir.appendingPathComponent("content", isDirectory: true))
  }

  init(baseURL: URL) throws {
    self.baseURL = baseURL
    self.digestDirectoryURL = baseURL.appendingPathComponent(Self.digestAlgorithm, isDirectory: true)
    self.pruneLockURL = baseURL.appendingPathComponent(".gc.lock")
    try FileManager.default.createDirectory(at: digestDirectoryURL, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: pruneLockURL.path) {
      _ = FileManager.default.createFile(atPath: pruneLockURL.path, contents: Data())
    }
  }

  /// Serializes reference publication with the final reference check and
  /// deletion of immutable cache entries across Tart processes.
  func withPruneLock<T>(_ body: () throws -> T) throws -> T {
    let lock = try FileLock(lockURL: pruneLockURL)
    try lock.lock()
    defer { try? lock.unlock() }

    return try body()
  }

  /// Waits for any prune already scanning references to finish. After this
  /// returns, later prune runs can see a reference the caller already wrote.
  func synchronizePublishedReferences() throws {
    try withPruneLock {}
  }

  func contentURL(for contentDigest: String) throws -> URL {
    try contentURL(for: contentDigest, under: baseURL)
  }

  /// Returns the canonical path for a digest under an arbitrary content-store
  /// root without creating directories or lock files.
  func contentURL(for contentDigest: String, under baseURL: URL) throws -> URL {
    let digestHex = try validatedDigestHex(contentDigest)

    return baseURL
      .appendingPathComponent(Self.digestAlgorithm, isDirectory: true)
      .appendingPathComponent(digestHex)
  }

  func temporaryContentURL(for contentDigest: String) throws -> URL {
    let targetURL = try contentURL(for: contentDigest)

    return targetURL.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
  }

  /// Returns a stable staging path so an interrupted registry pull can resume
  /// reconstructing this content entry on a later attempt.
  func resumableContentURL(for contentDigest: String) throws -> URL {
    let targetURL = try contentURL(for: contentDigest)

    return targetURL.deletingLastPathComponent().appendingPathComponent(".\(targetURL.lastPathComponent).partial")
  }

  /// Returns a stable lock file for serializing reconstruction of one content
  /// entry. The file is intentionally retained; flock state lives on the file
  /// descriptor and disappears when the owning process exits.
  func lockURL(for contentDigest: String) throws -> URL {
    let targetURL = try contentURL(for: contentDigest)

    let lockURL = targetURL.deletingLastPathComponent().appendingPathComponent(".\(targetURL.lastPathComponent).lock")
    if !FileManager.default.fileExists(atPath: lockURL.path) {
      _ = FileManager.default.createFile(atPath: lockURL.path, contents: nil)
    }

    return lockURL
  }

  /// Returns an immutable digest-addressed entry without rereading it. Files
  /// are verified when installed and when deciding whether a pull is a cache
  /// hit; normal clone/run/push paths trust the store like Tart's disk.img.
  func contentURLIfPresent(for contentDigest: String) throws -> URL? {
    let url = try contentURL(for: contentDigest)

    guard FileManager.default.fileExists(atPath: url.path) else {
      return nil
    }

    try url.updateAccessDate()

    return url
  }

  /// Returns a validated cache hit. Corrupt files are treated as misses so a
  /// later pull can safely rebuild them.
  func existingContentURL(for contentDigest: String) throws -> URL? {
    guard let url = try contentURLIfPresent(for: contentDigest) else {
      return nil
    }

    guard try Digest.hash(url) == contentDigest else {
      return nil
    }

    return url
  }

  /// Returns immutable content files that no retained cached image or local VM
  /// references. Callers may prune these like other cache entries.
  func prunables(excluding referencedContentDigests: Swift.Set<String>) throws -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
      at: digestDirectoryURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsSubdirectoryDescendants]
    ) else {
      return []
    }

    return try enumerator.compactMap { element in
      guard let url = element as? URL,
            try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
        return nil
      }

      let contentDigest = "\(Self.digestPrefix)\(url.lastPathComponent)"
      guard (try? validatedDigestHex(contentDigest)) != nil,
            !referencedContentDigests.contains(contentDigest) else {
        return nil
      }

      return url
    }
  }

  /// Move a fully reconstructed temporary file into the cache after verifying
  /// its semantic identity. The caller should create the temporary file with
  /// temporaryContentURL(for:) or resumableContentURL(for:) so rename stays on
  /// the same filesystem.
  func install(_ temporaryURL: URL, contentDigest: String) throws -> URL {
    let actualDigest = try Digest.hash(temporaryURL)
    guard actualDigest == contentDigest else {
      throw ContentStoreError.contentDigestMismatch(expected: contentDigest, actual: actualDigest)
    }

    let targetURL = try contentURL(for: contentDigest)
    let lock = try FileLock(lockURL: baseURL)
    try lock.lock()
    defer { try? lock.unlock() }

    if let existingURL = try existingContentURL(for: contentDigest) {
      try? FileManager.default.removeItem(at: temporaryURL)
      return existingURL
    }

    if FileManager.default.fileExists(atPath: targetURL.path) {
      _ = try FileManager.default.replaceItemAt(targetURL, withItemAt: temporaryURL)
    } else {
      try FileManager.default.moveItem(at: temporaryURL, to: targetURL)
    }

    return targetURL
  }

  private func validatedDigestHex(_ contentDigest: String) throws -> String {
    guard contentDigest.hasPrefix(Self.digestPrefix) else {
      throw ContentStoreError.invalidContentDigest(contentDigest)
    }

    let digestHex = String(contentDigest.dropFirst(Self.digestPrefix.count))
    let isHex = digestHex.allSatisfy { $0.isHexDigit && !$0.isUppercase }

    guard digestHex.count == 64, isHex else {
      throw ContentStoreError.invalidContentDigest(contentDigest)
    }

    return digestHex
  }
}
