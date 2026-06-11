import Foundation
import Network
import os.log
import NIO
import NIOPosix

@available(macOS 14, *)
class ControlSocket {
  let controlSocketURL: URL
  let vmPort: UInt32
  let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  let logger: os.Logger = os.Logger(subsystem: "org.cirruslabs.tart.control-socket", category: "network")

  init(_ controlSocketURL: URL, vmPort: UInt32 = 8080) {
    self.controlSocketURL = controlSocketURL
    self.vmPort = vmPort
  }

  func run() async throws {
    // Remove control socket file from previous "tart run" invocations,
    // if any, otherwise we may get the "address already in use" error
    try? FileManager.default.removeItem(atPath: controlSocketURL.path)

    // Change the current working directory to a VM's base directory
    // to work around Unix domain socket 104 byte limitation [1]
    //
    // [1]: https://blog.8-p.info/en/2020/06/11/unix-domain-socket-length/
    if let baseURL = controlSocketURL.baseURL {
      FileManager.default.changeCurrentDirectoryPath(baseURL.path())
    }

    let serverChannel = try await ServerBootstrap(group: eventLoopGroup)
      .bind(unixDomainSocketPath: controlSocketURL.relativePath) { childChannel in
        childChannel.eventLoop.makeCompletedFuture {
          return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
            wrappingChannelSynchronously: childChannel
          )
        }
      }

    try await withThrowingDiscardingTaskGroup { group in
      try await serverChannel.executeThenClose { serverInbound in
        for try await clientChannel in serverInbound {
          group.addTask {
            try await self.handleClient(clientChannel)
          }
        }
      }
    }
  }

  func handleClient(_ clientChannel: NIOAsyncChannel<ByteBuffer, ByteBuffer>) async throws {
    self.logger.info("received new control socket connection from a client")

    try await clientChannel.executeThenClose { clientInbound, clientOutbound in
      self.logger.info("dialing to VM on port \(self.vmPort)...")

      do {
        guard let vmConnection = try await vm?.connect(toPort: self.vmPort) else {
          throw RuntimeError.VMSocketFailed(self.vmPort, "VM is not running")
        }

        self.logger.info("running control socket proxy")

        let vmChannel = try await ClientBootstrap(group: eventLoopGroup).withConnectedSocket(vmConnection.fileDescriptor) { childChannel in
          childChannel.eventLoop.makeCompletedFuture {
            try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
              wrappingChannelSynchronously: childChannel
            )
          }
        }

        try await vmChannel.executeThenClose { (vmInbound, vmOutbound) in
          try await withThrowingDiscardingTaskGroup { group in
            // Proxy data from a client (e.g. "tart exec") to a VM
            group.addTask {
              for try await message in clientInbound {
                try await vmOutbound.write(message)
              }
            }

            // Proxy data from a VM to a client (e.g. "tart exec")
            group.addTask {
              for try await message in vmInbound {
                try await clientOutbound.write(message)
              }
            }
          }
        }

        self.logger.info("control socket client disconnected")
      } catch (let error) {
        self.logger.error("control socket connection failed: \(error)")
      }
    }
  }
}
