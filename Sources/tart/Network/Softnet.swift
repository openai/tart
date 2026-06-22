import Atomics
import Foundation
import Semaphore
import System
import Virtualization

enum SoftnetError: Error {
  case InitializationFailed(why: String)
  case RuntimeFailed(why: String)
}

class Softnet: Network {
  private let process = Process()
  private var monitorTask: Task<Void, Error>? = nil
  private let monitorTaskFinished = ManagedAtomic<Bool>(false)

  let vmFD: Int32

  init(vmMACAddress: String, extraArguments: [String] = [], controlFD: Int32? = nil) throws {
    var controlFileHandle: FileHandle?

    if let controlFD = controlFD {
      guard controlFD > STDERR_FILENO else {
        throw SoftnetError.InitializationFailed(why: "Softnet control file descriptor must be greater than 2")
      }

      controlFileHandle = FileHandle(fileDescriptor: controlFD, closeOnDealloc: true)
      try Self.validateControlFD(controlFD)
    }

    let fds = UnsafeMutablePointer<Int32>.allocate(capacity: MemoryLayout<Int>.stride * 2)

    let ret = socketpair(AF_UNIX, SOCK_DGRAM, 0, fds)
    if ret != 0 {
      throw SoftnetError.InitializationFailed(why: "socketpair() failed with exit code \(ret)")
    }

    vmFD = fds[0]
    let softnetFD = fds[1]

    try setSocketBuffers(vmFD, 1 * 1024 * 1024);
    try setSocketBuffers(softnetFD, 1 * 1024 * 1024);

    process.executableURL = try Self.softnetExecutableURL()
    process.arguments = ["--vm-fd", String(STDIN_FILENO), "--vm-mac-address", vmMACAddress] + extraArguments
    process.standardInput = FileHandle(fileDescriptor: softnetFD, closeOnDealloc: false)

    if let controlFileHandle = controlFileHandle {
      process.arguments! += ["--control-fd", String(STDOUT_FILENO)]
      process.standardOutput = controlFileHandle
    }
  }

