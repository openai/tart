import Foundation
import Darwin

// All mutable state is confined to queue.
final class VMIdentityShutdown: @unchecked Sendable {
  private let queue = DispatchQueue(label: "tart.vm-identity-shutdown")
  private var attempted = false

  func request() {
    queue.async { self.cancelNow() }
  }

  func cancel() async {
    await withCheckedContinuation { continuation in
      queue.async {
        self.cancelNow()
        continuation.resume()
      }
    }
  }

  private func cancelNow() {
    guard !attempted else { return }
    attempted = true
    if VMIdentityService.terminate() {
      print("Cancelled the VM's Apple identity service for shutdown")
    }
  }
}

// A macOS guest can leave an Apple attestation request pending indefinitely when
// Apple's servers are unreachable. Cancel its identity XPC service before VZ
// tears down the device, or the VM helper's shutdown watchdog can kill it.
struct VMIdentityService {
  static let vmService = "com.apple.Virtualization.VirtualMachine"
  static let identityService = "com.apple.AppleVirtualPlatform.Identity.Virtio"
  static let vmProgram = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
  static let identityProgram = "/System/Library/PrivateFrameworks/AppleVirtualPlatform.framework/Versions/A/PlugIns/com.apple.AppleVirtualPlatform.Identity.Virtio.vzplugin/Contents/MacOS/com.apple.Virtualization.AppleVirtualPlatformIdentity"

  typealias Run = ([String]) -> String?

  struct Identity: Equatable {
    let target: String
    let parentPID: Int32
    let pid: Int32
  }

  static func terminate(vmPID: Int32 = getpid()) -> Bool {
    let deadline = DispatchTime.now() + .seconds(2)
    let command: Run = { arguments in
      run(arguments, deadline: deadline)
    }
    return terminate(vmPID: vmPID, run: command) { identity in
      guard var token = auditToken(pid: identity.pid),
            processID(target: identity.target, parentPID: identity.parentPID,
                      program: identityProgram, run: command) == identity.pid else { return false }
      // The kernel checks the normal signal permissions and the PID generation.
      // A recycled PID cannot cause us to signal another process.
      return proc_signal_with_audittoken(&token, SIGTERM) == 0
    }
  }

  static func terminate(vmPID: Int32, run: Run, signal: (Identity) -> Bool) -> Bool {
    guard let identity = identity(vmPID: vmPID, run: run) else {
      return false
    }

    return signal(identity)
  }

  static func identity(vmPID: Int32, run: Run) -> Identity? {
    guard vmPID > 0,
          let helper = instance(parentPID: vmPID, service: vmService, program: vmProgram, run: run),
          let helperPID = processID(target: helper, parentPID: vmPID, program: vmProgram, run: run),
          let target = instance(parentPID: helperPID, service: identityService, program: identityProgram, run: run),
          let pid = processID(target: target, parentPID: helperPID, program: identityProgram, run: run) else {
      return nil
    }
    // A parent application's responsible PID can be shared by multiple VMs. Follow each
    // UUID-qualified service instance instead of searching by process name.
    return Identity(target: target, parentPID: helperPID, pid: pid)
  }

  private static func auditToken(pid: Int32) -> audit_token_t? {
    var task: mach_port_name_t = 0
    guard task_name_for_pid(mach_task_self_, pid, &task) == KERN_SUCCESS else { return nil }
    defer { mach_port_deallocate(mach_task_self_, task) }
    var token = audit_token_t()
    var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &token) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { words in
        task_info(task, task_flavor_t(TASK_AUDIT_TOKEN), words, &count)
      }
    }
    guard result == KERN_SUCCESS, token.val.5 == UInt32(pid), token.val.1 == geteuid() else { return nil }
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath_audittoken(&token, &path, UInt32(path.count)) > 0,
          String(cString: path) == identityProgram else { return nil }
    return token
  }

  private static func instance(parentPID: Int32, service: String, program: String, run: Run) -> String? {
    let target = "pid/\(parentPID)/\(service)"
    guard let text = run(["print", target]),
          let lines = serviceLines(text, target: target, parentPID: parentPID, program: program),
          let start = lines.firstIndex(of: "\tinstances = {"),
          let end = lines[(start + 1)...].firstIndex(of: "\t}") else {
      return nil
    }
    let instances = Array(lines[(start + 1)..<end])
    guard instances.count == 1 else { return nil }
    let prefix = "\t\t\(service)."
    guard instances[0].hasPrefix(prefix), instances[0].hasSuffix(",") else { return nil }
    let identifier = String(instances[0].dropFirst(prefix.count).dropLast())
    guard UUID(uuidString: identifier)?.uuidString == identifier else { return nil }
    return "\(target).\(identifier)"
  }

  private static func processID(target: String, parentPID: Int32, program: String, run: Run) -> Int32? {
    guard let text = run(["print", target]),
          let lines = serviceLines(text, target: target, parentPID: parentPID, program: program),
          lines.contains("\tstate = running") else { return nil }
    let values = lines.filter { $0.hasPrefix("\tpid = ") }
    guard values.count == 1, let pid = Int32(values[0].dropFirst("\tpid = ".count)), pid > 0 else { return nil }
    return pid
  }

  private static func serviceLines(_ text: String, target: String, parentPID: Int32, program: String) -> [String]? {
    let lines = text.components(separatedBy: "\n")
    // launchctl print is diagnostic output, so deliberately fail closed if its
    // format or the service layout changes on a future macOS release.
    guard lines.first == "\(target) = {",
          lines.contains("\ttype = XPCService"),
          lines.contains("\tprogram = \(program)"),
          lines.contains(where: { $0.hasPrefix("\tdomain = pid/\(parentPID) [") }) else { return nil }
    return lines
  }

  // The reader writes data once, before signalling finished.
  private final class Output: @unchecked Sendable {
    let finished = DispatchSemaphore(value: 0)
    var data: Data?
  }

  static func run(_ arguments: [String], deadline: DispatchTime,
                  executable: URL = URL(fileURLWithPath: "/bin/launchctl")) -> String? {
    guard DispatchTime.now() < deadline else { return nil }
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do {
      try process.run()
    } catch {
      return nil
    }
    try? pipe.fileHandleForWriting.close()

    let output = Output()
    DispatchQueue.global(qos: .userInitiated).async {
      defer { output.finished.signal() }
      var data = Data()
      var oversized = false
      do {
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 16384), !chunk.isEmpty {
          if data.count + chunk.count <= 1048576 && !oversized {
            data.append(chunk)
          } else {
            oversized = true
          }
        }
        if !oversized { output.data = data }
      } catch {}
    }

    guard exited.wait(timeout: deadline) == .success else {
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      return nil
    }
    guard process.terminationStatus == 0,
          output.finished.wait(timeout: deadline) == .success,
          let data = output.data else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
