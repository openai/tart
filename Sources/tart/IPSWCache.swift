import Foundation
import Virtualization

class IPSWCache: PrunableStorage {
  let baseURL: URL
  private let readOnly: Bool

  init(readOnly: Bool = false) throws {
    self.readOnly = readOnly
    baseURL = try Config(readOnly: readOnly).tartCacheDir.appendingPathComponent("IPSWs", isDirectory: true)
    if !readOnly {
      try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }
  }

  func locationFor(fileName: String) -> URL {
    baseURL.appendingPathComponent(fileName, isDirectory: false)
  }

  func prunables() throws -> [Prunable] {
    do {
      return try FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasSuffix(".ipsw")}
    } catch {
      if readOnly && error.isFileNotFound() {
        return []
      }
      throw error
    }
  }
}
