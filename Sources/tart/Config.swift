import Foundation

struct Config {
  let tartHomeDir: URL
  let tartCacheDir: URL
  let tartTmpDir: URL

  init() throws {
    var tartHomeDir: URL

    if let customTartHome = ProcessInfo.processInfo.environment["TART_HOME"] {
      tartHomeDir = URL(fileURLWithPath: customTartHome, isDirectory: true)
      try Self.validateTartHome(url: tartHomeDir)
    } else {
      tartHomeDir = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".tart", isDirectory: true)
    }
    self.tartHomeDir = tartHomeDir

    tartCacheDir = tartHomeDir.appendingPathComponent("cache", isDirectory: true)
    try FileManager.default.createDirectory(at: tartCacheDir, withIntermediateDirectories: true)

    tartTmpDir = tartHomeDir.appendingPathComponent("tmp", isDirectory: true)
    try FileManager.default.createDirectory(at: tartTmpDir, withIntermediateDirectories: true)
  }

  func gc() throws {
    for entry in try FileManager.default.contentsOfDirectory(at: tartTmpDir,
                                                             includingPropertiesForKeys: [], options: []) {
      let lock = try FileLock(lockURL: entry)
      if try !lock.trylock() {
        continue
      }

      try VMDirectory(baseURL: entry).removeFromDisk()

      try lock.unlock()
    }
  }

  static func jsonEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()

    encoder.outputFormatting = [.sortedKeys]

    return encoder
  }

  static func jsonDecoder() -> JSONDecoder {
    JSONDecoder()
  }

  private static func validateTartHome(url: URL) throws {
    let urlComponents = url.pathComponents

    let descendingURLs = urlComponents.indices.map { i in
      URL(fileURLWithPath: urlComponents[0...i].joined(separator: "/"))
    }

    for descendingURL in descendingURLs {
      if FileManager.default.fileExists(atPath: descendingURL.path) {
        continue
      }

      do {
        try FileManager.default.createDirectory(at: descendingURL, withIntermediateDirectories: false)
      } catch {
        throw RuntimeError.Generic("TART_HOME is invalid: \(descendingURL.path) does not exist, yet we can't create it: \(error.localizedDescription)")
      }
    }
  }
}
