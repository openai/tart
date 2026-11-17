import Foundation

/// Remembers which blob each disk chunk compressed to when this machine pushed
/// it, so that pushing an identical chunk again doesn't need to compress it.
///
/// Only chunks that Tart compressed itself are recorded, because a registry
/// vouches for a blob's digest but not for what the blob decompresses to.
struct CompressedChunkCache {
  private static let digestPrefix = "sha256:"

  private struct Entry: Codable {
    var digest: String
    var size: Int
  }

  let baseURL: URL

  init() throws {
    try self.init(baseURL: Config().tartCacheDir.appendingPathComponent("chunks", isDirectory: true))
  }

  init(baseURL: URL) throws {
    self.baseURL = baseURL
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
  }

  /// Returns the blob that a chunk with this uncompressed content digest was compressed to.
  func compressedBlob(for uncompressedContentDigest: String) -> Descriptor? {
    guard let url = entryURL(for: uncompressedContentDigest),
          let entryJSON = try? Data(contentsOf: url),
          let entry = try? JSONDecoder().decode(Entry.self, from: entryJSON) else {
      return nil
    }

    return Descriptor(size: entry.size, digest: entry.digest)
  }

  func remember(_ blob: Descriptor, for uncompressedContentDigest: String) throws {
    guard let url = entryURL(for: uncompressedContentDigest) else {
      return
    }

    try JSONEncoder().encode(Entry(digest: blob.digest, size: blob.size)).write(to: url, options: .atomic)
  }

  private func entryURL(for uncompressedContentDigest: String) -> URL? {
    guard uncompressedContentDigest.hasPrefix(Self.digestPrefix) else {
      return nil
    }

    let digestHex = uncompressedContentDigest.dropFirst(Self.digestPrefix.count)
    guard !digestHex.isEmpty, digestHex.allSatisfy(\.isHexDigit) else {
      return nil
    }

    return baseURL.appendingPathComponent(String(digestHex))
  }
}
