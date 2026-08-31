import Darwin
import Semaphore
import Virtualization

#if compiler(>=6.4)
  import vmnet

  struct IPv4Subnet: Equatable, CustomStringConvertible {
    private enum PrivateRange: Equatable {
      case ten
      case oneSeventyTwo
      case oneNinetyTwo
    }

    let networkAddress: UInt32
    let prefixLength: UInt8

    init(_ rawValue: String) throws {
      let components = rawValue.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
      guard components.count == 2 else {
        throw IPv4SubnetError.invalid(rawValue, why: "expected CIDR notation such as 192.168.200.0/24")
      }

      guard let parsedPrefixLength = Int(components[1]), (1...30).contains(parsedPrefixLength) else {
        throw IPv4SubnetError.invalid(rawValue, why: "prefix length must be between 1 and 30")
      }

      let addressString = String(components[0])
      var parsedAddress = in_addr()
      guard inet_pton(AF_INET, addressString, &parsedAddress) == 1 else {
        throw IPv4SubnetError.invalid(rawValue, why: "invalid IPv4 address \"\(addressString)\"")
      }

      let address = UInt32(bigEndian: parsedAddress.s_addr)
      let parsedSubnetMask = UInt32.max << (32 - parsedPrefixLength)
      let networkAddress = address & parsedSubnetMask
      let canonical = "\(Self.addressString(networkAddress))/\(parsedPrefixLength)"

      guard address == networkAddress else {
        throw IPv4SubnetError.invalid(rawValue, why: "network address is not canonical; use \(canonical)")
      }

      let broadcastAddress = networkAddress | ~parsedSubnetMask
      guard let networkPrivateRange = Self.privateRange(containing: networkAddress),
            networkPrivateRange == Self.privateRange(containing: broadcastAddress)
      else {
        throw IPv4SubnetError.invalid(rawValue, why: "subnet must be fully contained in an RFC 1918 private range")
      }

      self.networkAddress = networkAddress
      self.prefixLength = UInt8(parsedPrefixLength)
    }

    var gatewayAddressDescription: String {
      Self.addressString(networkAddress + 1)
    }

    var subnetMask: UInt32 {
      UInt32.max << (32 - Int(prefixLength))
    }

    var subnetMaskDescription: String {
      Self.addressString(subnetMask)
    }

    var description: String {
      "\(Self.addressString(networkAddress))/\(prefixLength)"
    }

    func matches(address: UInt32, mask: UInt32) -> Bool {
      mask == subnetMask && (address & mask) == networkAddress
    }

    static func addressString(_ address: UInt32) -> String {
      "\((address >> 24) & 0xff).\((address >> 16) & 0xff).\((address >> 8) & 0xff).\(address & 0xff)"
    }

    private static func privateRange(containing address: UInt32) -> PrivateRange? {
      switch address {
      case 0x0a00_0000...0x0aff_ffff:
        return .ten
      case 0xac10_0000...0xac1f_ffff:
        return .oneSeventyTwo
      case 0xc0a8_0000...0xc0a8_ffff:
        return .oneNinetyTwo
      default:
        return nil
      }
    }
  }

  enum IPv4SubnetError: Error, CustomStringConvertible {
    case invalid(String, why: String)

    var description: String {
      switch self {
      case .invalid(let value, let why):
        return "invalid vmnet subnet \"\(value)\": \(why)"
      }
    }
  }

  @available(macOS 26, *)
  final class NetworkVmnet: Network {
    private let network: vmnet_network_ref

    init(subnet: IPv4Subnet) throws {
      var status: vmnet_return_t = .VMNET_FAILURE
      guard let configuration = vmnet_network_configuration_create(.VMNET_SHARED_MODE, &status) else {
        throw NetworkVmnetError.configurationCreationFailed(status: status)
      }
      defer { Self.release(configuration) }

      guard status == .VMNET_SUCCESS else {
        throw NetworkVmnetError.configurationCreationFailed(status: status)
      }

      var gatewayAddress = in_addr()
      var subnetMask = in_addr()
      guard inet_pton(AF_INET, subnet.gatewayAddressDescription, &gatewayAddress) == 1,
            inet_pton(AF_INET, subnet.subnetMaskDescription, &subnetMask) == 1
      else {
        throw NetworkVmnetError.invalidGeneratedAddress(subnet: subnet)
      }

      let subnetStatus = vmnet_network_configuration_set_ipv4_subnet(configuration, &gatewayAddress, &subnetMask)
      guard subnetStatus == .VMNET_SUCCESS else {
        throw NetworkVmnetError.subnetConfigurationFailed(subnet: subnet, status: subnetStatus)
      }

      status = .VMNET_FAILURE
      guard let network = vmnet_network_create(configuration, &status) else {
        throw NetworkVmnetError.networkCreationFailed(subnet: subnet, status: status)
      }

      var releaseNetworkOnFailure = true
      defer {
        if releaseNetworkOnFailure {
          Self.release(network)
        }
      }

      guard status == .VMNET_SUCCESS else {
        throw NetworkVmnetError.networkCreationFailed(subnet: subnet, status: status)
      }

      var actualAddress = in_addr()
      var actualMask = in_addr()
      vmnet_network_get_ipv4_subnet(network, &actualAddress, &actualMask)

      let actualAddressValue = UInt32(bigEndian: actualAddress.s_addr)
      let actualMaskValue = UInt32(bigEndian: actualMask.s_addr)
      guard subnet.matches(address: actualAddressValue, mask: actualMaskValue) else {
        throw NetworkVmnetError.unexpectedSubnet(
          requested: subnet,
          actualAddress: actualAddressValue,
          actualMask: actualMaskValue
        )
      }

      self.network = network
      releaseNetworkOnFailure = false
    }

    deinit {
      Self.release(network)
    }

    func attachments() -> [VZNetworkDeviceAttachment] {
      [VZVmnetNetworkDeviceAttachment(network: network)]
    }

    func run(_ sema: AsyncSemaphore) throws {
      // The vmnet network runs in-process and has no sidecar to monitor.
    }

    func stop() async throws {
      // The vmnet reference is released when this Network instance is deinitialized.
    }

    private static func release(_ pointer: OpaquePointer) {
      Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(pointer)).release()
    }
  }

  @available(macOS 26, *)
  enum NetworkVmnetError: Error, CustomStringConvertible {
    case configurationCreationFailed(status: vmnet_return_t)
    case invalidGeneratedAddress(subnet: IPv4Subnet)
    case subnetConfigurationFailed(subnet: IPv4Subnet, status: vmnet_return_t)
    case networkCreationFailed(subnet: IPv4Subnet, status: vmnet_return_t)
    case unexpectedSubnet(requested: IPv4Subnet, actualAddress: UInt32, actualMask: UInt32)

    var description: String {
      switch self {
      case .configurationCreationFailed(let status):
        return "vmnet_network_configuration_create() failed with status \(status)"
      case .invalidGeneratedAddress(let subnet):
        return "failed to derive vmnet gateway and subnet mask for \(subnet)"
      case .subnetConfigurationFailed(let subnet, let status):
        return "vmnet_network_configuration_set_ipv4_subnet(\(subnet)) failed with status \(status)"
      case .networkCreationFailed(let subnet, let status):
        return "vmnet_network_create(\(subnet)) failed with status \(status); make sure the subnet does not conflict with another active network"
      case .unexpectedSubnet(let requested, let actualAddress, let actualMask):
        let actualNetwork = IPv4Subnet.addressString(actualAddress & actualMask)
        let actualMask = IPv4Subnet.addressString(actualMask)
        return "vmnet created IPv4 network \(actualNetwork) with mask \(actualMask) instead of requested subnet \(requested)"
      }
    }
  }
#endif
