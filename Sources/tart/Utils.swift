import Foundation

// A fire-and-forget task that reports any thrown error to stderr. An unstructured
// Task spawned from a synchronous context (a signal handler, a SwiftUI action) has
// no parent to propagate its error to, so we report it here instead of dropping it.
struct ErrorReportingTask {
  let task: Task<Void, Never>

  @discardableResult
  init(_ context: String, operation: @escaping @Sendable () async throws -> Void) {
    task = Task {
      do {
        try await operation()
      } catch {
        fputs("\(context): \(error)\n", stderr)
      }
    }
  }
}

extension Collection {
  subscript (safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

func resolveBinaryPath(_ name: String) -> URL? {
  guard let path = ProcessInfo.processInfo.environment["PATH"] else {
    return nil
  }

  for pathComponent in path.split(separator: ":") {
    let url = URL(fileURLWithPath: String(pathComponent))
      .appendingPathComponent(name, isDirectory: false)

    if FileManager.default.fileExists(atPath: url.path) {
      return url
    }
  }

  return nil
}
