import ArgumentParser
import Foundation
import Network
import SystemConfiguration

enum IPResolutionStrategy: String, ExpressibleByArgument, CaseIterable {
  case dhcp, arp, agent

  private(set) static var allValueStrings: [String] = Self.allCases.map { "\($0)"}
}

struct IP: AsyncParsableCommand {
  static var configuration = CommandConfiguration(abstract: "Get VM's IP address")

  @Argument(help: "VM name", completion: .custom(completeLocalMachines))
  var name: String

  @Option(help: "Number of seconds to wait for a potential VM booting")
  var wait: UInt16 = 0

  @Option(help: ArgumentHelp("Strategy for resolving IP address",
                             discussion: """
                             By default, Tart is using a "dhcp" resolver which parses the DHCP lease file on host and tries to find an entry containing the VM's MAC address. This method is fast and the most reliable, but only works for VMs are not using the bridged networking.\n
                             Alternatively, Tart has an "arp" resolver which calls an external "arp" executable and parses it's output. This works for VMs using bridged networking and returns their IP, but when they generate enough network activity to populate the host's ARP table. Note that "arp" strategy won't work for VMs using the Softnet networking.\n
                             A third strategy, "agent" works in all cases reliably, but requires Guest agent for Tart VMs (https://github.com/cirruslabs/tart-guest-agent) to be installed inside of a VM.
                             """))
  var resolver: IPResolutionStrategy = .dhcp

  func run() async throws {
    let vmDir = try VMStorageLocal().open(name)
    let vmConfig = try VMConfig.init(fromURL: vmDir.configURL)
    let vmMACAddress = MACAddress(fromString: vmConfig.macAddress.string)!

    guard let ip = try await IP.resolveIP(vmMACAddress, resolutionStrategy: resolver, secondsToWait: wait, controlSocketURL: vmDir.controlSocketURL) else {
      var message = "no IP address found"

      if try !vmDir.running() {
        message += ", is your VM running?"
      }

      if (resolver == .agent) {
        message += " (also make sure that Guest agent for Tart is running inside of a VM)"
      } else if (vmConfig.os == .linux && resolver == .arp) {
        message += " (not all Linux distributions are compatible with the ARP resolver)"
      }

      throw RuntimeError.NoIPAddressFound(message)
    }

    print(ip)
  }

  static public func resolveIP(_ vmMACAddress: MACAddress, resolutionStrategy: IPResolutionStrategy = .dhcp, secondsToWait: UInt16 = 0, controlSocketURL: URL? = nil) async throws -> IPv4Address? {
    let waitUntil = Calendar.current.date(byAdding: .second, value: Int(secondsToWait), to: Date.now)!

    repeat {
      switch resolutionStrategy {
      case .arp:
        if let ip = try ARPCache().ResolveMACAddress(macAddress: vmMACAddress) {
          return ip
        }
      case .dhcp:
        if let leases = try Leases(), let ip = leases.ResolveMACAddress(macAddress: vmMACAddress) {
          return ip
        }
      case .agent:
        guard let controlSocketURL = controlSocketURL else {
          throw RuntimeError.Generic("Cannot perform IP resolution via Tart Guest Agent when control socket URL is not set")
        }

        // Change the current working directory to a VM's base directory
        // to work around Unix domain socket 104 byte limitation [1]
        //
        // [1]: https://blog.8-p.info/en/2020/06/11/unix-domain-socket-length/
        if let baseURL = controlSocketURL.baseURL {
          FileManager.default.changeCurrentDirectoryPath(baseURL.path)
        }

        if let ip = try await AgentResolver.ResolveIP(controlSocketURL.relativePath) {
          return ip
        }
      }

      // wait a second
      try await Task.sleep(nanoseconds: 1_000_000_000)
    } while Date.now < waitUntil

    return nil
  }
}
