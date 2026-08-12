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

  init() throws {
    try self.init(baseURL: Config().tartCacheDir.appendingPathComponent("content", isDirectory: true))
  }

  init(baseURL: URL) throws {
    self.baseURL = baseURL
    self.digestDirectoryURL = baseURL.appendingPathComponent(Self.digestAlgorithm, isDirectory: true)
    try FileManager.default.createDirectory(at: digestDirectoryURL, withIntermediateDirectories: true)
  }

  func contentURL(for contentDigest: String) throws -> URL {
    let digestHex = try validatedDigestHex(contentDigest)

    return digestDirectoryURL.appendingPathComponent(digestHex)
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

  /// Returns a digest-addressed entry without rereading it. Pull verifies
  /// content hashes before accepting a cache hit; clone only needs a cheap
  /// structural check, like Tart's existing disk.img path.
  func contentURLIfPresent(for contentDigest: String) throws -> URL? {
    let url = try contentURL(for: contentDigest)

    guard FileManager.default.fileExists(atPath: url.path) else {
      return nil
    }

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
