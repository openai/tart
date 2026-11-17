import Foundation
import Virtualization

enum VMIdentityStop {
  private static let identityPrefix = "com.apple.AppleVirtualPlatform.Identity.Virtio."

  @MainActor
  static func interrupt(_ vm: VZVirtualMachine) throws {
    guard vm.state == .stopping else { return }
    let selector = NSSelectorFromString("_serviceProcessIdentifier")
    guard vm.responds(to: selector),
          let owner = (vm.value(forKey: "_serviceProcessIdentifier") as? NSNumber)?.int32Value,
          owner > 1, let identity = try service(owner: owner),
          let current = try service(owner: owner), current == identity else { return }
    var path = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(identity.pid, &path, UInt32(path.count)) > 0 else { return }
    let executable = String(cString: path)
    guard executable.hasPrefix("/System/Library/PrivateFrameworks/AppleVirtualPlatform.framework/"),
          URL(fileURLWithPath: executable).lastPathComponent == "com.apple.Virtualization.AppleVirtualPlatformIdentity"
    else { return }
    kill(identity.pid, SIGKILL)
  }

  private static func service(owner: pid_t) throws -> Identity? {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["print", "pid/\(owner)"]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return nil }
    return parse(text, owner: owner)
  }

  struct Identity: Equatable {
    let pid: pid_t
    let label: String
  }

  static func parse(_ text: String, owner: pid_t) -> Identity? {
    guard text.hasPrefix("pid/\(owner) = {\n"),
          let services = text.components(separatedBy: "\n\tservices = {\n").dropFirst().first?
            .components(separatedBy: "\n\t}").first else { return nil }
    let identities = services.split(separator: "\n").compactMap { line -> Identity? in
      let fields = line.split(whereSeparator: \.isWhitespace)
      guard fields.count == 3, fields[2].hasPrefix(identityPrefix),
            UUID(uuidString: String(fields[2].dropFirst(identityPrefix.count))) != nil,
            let pid = pid_t(fields[0]), pid > 1 else { return nil }
      return Identity(pid: pid, label: String(fields[2]))
    }
    return identities.count == 1 ? identities[0] : nil
  }
}
