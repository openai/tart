import ArgumentParser
import Foundation
import IOKit
import NIO
import Security
import Virtualization

#if canImport(AccessoryAccess)
  import AccessoryAccess
#endif

/// Which host USB devices `tart run --usb` offers to the VM.
enum USBFilter: Equatable {
  case any
  case device(vendorID: UInt16, productID: UInt16)

  init(parseFrom: String) throws {
    if parseFrom == "any" {
      self = .any
      return
    }

    let ids = parseFrom.split(separator: ":", omittingEmptySubsequences: false).map { UInt16($0, radix: 16) }

    guard ids.count == 2, let vendorID = ids[0], let productID = ids[1] else {
      throw ValidationError("expected \"any\" or hexadecimal vendor:product IDs (e.g. 05ac:12a8)")
    }

    self = .device(vendorID: vendorID, productID: productID)
  }

  func matches(_ deviceID: String) -> Bool {
    switch self {
    case .any:
      return true
    case .device(let vendorID, let productID):
      return deviceID == String(format: "%04x:%04x", vendorID, productID)
    }
  }
}

/// One row of the USB menu in the menu bar.
struct USBMenuItem: Identifiable {
  let id: UInt64
  let deviceID: String
  let name: String
  let attached: Bool
  let toggle: () async throws -> Void

  var title: String {
    "\(name) (\(deviceID))"
  }
}

/// A USB device as `tart usb` reports it.
struct USBDeviceInfo: Codable {
  var VM = ""
  let Device: String
  let Name: String
  let Attached: Bool
}

/// What a running VM answers to `tart usb`.
struct USBReply: Codable {
  let devices: [USBDeviceInfo]
  var error: String?
}

/// Answers `tart usb` for one running VM: one line in, one `USBReply` out, on each connection.
@available(macOS 14, *)
class USBSocket: ControlSocket {
  let handler: (String) async -> USBReply

  init(_ socketURL: URL, handler: @escaping (String) async -> USBReply) async throws {
    self.handler = handler
    try await super.init(socketURL)
  }

  override func handleClient(_ clientChannel: NIOAsyncChannel<ByteBuffer, ByteBuffer>) async throws {
    // An error here would stop the socket for everyone else
    try? await clientChannel.executeThenClose { inbound, outbound in
      var request = ""

      for try await var buffer in inbound {
        request += buffer.readString(length: buffer.readableBytes) ?? ""

        if request.hasSuffix("\n") {
          break
        }
      }

      let reply = await self.handler(request.trimmingCharacters(in: .newlines))
      try await outbound.write(ByteBuffer(bytes: try JSONEncoder().encode(reply)))
    }
  }
}

/// Reads the vendor and product IDs of a USB device descriptor, in the format of `--usb`.
func usbDeviceID(descriptor: Data) -> String {
  let bytes = [UInt8](descriptor)

  return String(format: "%02x%02x:%02x%02x", bytes[9], bytes[8], bytes[11], bytes[10])
}

extension VM {
  /// AccessoryAccess refuses to talk to a process without this entitlement, and the
  /// error it returns doesn't say so. macOS kills ad-hoc signed binaries that claim the
  /// entitlement, so only builds with a matching provisioning profile can have it.
  static var isUSBPassthroughSupported: Bool {
    #if canImport(AccessoryAccess)
      if #available(macOS 27, *), let task = SecTaskCreateFromSelf(nil) {
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.accessory-access.usb" as CFString, nil) as? Bool == true
      }
    #endif

