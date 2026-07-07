import ArgumentParser
import Foundation

struct Save: AsyncParsableCommand {
  static var configuration = CommandConfiguration(abstract: "Save a VM to an OCI archive file")

  @Argument(help: "local VM name", completion: .custom(completeMachines))
  var localName: String

  @Argument(help: "output archive path", completion: .file())
  var path: String

  @Option(help: "concurrency for disk layer compression")
  var concurrency: UInt = 4

  @Option(name: [.customLong("label")], help: ArgumentHelp("additional metadata to attach to the OCI image configuration in key=value format",
                                                           discussion: "Can be specified multiple times to attach multiple labels."))
  var labels: [String] = []

  @Option(help: "tag to assign to the saved image (default: latest)")
  var tag: String?

  func run() async throws {
    let localVMDir = try VMStorageHelper.open(localName)
    let lock = try localVMDir.lock()
    if try !lock.trylock() {
      throw RuntimeError.VMIsRunning(localName)
    }

    let resolvedPath: String
    if path.hasPrefix("/") {
      resolvedPath = path
    } else {
      resolvedPath = FileManager.default.currentDirectoryPath + "/" + path
    }

    try await localVMDir.saveToArchive(
      path: resolvedPath,
      concurrency: concurrency,
      labels: parseLabels(),
      tag: tag
    )
  }

  func parseLabels() -> [String: String] {
    var result = [String: String]()

    for label in labels {
      let parts = label.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)

      let key = parts.count > 0 ? String(parts[0]) : ""
      let value = parts.count > 1 ? String(parts[1]) : ""

      if key.isEmpty {
        continue
      }

      result[key] = value
    }

    return result
  }
}
