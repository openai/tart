import Foundation

class VMStorageHelper {
  static func open(_ name: String) throws -> VMDirectory {
    try missingVMWrap(name) {
      if let remoteName = try? RemoteName(name) {
        return try VMStorageOCI().open(remoteName)
      } else {
        return try VMStorageLocal().open(name)
      }
    }
  }

  static func delete(_ name: String) throws {
    try missingVMWrap(name) {
      if let remoteName = try? RemoteName(name) {
        try VMStorageOCI().delete(remoteName)
      } else {
        try VMStorageLocal().delete(name)
      }
    }
  }

  private static func missingVMWrap<R: Any>(_ name: String, closure: () throws -> R) throws -> R {
    do {
      return try closure()
    } catch RuntimeError.PIDLockMissing {
      throw RuntimeError.VMDoesNotExist(name: name)
    } catch {
      if error.isFileNotFound() {
        throw RuntimeError.VMDoesNotExist(name: name)
      }

      throw error
    }
  }
}

extension NSError {
  func isFileNotFound() -> Bool {
    return self.domain == NSCocoaErrorDomain &&
      (self.code == NSFileNoSuchFileError || self.code == NSFileReadNoSuchFileError)
  }
}

extension Error {
  func isFileNotFound() -> Bool {
    (self as NSError).isFileNotFound() || (self as NSError).underlyingErrors.contains(where: { $0.isFileNotFound() })
  }
}

enum RuntimeError : Error {
  case Generic(_ message: String)
  case VMConfigurationError(_ message: String)
  case VMDoesNotExist(name: String)
  case VMMissingFiles(_ message: String)
  case VMIsRunning(_ name: String)
  case VMNotRunning(_ name: String)
  case VMAlreadyRunning(_ message: String)
  case NoIPAddressFound(_ message: String)
  case DiskAlreadyInUse(_ message: String)
  case FailedToOpenBlockDevice(_ path: String, _ explanation: String)
  case InvalidDiskSize(_ message: String)
  case FailedToCreateDisk(_ message: String)
  case FailedToResizeDisk(_ message: String)
  case FailedToUpdateAccessDate(_ message: String)
  case PIDLockFailed(_ message: String)
  case PIDLockMissing(_ message: String)
  case FailedToParseRemoteName(_ message: String)
  case VMTerminationFailed(_ message: String)
  case ImproperlyFormattedHost(_ host: String, _ hint: String)
  case InvalidCredentials(_ message: String)
  case VMDirectoryAlreadyInitialized(_ message: String)
  case ExportFailed(_ message: String)
  case ImportFailed(_ message: String)
  case SoftnetFailed(_ message: String)
  case OCIStorageError(_ message: String)
  case SuspendFailed(_ message: String)
  case PullFailed(_ message: String)
  case VirtualMachineLimitExceeded(_ hint: String)
  case VMSocketFailed(_ port: UInt32, _ explanation: String)
  case TerminalOperationFailed(_ message: String)
}

protocol HasExitCode {
  var exitCode: Int32 { get }
}

extension RuntimeError : CustomStringConvertible {
  public var description: String {
    switch self {
    case .Generic(let message):
      return message
    case .VMConfigurationError(let message):
      return message
    case .VMDoesNotExist(let name):
      return "the specified VM \"\(name)\" does not exist"
    case .VMMissingFiles(let message):
      return message
    case .VMIsRunning(let name):
      return "VM \"\(name)\" is running"
    case .VMNotRunning(let name):
      return "VM \"\(name)\" is not running"
    case .VMAlreadyRunning(let message):
      return message
    case .NoIPAddressFound(let message):
      return message
    case .DiskAlreadyInUse(let message):
      return message
    case .FailedToOpenBlockDevice(let path, let explanation):
      return "failed to open block device \(path): \(explanation)"
    case .InvalidDiskSize(let message):
      return message
    case .FailedToCreateDisk(let message):
      return message
    case .FailedToResizeDisk(let message):
      return message
    case .FailedToUpdateAccessDate(let message):
      return message
    case .PIDLockFailed(let message):
      return message
    case .PIDLockMissing(let message):
      return message
    case .FailedToParseRemoteName(let cause):
      return "failed to parse remote name: \(cause)"
    case .VMTerminationFailed(let message):
      return message
    case .ImproperlyFormattedHost(let host, let hint):
      return "improperly formatted host \"\(host)\" was provided\(hint)"
    case .InvalidCredentials(let message):
      return message
    case .VMDirectoryAlreadyInitialized(let message):
      return message
    case .ExportFailed(let message):
      return "VM export failed: \(message)"
    case .ImportFailed(let message):
      return "VM import failed: \(message)"
    case .SoftnetFailed(let message):
      return "Softnet failed: \(message)"
    case .OCIStorageError(let message):
      return "OCI storage error: \(message)"
    case .SuspendFailed(let message):
      return "Failed to suspend the VM: \(message)"
    case .PullFailed(let message):
      return message
    case .VirtualMachineLimitExceeded(let hint):
      return "The number of VMs exceeds the system limit\(hint)"
    case .VMSocketFailed(let port, let explanation):
      return "Failed to establish a VM socket connection to port \(port): \(explanation)"
    case .TerminalOperationFailed(let message):
      return message
    }
  }
}

extension RuntimeError : HasExitCode {
  var exitCode: Int32 {
    switch self {
    case .VMDoesNotExist:
      return 2
    case .VMNotRunning:
      return 2
    case .VMAlreadyRunning:
      return 2
    default:
      return 1
    }
  }
}