    return false
  }

  /// Follows the USB devices that macOS assigns to the app it holds responsible for Tart, keeps
  /// the USB menu up to date and answers `tart usb` on `socketURL`. Devices that match `filters`
  /// attach on their own. With no filters the VM sees every device and attaches none until
  /// someone asks for it. Throws if the socket or AccessoryAccess can't start, and otherwise
  /// never returns.
  @MainActor
  func attachUSBDevices(matching filters: [USBFilter], socketURL: URL) async throws {
    #if canImport(AccessoryAccess)
      guard #available(macOS 27, *) else {
        return
      }

      // An empty list matches every USB device
      let criteria = filters.contains(.any) ? [] : filters.compactMap { filter -> AAUSBAccessoryMatchingCriteria? in
        guard case .device(let vendorID, let productID) = filter else {
          return nil
        }

        return AAUSBAccessoryMatchingCriteria(deviceMatchingCriteria: .init(vendorID: Int(vendorID), productID: Int(productID)))
      }

      let devices = USBDevices(vm: self, attachesOnConnect: !filters.isEmpty)
      let socket = try await USBSocket(socketURL) { await devices.handle($0) }

      ErrorReportingTask("Failed to run USB socket") {
        try await socket.run()
      }

      // AccessoryAccess holds the sequence weakly and a for-await loop doesn't retain it,
      // so without this reference the loop ends right after registering
      let events = try await AAUSBAccessoryManager.shared.events(matching: criteria)
      defer { withExtendedLifetime(events) {} }

      // Devices that were already assigned arrive here as connect events too
      for await event in events {
        switch event {
        case .didConnect(let accessory):
          devices.connected(accessory)
        case .didDisconnect(let accessory):
          await devices.disconnected(accessory)
        @unknown default:
          break
        }
      }
    #endif
  }
}

