// Native vmnet-backed networking, adopting the vmnet logical network API
// surface introduced alongside VZVmnetNetworkDeviceAttachment.
//
// Goal: provide a sidecar-free alternative to the external Softnet process for
// CI-style port forwarding from host TCP/UDP ports to guest ports. The vmnet
// configuration is created in-process and handed to
// VZVmnetNetworkDeviceAttachment, so the VM keeps using the standard
// VZVirtioNetworkDeviceConfiguration path.
//
// The whole file is gated behind `#if compiler(>=6.4)` to match how Tart
// already gates VZMacGuestProvisioningOptions in VM.swift (the same situation:
// new SDK symbols referenced by a tree that still builds under Xcode 26).

import Darwin
import Foundation
import Semaphore
import Virtualization

#if compiler(>=6.4)
  import vmnet

  @available(macOS 26, *)
  class NetworkVmnet: Network {
    enum NetworkProtocol: String, CaseIterable {
      case tcp
      case udp
    }

    struct PortForwarding: Equatable {
      let proto: NetworkProtocol
      let externalPort: UInt16
      let internalPort: UInt16
    }

    private let network: vmnet_network_ref

    init(vmMACAddress: String, portForwardings: [PortForwarding] = []) throws {
      let macAddress = try Self.parseMACAddress(vmMACAddress)
      let addressing = try Self.addressing(for: macAddress)

      var configStatus: vmnet_return_t = .VMNET_FAILURE
      guard let configuration = vmnet_network_configuration_create(.VMNET_SHARED_MODE, &configStatus) else {
        throw NetworkVmnetError.ConfigurationCreationFailed(status: configStatus)
      }
      defer { Self.release(configuration) }

      if !portForwardings.isEmpty {
        try Self.configureIPv4Addressing(addressing, for: macAddress, to: configuration)
        try Self.applyPortForwarding(rules: portForwardings, internalAddress: addressing.guestAddress, to: configuration)
      }

      var networkStatus: vmnet_return_t = .VMNET_FAILURE
      guard let network = vmnet_network_create(configuration, &networkStatus) else {
        throw NetworkVmnetError.NetworkCreationFailed(status: networkStatus)
      }
      self.network = network
    }

    deinit {
      Self.release(network)
    }

    func attachments() -> [VZNetworkDeviceAttachment] {
      [VZVmnetNetworkDeviceAttachment(network: network)]
    }

    func run(_ sema: AsyncSemaphore) throws {
      // vmnet networks run in-process. There is no sidecar to monitor.
    }

    func stop() async throws {
      // The network handle is released in deinit; the VM tears down the
      // attachment as part of its normal shutdown.
    }

    private static func applyPortForwarding(
      rules: [PortForwarding],
      internalAddress: in_addr,
      to configuration: vmnet_network_configuration_ref
    ) throws {
      for rule in rules {
        var internalAddress = internalAddress
        let status = withUnsafePointer(to: &internalAddress) {
          vmnet_network_configuration_add_port_forwarding_rule(
            configuration,
            rule.vmnetProtocol,
            sa_family_t(AF_INET),
            rule.internalPort,
            rule.externalPort,
            UnsafeRawPointer($0)
          )
        }

        guard status == .VMNET_SUCCESS else {
          throw NetworkVmnetError.PortForwardingConfigurationFailed(rule: rule, status: status)
        }
      }
    }

    private static func configureIPv4Addressing(
      _ addressing: IPv4Addressing,
      for macAddress: MACAddress,
      to configuration: vmnet_network_configuration_ref
    ) throws {
      var subnet = addressing.subnet
      var mask = addressing.mask
      let subnetStatus = withUnsafePointer(to: &subnet) { subnetPointer in
        withUnsafePointer(to: &mask) { maskPointer in
          vmnet_network_configuration_set_ipv4_subnet(configuration, subnetPointer, maskPointer)
        }
      }
      guard subnetStatus == .VMNET_SUCCESS else {
        throw NetworkVmnetError.IPv4SubnetConfigurationFailed(status: subnetStatus)
      }

      var guestAddress = addressing.guestAddress
      var etherAddress = ether_addr_t(
        octet: (
          macAddress.mac[0],
          macAddress.mac[1],
          macAddress.mac[2],
          macAddress.mac[3],
          macAddress.mac[4],
          macAddress.mac[5]
        )
      )
      let reservationStatus = withUnsafePointer(to: &etherAddress) { macPointer in
        withUnsafePointer(to: &guestAddress) { guestAddressPointer in
          vmnet_network_configuration_add_dhcp_reservation(configuration, macPointer, guestAddressPointer)
        }
      }
      guard reservationStatus == .VMNET_SUCCESS else {
        throw NetworkVmnetError.DHCPReservationConfigurationFailed(status: reservationStatus)
      }
    }

    static func parsePortForwardings(_ spec: String) throws -> [PortForwarding] {
      try spec.split(separator: ",").map { try parseSingle(String($0)) }
    }

    private static func parseSingle(_ raw: String) throws -> PortForwarding {
      let (portPart, protoPart): (String, String) = {
        if let slashIdx = raw.firstIndex(of: "/") {
          return (String(raw[..<slashIdx]), String(raw[raw.index(after: slashIdx)...]))
        }
        return (raw, "tcp")
      }()

      let ports = portPart.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      guard ports.count == 2,
            let external = UInt16(ports[0]),
            let internalPort = UInt16(ports[1]),
            external > 0, internalPort > 0
      else {
        throw NetworkVmnetError.InvalidPortForwardingSpec(
          spec: raw,
          why: "expected EXTERNAL_PORT:INTERNAL_PORT[/PROTOCOL] with non-zero ports"
        )
      }

      guard let proto = NetworkProtocol(rawValue: protoPart.lowercased()) else {
        throw NetworkVmnetError.InvalidPortForwardingSpec(
          spec: raw,
          why: "unknown protocol \"\(protoPart)\", expected tcp or udp"
        )
      }

      return PortForwarding(proto: proto, externalPort: external, internalPort: internalPort)
    }

    private struct IPv4Addressing {
      let subnet: in_addr
      let mask: in_addr
      let guestAddress: in_addr
    }

    private static func addressing(for macAddress: MACAddress) throws -> IPv4Addressing {
      let thirdOctet = subnetThirdOctet(for: macAddress)

      return try IPv4Addressing(
        subnet: ipv4Address("192.168.\(thirdOctet).0"),
        mask: ipv4Address("255.255.255.0"),
        guestAddress: ipv4Address("192.168.\(thirdOctet).2")
      )
    }

    private static func subnetThirdOctet(for macAddress: MACAddress) -> UInt8 {
      var hash: UInt32 = 2_166_136_261
      for byte in macAddress.mac {
        hash ^= UInt32(byte)
        hash &*= 16_777_619
      }

      // Keep forwarded VMs on stable per-MAC subnets and avoid bridge100's common default.
      var octet = UInt8((hash % 253) + 2)
      if octet == 64 {
        octet = 65
      }
      return octet
    }

    private static func ipv4Address(_ string: String) throws -> in_addr {
      var address = in_addr()
      guard inet_pton(AF_INET, string, &address) == 1 else {
        throw NetworkVmnetError.InvalidIPv4Address(string)
      }
      return address
    }

    private static func parseMACAddress(_ string: String) throws -> MACAddress {
      guard let macAddress = MACAddress(fromString: string) else {
        throw NetworkVmnetError.InvalidMACAddress(string)
      }
      return macAddress
    }

    private static func release(_ pointer: OpaquePointer) {
      Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(pointer)).release()
    }
  }

  @available(macOS 26, *)
  extension NetworkVmnet.PortForwarding: CustomStringConvertible {
    fileprivate var vmnetProtocol: UInt8 {
      switch proto {
      case .tcp:
        return UInt8(IPPROTO_TCP)
      case .udp:
        return UInt8(IPPROTO_UDP)
      }
    }

    var description: String {
      "\(externalPort):\(internalPort)/\(proto.rawValue)"
    }
  }

  @available(macOS 26, *)
  enum NetworkVmnetError: Error, CustomStringConvertible {
    case ConfigurationCreationFailed(status: vmnet_return_t)
    case NetworkCreationFailed(status: vmnet_return_t)
    case IPv4SubnetConfigurationFailed(status: vmnet_return_t)
    case DHCPReservationConfigurationFailed(status: vmnet_return_t)
    case PortForwardingConfigurationFailed(rule: NetworkVmnet.PortForwarding, status: vmnet_return_t)
    case InvalidPortForwardingSpec(spec: String, why: String)
    case InvalidIPv4Address(String)
    case InvalidMACAddress(String)

    var description: String {
      switch self {
      case .ConfigurationCreationFailed(let status):
        return "vmnet_network_configuration_create() failed with status \(status)"
      case .NetworkCreationFailed(let status):
        return "vmnet_network_create() failed with status \(status)"
      case .InvalidPortForwardingSpec(let spec, let why):
        return "invalid port forwarding spec \"\(spec)\": \(why)"
      case .IPv4SubnetConfigurationFailed(let status):
        return "vmnet_network_configuration_set_ipv4_subnet() failed with status \(status)"
      case .DHCPReservationConfigurationFailed(let status):
        return "vmnet_network_configuration_add_dhcp_reservation() failed with status \(status)"
      case .PortForwardingConfigurationFailed(let rule, let status):
        return "vmnet_network_configuration_add_port_forwarding_rule(\(rule)) failed with status \(status)"
      case .InvalidIPv4Address(let address):
        return "invalid IPv4 address \"\(address)\""
      case .InvalidMACAddress(let macAddress):
        return "invalid MAC address \"\(macAddress)\""
      }
    }
  }

#endif
