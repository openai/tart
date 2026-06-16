// Native vmnet-backed networking, adopting the macOS 27 (WWDC26) Virtualization
// API surface introduced in session 224 ("Expand the capabilities of your
// Virtualization app").
//
// Goal: provide a sidecar-free alternative to the external Softnet process for
// CI-style port forwarding from host TCP/UDP ports to guest ports. The vmnet
// configuration is created in-process and handed to
// VZVmnetNetworkDeviceAttachment, so the VM keeps using the standard
// VZVirtioNetworkDeviceConfiguration path.
//
// Compile-verification status: this file targets Swift 6.4 (Xcode 27 beta) and
// the macOS 27 SDK headers. The host Swift available when this branch was
// written was 6.3.2, so it has not been compiled. The C entry points used here
// (vmnet_network_configuration_create, vmnet_network_create) are the names
// shown verbatim in WWDC26 session 224. The port-forwarding configuration
// symbol is not stated in the session and is left as a clearly marked FIXME so
// it can be wired up once the final Xcode 27 headers are available.
//
// The whole file is gated behind `#if compiler(>=6.4)` to match how Tart
// already gates VZMacGuestProvisioningOptions in VM.swift (the same situation:
// macOS 27 SDK symbols referenced by a tree that still builds under Xcode 26).

import Foundation
import Semaphore
import Virtualization

#if compiler(>=6.4)
  import vmnet

  @available(macOS 27, *)
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

    private let network: vmnet_network_t
    private let portForwardings: [PortForwarding]

    init(portForwardings: [PortForwarding] = []) throws {
      self.portForwardings = portForwardings

      var configStatus: vmnet_return_t = .VMNET_FAILURE
      guard let configuration = vmnet_network_configuration_create(.VMNET_SHARED_MODE, &configStatus) else {
        throw NetworkVmnetError.ConfigurationCreationFailed(status: configStatus)
      }
      defer { vmnet_network_configuration_release(configuration) }

      try Self.applyPortForwarding(rules: portForwardings, to: configuration)

      var networkStatus: vmnet_return_t = .VMNET_FAILURE
      guard let network = vmnet_network_create(configuration, &networkStatus) else {
        throw NetworkVmnetError.NetworkCreationFailed(status: networkStatus)
      }
      self.network = network
    }

    deinit {
      vmnet_network_release(network)
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

    // FIXME(macOS 27 SDK): wire up the actual vmnet port-forwarding setter.
    //
    // WWDC26 session 224 advertises "forward host TCP/UDP ports to specific
    // VMs" as part of the new vmnet_network_configuration_t surface but does
    // not show the exact C symbol. Once the final Xcode 27 SDK ships, replace
    // the body below with the real calls (likely shaped like
    // `vmnet_network_configuration_add_port_forwarding_rule(configuration,
    // protocol, externalPort, internalPort, &status)`).
    //
    // For now, refuse to start a VM with port-forwarding rules so the failure
    // mode is loud rather than silently dropped traffic.
    private static func applyPortForwarding(
      rules: [PortForwarding],
      to configuration: vmnet_network_configuration_t
    ) throws {
      guard !rules.isEmpty else { return }
      throw NetworkVmnetError.PortForwardingPendingSDKFinalization
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
  }

  enum NetworkVmnetError: Error, CustomStringConvertible {
    case ConfigurationCreationFailed(status: vmnet_return_t)
    case NetworkCreationFailed(status: vmnet_return_t)
    case InvalidPortForwardingSpec(spec: String, why: String)
    case PortForwardingPendingSDKFinalization

    var description: String {
      switch self {
      case .ConfigurationCreationFailed(let status):
        return "vmnet_network_configuration_create() failed with status \(status)"
      case .NetworkCreationFailed(let status):
        return "vmnet_network_create() failed with status \(status)"
      case .InvalidPortForwardingSpec(let spec, let why):
        return "invalid port forwarding spec \"\(spec)\": \(why)"
      case .PortForwardingPendingSDKFinalization:
        return "--net-vmnet-expose is not yet wired through to the macOS 27 vmnet port-forwarding API; "
          + "use --net-softnet-expose for now or remove the rule"
      }
    }
  }

#endif