#if canImport(AccessoryAccess)
  /// The USB devices that this VM can see. Every VM started from the same app sees a device that
  /// its `--usb` filters match, or any device without `--usb`, and only one of them can hold it
  /// at a time.
  @available(macOS 27, *)
  @MainActor
  private class USBDevices {
    let vm: VM
    let attachesOnConnect: Bool
    let controller: VZUSBController
    var accessories: [UInt64: AAUSBAccessory] = [:]
    var attached: [UInt64: VZUSBPassthroughDevice] = [:]
    var attaching: Swift.Set<UInt64> = []

    // Vendor and product IDs of the devices that this VM only attaches when asked to, from the
    // USB menu or with `tart usb attach`. A registry ID wouldn't do, because it changes whenever
    // a device moves between VMs.
    //
    // Identical devices share an entry. Add the port if anyone needs to tell them apart.
    var onRequest: Swift.Set<String> = []

    init(vm: VM, attachesOnConnect: Bool) {
      self.vm = vm
      self.attachesOnConnect = attachesOnConnect
      controller = vm.virtualMachine.usbControllers[0]
    }

    func connected(_ accessory: AAUSBAccessory) {
      let id = accessory.registryID
      let deviceID = usbDeviceID(descriptor: accessory.deviceDescriptorData)

      accessories[id] = accessory
      updateMenu()

      guard attachesOnConnect, !onRequest.contains(deviceID) else {
        return
      }

      // Attaching needs a running VM and this event won't repeat, so wait for the VM to run again
      // after Control > Stop. The wait has its own task, because in the for-await loop it would
      // hold back the events that replace this device.
      Task {
        while vm.virtualMachine.state != .running && accessories[id] != nil {
          try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        guard accessories[id] != nil, attached[id] == nil, !onRequest.contains(deviceID) else {
          return
        }

        do {
          try await attach(accessory)
        } catch {
          // Usually another VM got there first, so leave the choice to the user
          if accessories[id] != nil {
            onRequest.insert(deviceID)
          }

          fputs("Failed to attach USB device \(deviceID): \(error)\n", stderr)
        }
      }
    }

    func disconnected(_ accessory: AAUSBAccessory) async {
      accessories.removeValue(forKey: accessory.registryID)
      updateMenu()

      guard let device = attached.removeValue(forKey: accessory.registryID) else {
        return
      }

      do {
        try await detach(device, accessory)
      } catch {
        fputs("Failed to detach USB device: \(error)\n", stderr)
      }
    }

    func attach(_ accessory: AAUSBAccessory) async throws {
      // The USB menu, `tart usb` and a new device can all get here at once
      guard attaching.insert(accessory.registryID).inserted else {
        return
      }

      defer { attaching.remove(accessory.registryID) }

      let configuration = VZUSBPassthroughDeviceConfiguration(device: accessory)
      let device = try VZUSBPassthroughDevice(configuration: configuration)
      try await controller.attach(device: device)
      attached[accessory.registryID] = device
      onRequest.remove(usbDeviceID(descriptor: accessory.deviceDescriptorData))
      updateMenu()
      print("attached USB device \(String(format: "0x%llx", accessory.registryID))")
    }

    func detach(_ device: VZUSBPassthroughDevice, _ accessory: AAUSBAccessory) async throws {
      // Nothing to detach if the device was unplugged or the VM has stopped
      if device.usbController != nil && vm.virtualMachine.state == .running {
        try await controller.detach(device: device)
      }

      print("detached USB device \(String(format: "0x%llx", accessory.registryID))")
    }

    /// Detaches a device, if this VM has it, and keeps it detached until someone asks for it.
    func release(_ accessory: AAUSBAccessory) async throws {
      // An attach in flight would clear the mark below and keep the device, so let it finish
      while attaching.contains(accessory.registryID) {
        try? await Task.sleep(nanoseconds: 10_000_000)
      }

      // The device comes back with a connect event as soon as it's detached, so mark it first
      onRequest.insert(usbDeviceID(descriptor: accessory.deviceDescriptorData))

      guard let device = attached[accessory.registryID] else {
        return
      }

      try await detach(device, accessory)
      attached.removeValue(forKey: accessory.registryID)
      updateMenu()
    }

    /// Runs a `tart usb` request: `list`, or `attach` or `detach` followed by a device.
    func handle(_ request: String) async -> USBReply {
      do {
        let words = request.split(separator: " ").map(String.init)

        if words.count == 2 {
          let filter = try USBFilter(parseFrom: words[1])
          let matching = accessories.values.filter { filter.matches(usbDeviceID(descriptor: $0.deviceDescriptorData)) }

          if words[0] == "attach" && matching.isEmpty {
            return USBReply(devices: deviceInfos(), error: "no device matching \(words[1])")
          }

          for accessory in matching {
            if words[0] == "detach" {
              try await release(accessory)
            } else if attached[accessory.registryID] == nil {
              try await attach(accessory)
            }
          }
        }

        // Tells `tart usb attach` to leave the other VMs alone, as attaching here can't work
        if words.count != 2 && vm.virtualMachine.state != .running {
          return USBReply(devices: deviceInfos(), error: "the VM is stopped, bring its window to the front and use Control > Start in the menu bar")
        }

        return USBReply(devices: deviceInfos())
      } catch {
        return USBReply(devices: deviceInfos(), error: error.localizedDescription)
      }
    }

    func deviceInfos() -> [USBDeviceInfo] {
      vm.usbMenuItems.map { USBDeviceInfo(Device: $0.deviceID, Name: $0.name, Attached: $0.attached) }
    }

    func updateMenu() {
      vm.usbMenuItems = accessories.values.sorted { $0.registryID < $1.registryID }.map { accessory in
        USBMenuItem(
          id: accessory.registryID,
          deviceID: usbDeviceID(descriptor: accessory.deviceDescriptorData),
          name: name(accessory),
          attached: attached[accessory.registryID] != nil
        ) {
          if self.attached[accessory.registryID] == nil {
            try await self.attach(accessory)
          } else {
            try await self.release(accessory)
          }
        }
      }
    }

    func name(_ accessory: AAUSBAccessory) -> String {
      let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(accessory.registryID))
      defer { IOObjectRelease(service) }

      let name = IORegistryEntryCreateCFProperty(service, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String

      return name ?? "USB device"
    }
  }
#endif
