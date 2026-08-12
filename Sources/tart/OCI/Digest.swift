import Foundation
import CryptoKit

enum DigestError: Error {
  case InvalidOffset
  case InvalidSize
}

class Digest {
  private static let fileBufferSize = 4 * 1024 * 1024

  var hash: SHA256 = SHA256()

  func update(_ data: Data) {
    hash.update(data: data)
  }

  func finalize() -> String {
    hash.finalize().hexdigest()
  }

  static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).hexdigest()
  }

  static func hash(_ url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }

    return try hashContents(from: file)
  }

  static func hash(_ url: URL, offset: UInt64, size: UInt64) throws -> String {
    // Sanity check
    let fhSanity = try FileHandle(forReadingFrom: url)
    try fhSanity.seekToEnd()
    let fileSize = try fhSanity.offset()
    try fhSanity.close()

    if offset > fileSize {
      throw DigestError.InvalidOffset
    }

    if size > fileSize - offset {
      throw DigestError.InvalidSize
    }

    // Read the requested range incrementally and calculate its digest.
    let fh = try FileHandle(forReadingFrom: url)
    defer { try? fh.close() }

    try fh.seek(toOffset: offset)

    return try hashContents(from: fh, size: size)
  }

  /// Streams a file into SHA-256 while keeping Foundation's temporary read
  /// buffers scoped to one chunk.
  private static func hashContents(from file: FileHandle, size: UInt64? = nil) throws -> String {
    let digest = Digest()
    var remaining = size

    while remaining.map({ $0 > 0 }) ?? true {
      let didRead = try autoreleasepool { () throws -> Bool in
        let count = remaining.map {
          Int(min(UInt64(fileBufferSize), $0))
        } ?? fileBufferSize

        guard let data = try file.read(upToCount: count), !data.isEmpty else {
          if remaining != nil {
            throw DigestError.InvalidSize
          }

          return false
        }

        digest.update(data)
        if let bytesRemaining = remaining {
          remaining = bytesRemaining - UInt64(data.count)
        }

        return true
      }

      if !didRead {
        break
      }
    }

    return digest.finalize()
  }
}

extension SHA256.Digest {
  func hexdigest() -> String {
    "sha256:" + self.map {
      String(format: "%02x", $0)
    }
    .joined()
  }
}
