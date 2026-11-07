import ArgumentParser
import Foundation
import NIO
import NIOPosix

struct USB: AsyncParsableCommand {
  static var configuration = CommandConfiguration(
    commandName: "usb",
    abstract: "Move USB devices between running VMs",
    discussion: """
    Only sees VMs with a USB menu or started with --usb, and the devices that macOS assigned to the app that started them. \
    Assigning a device to an app is up to the user, see https://tart.run/faq/#usb-passthrough.
    """,
    subcommands: [USBList.self, USBAttach.self, USBDetach.self]
  )
}

struct USBList: AsyncParsableCommand {
  static var configuration = CommandConfiguration(commandName: "list", abstract: "List the USB devices that running VMs can see")

  @Option(help: "Output format: text or json", completion: .list(["text", "json"]))
  var format: Format = .text

  func run() async throws {
    var devices: [USBDeviceInfo] = []

    for (name, vmDir) in try VMStorageLocal().list() {
      guard let reply = try? await usbRequest(vmDir, "list") else {
        continue
      }

      for var device in reply.devices {
        device.VM = name
        devices.append(device)
      }
    }

    print(format.renderList(devices))
  }
}

struct USBAttach: AsyncParsableCommand {
  static var configuration = CommandConfiguration(commandName: "attach", abstract: "Attach a USB device to a running VM, detaching it from any other VM")

  @Argument(help: "VM name", completion: .custom(completeRunningMachines))
  var name: String

  @Argument(help: ArgumentHelp("Device, in the format of --usb", valueName: "vendor:product"))
  var device: String

  func run() async throws {
    let filter = try USBFilter(parseFrom: device)
    let storage = try VMStorageLocal()
    let vmDir = try storage.open(name)

    // List the VMs before any request, because a request changes the working directory
    // that a relative TART_HOME resolves against
    let otherVMs = try storage.list().filter { $0.0 != name }

    var target = try await usbRequest(vmDir, "list")

    // A device that just left a VM comes back a moment later, under a new registry ID
    for _ in 1...20 where target.error == nil && !target.devices.contains(where: { filter.matches($0.Device) }) {
      try await Task.sleep(nanoseconds: 250_000_000)
      target = try await usbRequest(vmDir, "list")
    }

    let devices = target.devices.map(\.Device).filter(filter.matches)

    // Fail before detaching from the other VMs, because a device that this VM can't take
    // would end up in no VM at all
    if let error = target.error {
      throw RuntimeError.Generic("VM \"\(name)\" can't take \(device): \(error)")
    }

    guard !devices.isEmpty else {
      throw RuntimeError.Generic("VM \"\(name)\" can't see \(device): check that it's connected and matches the --usb filters of the VM, if it has any, and that someone assigned it to the app of this VM in the Virtual Machine Accessories menu bar item")
    }

    for device in devices {
      // Errors don't matter here, as the attach below fails if a VM still holds the device
      for (_, otherDir) in otherVMs {
        _ = try? await usbRequest(otherDir, "detach \(device)")
      }

      // A device that left another VM reaches this one a moment later, under a new registry ID
      var reply = try await usbRequest(vmDir, "attach \(device)")

      for _ in 1...20 where reply.error != nil {
        try await Task.sleep(nanoseconds: 250_000_000)
        reply = try await usbRequest(vmDir, "attach \(device)")
      }

      if let error = reply.error {
        throw RuntimeError.Generic(error)
      }
    }
  }
}

struct USBDetach: AsyncParsableCommand {
  static var configuration = CommandConfiguration(commandName: "detach", abstract: "Detach a USB device from a running VM until the USB menu or \"tart usb attach\" attaches it again")

  @Argument(help: "VM name", completion: .custom(completeRunningMachines))
  var name: String

  @Argument(help: ArgumentHelp("Device, in the format of --usb", valueName: "vendor:product"))
  var device: String

  func validate() throws {
    _ = try USBFilter(parseFrom: device)
  }

  func run() async throws {
    if let error = try await usbRequest(try VMStorageLocal().open(name), "detach \(device)").error {
      throw RuntimeError.Generic(error)
    }
  }
}

/// Sends a request to a running VM, see `USBSocket`.
func usbRequest(_ vmDir: VMDirectory, _ request: String) async throws -> USBReply {
  let noUSB = RuntimeError.Generic("VM \"\(vmDir.name)\" has no USB: it must be running with a window or --usb, on a Tart build that supports it, see https://tart.run/faq/#usb-passthrough")

  // Work around the Unix domain socket 104 byte limitation, like "tart exec" does.
  // Staying in the previous directory would send this request to the previous VM.
  guard FileManager.default.changeCurrentDirectoryPath(vmDir.baseURL.path) else {
    throw noUSB
  }

  let channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>

  do {
    channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .connect(unixDomainSocketPath: vmDir.usbSocketURL.relativePath) { channel in
        channel.eventLoop.makeCompletedFuture {
          try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
        }
      }
  } catch {
    throw noUSB
  }

  return try await channel.executeThenClose { inbound, outbound in
    try await outbound.write(ByteBuffer(string: request + "\n"))

    var reply = Data()
    for try await buffer in inbound {
      reply.append(contentsOf: buffer.readableBytesView)
    }

    return try JSONDecoder().decode(USBReply.self, from: reply)
  }
}