  static func validateControlFD(_ fd: Int32) throws {
    guard fd > STDERR_FILENO else {
      throw SoftnetError.InitializationFailed(why: "Softnet control file descriptor must be greater than 2")
    }

    var socketType: Int32 = 0
    var socketTypeLength = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(fd, SOL_SOCKET, SO_TYPE, &socketType, &socketTypeLength) == 0 else {
      let details = Errno(rawValue: CInt(errno))
      throw SoftnetError.InitializationFailed(why: "Softnet control file descriptor is not a socket: \(details)")
    }

    guard socketType == SOCK_STREAM else {
      throw SoftnetError.InitializationFailed(why: "Softnet control file descriptor must be a Unix stream socket")
    }

    var peerAddress = sockaddr_storage()
    var peerAddressLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let result = withUnsafeMutablePointer(to: &peerAddress) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getpeername(fd, $0, &peerAddressLength)
      }
    }
    guard result == 0 else {
      let details = Errno(rawValue: CInt(errno))
      throw SoftnetError.InitializationFailed(why: "Softnet control file descriptor is not connected: \(details)")
    }

    guard peerAddress.ss_family == sa_family_t(AF_UNIX) else {
      throw SoftnetError.InitializationFailed(why: "Softnet control file descriptor must be a Unix stream socket")
    }
  }

  static func softnetExecutableURL() throws -> URL {
    let binaryName = "softnet"

    guard let executableURL = resolveBinaryPath(binaryName) else {
      throw SoftnetError.InitializationFailed(why: "\(binaryName) not found in PATH")
    }

    return executableURL
  }

  func run(_ sema: AsyncSemaphore) throws {
    defer { try? (process.standardOutput as? FileHandle)?.close() }

    try process.run()

    monitorTask = Task {
      // Wait for the Softnet to finish
      process.waitUntilExit()

      // Signal to the caller that the Softnet has finished
      sema.signal()

      // Signal to ourselves that the Softnet has finished
      monitorTaskFinished.store(true, ordering: .sequentiallyConsistent)
    }
  }

  func stop() async throws {
    if monitorTaskFinished.load(ordering: .sequentiallyConsistent) {
      // Consume the monitor task's value to ensure the task has finished
      _ = try await monitorTask?.value

      throw SoftnetError.RuntimeFailed(why: "Softnet process terminated prematurely")
    } else {
      process.interrupt()

      // Consume the monitor task's value to ensure the task has finished
      _ = try await monitorTask?.value
    }
  }

  private func setSocketBuffers(_ fd: Int32, _ sizeBytes: Int) throws {
    let option_len = socklen_t(MemoryLayout<Int>.size)

    // The system expects the value of SO_RCVBUF to be at least double the value of SO_SNDBUF,
    // and for optimal performance, the recommended value of SO_RCVBUF is four times the value of SO_SNDBUF.
    // See: https://developer.apple.com/documentation/virtualization/vzfilehandlenetworkdeviceattachment/3969266-maximumtransmissionunit
    var receiveBufferSize = 4 * sizeBytes
    var ret = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBufferSize, option_len)
    if ret != 0 {
      throw SoftnetError.InitializationFailed(why: "setsockopt(SO_RCVBUF) returned \(ret)")
    }

    var sendBufferSize = sizeBytes
    ret = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendBufferSize, option_len)
    if ret != 0 {
      throw SoftnetError.InitializationFailed(why: "setsockopt(SO_SNDBUF) returned \(ret)")
    }
  }

  func attachments() -> [VZNetworkDeviceAttachment] {
    let fh = FileHandle.init(fileDescriptor: vmFD)
    return [VZFileHandleNetworkDeviceAttachment(fileHandle: fh)]
  }

  static func configureSUIDBitIfNeeded() throws {
    // Obtain the Softnet executable path
    //
    // It's important to use resolvingSymlinksInPath() here, because otherwise
    // we will get something like "/opt/homebrew/bin/softnet" instead of
    // "/opt/homebrew/Cellar/softnet/0.6.2/bin/softnet"
    let softnetExecutablePath = try Softnet.softnetExecutableURL().resolvingSymlinksInPath().path

    // Check if the SUID bit is already configured
    let info = try FileManager.default.attributesOfItem(atPath: softnetExecutablePath) as NSDictionary
    if info.fileOwnerAccountID() == 0 && (info.filePosixPermissions() & Int(S_ISUID)) != 0 {
      return
    }

    // Check if the passwordless Sudo is already configured for Softnet
    let sudoBinaryName = "sudo"

    guard let sudoExecutableURL = resolveBinaryPath(sudoBinaryName) else {
      throw SoftnetError.InitializationFailed(why: "\(sudoBinaryName) not found in PATH")
    }

    let process = Process()
    process.executableURL = sudoExecutableURL
    process.arguments = ["--non-interactive", softnetExecutablePath, "--help"]
    process.standardInput = nil
    process.standardOutput = nil
    process.standardError = nil
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus == 0 {
      return
    }

    // Configure the SUID bit by spawning the Sudo process in interactive mode
    // and asking the user for password required to run chown & chmod
    fputs("Softnet requires a Sudo password to set the SUID bit on the Softnet executable, please enter it below.\n",
          stderr)

    try runInteractiveSudo(
      executableURL: sudoExecutableURL,
      arguments: ["chown", "root", softnetExecutablePath],
      failureMessage: "failed to change ownership of Softnet executable with Sudo")

    try runInteractiveSudo(
      executableURL: sudoExecutableURL,
      arguments: ["chmod", "u+s", softnetExecutablePath],
      failureMessage: "failed to configure SUID bit on Softnet executable with Sudo")
  }

  private static func runInteractiveSudo(executableURL: URL, arguments: [String], failureMessage: String) throws {
    let originalForegroundProcessGroup = tcgetpgrp(STDIN_FILENO)
    if originalForegroundProcessGroup == -1 {
      let details = Errno(rawValue: CInt(errno))

      throw RuntimeError.SoftnetFailed("tcgetpgrp(2) failed: \(details)")
    }

    let process = try Process.run(executableURL, arguments: arguments)

    // Set TTY's foreground process group to that of the Sudo process,
    // otherwise it will get stopped by a SIGTTIN once user input arrives
    try setTerminalForegroundProcessGroup(process.processIdentifier)

    process.waitUntilExit()

    try setTerminalForegroundProcessGroup(originalForegroundProcessGroup)

    if process.terminationStatus != 0 {
      throw RuntimeError.SoftnetFailed(failureMessage)
    }
  }

  private static func setTerminalForegroundProcessGroup(_ processGroup: pid_t) throws {
    let previousSIGTTOUHandler = signal(SIGTTOU, SIG_IGN)
    defer { _ = signal(SIGTTOU, previousSIGTTOUHandler) }

    if tcsetpgrp(STDIN_FILENO, processGroup) == -1 {
      let details = Errno(rawValue: CInt(errno))

      throw RuntimeError.SoftnetFailed("tcsetpgrp(2) failed: \(details)")
    }
  }
}
