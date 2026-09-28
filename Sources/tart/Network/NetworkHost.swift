import Foundation
import Semaphore
import Virtualization
import vmnet

@available(macOS 26, *)
class NetworkHost: Network {
  private let attachment: VZNetworkDeviceAttachment

  init() throws {
    var status = vmnet_return_t.VMNET_SUCCESS
    guard let configuration = vmnet_network_configuration_create(.VMNET_HOST_MODE, &status) else {
      throw RuntimeError.Generic("Failed to create a vmnet configuration for host-only networking: \(status)")
    }
    defer { Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(configuration)).release() }

    guard let network = vmnet_network_create(configuration, &status) else {
      var message = "Failed to create a vmnet network for host-only networking: \(status)"

      if status == .VMNET_NOT_AUTHORIZED {
        message += ". Creating a vmnet network requires root privileges or a properly signed app with the com.apple.vm.networking entitlement."
      }

      throw RuntimeError.Generic(message)
    }
    defer { Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(network)).release() }

    attachment = VZVmnetNetworkDeviceAttachment(network: network)
  }

  func attachments() -> [VZNetworkDeviceAttachment] {
    [attachment]
  }

  func run(_ sema: AsyncSemaphore) throws {
    // no-op, only used for Softnet
  }

  func stop() async throws {
    // no-op, only used for Softnet
  }
}

extension vmnet_return_t: @retroactive CustomStringConvertible {
  public var description: String {
    switch self {
    case .VMNET_SUCCESS: return "successfully completed"
    case .VMNET_FAILURE: return "general failure"
    case .VMNET_MEM_FAILURE: return "memory allocation failure"
    case .VMNET_INVALID_ARGUMENT: return "invalid argument specified"
    case .VMNET_SETUP_INCOMPLETE: return "interface setup is not complete"
    case .VMNET_INVALID_ACCESS: return "permission denied"
    case .VMNET_PACKET_TOO_BIG: return "packet size larger than MTU"
    case .VMNET_BUFFER_EXHAUSTED: return "buffers exhausted in kernel"
    case .VMNET_TOO_MANY_PACKETS: return "packet count exceeds limit"
    case .VMNET_SHARING_SERVICE_BUSY: return "vmnet interface cannot be started as conflicting sharing service is in use"
    case .VMNET_NOT_AUTHORIZED: return "the operation could not be completed due to missing authorization"
    @unknown default: return "unknown vmnet status (\(rawValue))"
    }
  }
}
