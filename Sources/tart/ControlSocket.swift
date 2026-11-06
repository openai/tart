import Foundation
import Darwin
import System
import Virtualization
import Network
import os.log
import NIO
import NIOPosix

@available(macOS 14, *)
class ControlSocket {
  typealias ServerChannel = NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>

  let controlSocketURL: URL
  let vmPort: UInt32
  let eventLoopGroup: MultiThreadedEventLoopGroup
  let serverChannel: ServerChannel
  let logger: os.Logger = os.Logger(subsystem: "org.cirruslabs.tart.control-socket", category: "network")

  init(_ controlSocketURL: URL, vmPort: UInt32 = 8080) async throws {
    self.controlSocketURL = controlSocketURL
    self.vmPort = vmPort
    let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    self.eventLoopGroup = eventLoopGroup

    // Remove control socket file from previous "tart run" invocations,
    // if any, otherwise we may get the "address already in use" error
    try? FileManager.default.removeItem(at: controlSocketURL)

    // Change the current working directory to a VM's base directory
    // to work around Unix domain socket 104 byte limitation [1]
    //
    // [1]: https://blog.8-p.info/en/2020/06/11/unix-domain-socket-length/
    if let baseURL = controlSocketURL.baseURL {
      FileManager.default.changeCurrentDirectoryPath(baseURL.absoluteURL.path(percentEncoded: false))
    }

    do {
      self.serverChannel = try await ServerBootstrap(group: eventLoopGroup)
        .childChannelOption(.allowRemoteHalfClosure, value: true)
        .serverChannelInitializer { channel in
          channel.pipeline.addHandler(
            ControlSocketAcceptErrorHandler(),
            name: "ControlSocketAcceptErrorHandler"
          )
        }
        .bind(unixDomainSocketPath: controlSocketURL.relativePath) { childChannel in
          childChannel.eventLoop.makeCompletedFuture {
            return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
              wrappingChannelSynchronously: childChannel,
              configuration: Self.proxiedChannelConfiguration
            )
          }
        }
    } catch {
      try? await eventLoopGroup.shutdownGracefully()
      throw error
    }
  }

  func run() async throws {
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

        // Duplicate the connection's file descriptor
        //
        // This way VZVirtioSocketConnection and NIO won't race to close the same descriptor,
        // which may result in "tart run" crashing because of NIO's fatal assertion on EBADF.
        let vmSocket = try duplicateAndCloseConnection(vmConnection)

        let vmChannel = try await ClientBootstrap(group: eventLoopGroup)
          .channelOption(.allowRemoteHalfClosure, value: true)
          .withConnectedSocket(vmSocket) { childChannel in
            childChannel.eventLoop.makeCompletedFuture {
              try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                wrappingChannelSynchronously: childChannel,
                configuration: Self.proxiedChannelConfiguration
              )
            }
          }

        try await vmChannel.executeThenClose { (vmInbound, vmOutbound) in
          await Self.proxy(
            client: clientChannel, clientInbound: clientInbound, clientOutbound: clientOutbound,
            vm: vmChannel, vmInbound: vmInbound, vmOutbound: vmOutbound
          )
        }

        self.logger.info("control socket client disconnected")
      } catch (let error) {
        self.logger.error("control socket connection failed: \(error)")
      }
    }
  }

  // Both channels are created with remote half-closure allowed, so that an EOF from one side
  // ends its inbound stream instead of closing the whole channel, and with outbound half-closure
  // enabled, so that finishing an outbound writer shuts down the socket's write side.
  static let proxiedChannelConfiguration = NIOAsyncChannel<ByteBuffer, ByteBuffer>.Configuration(
    isOutboundHalfClosureEnabled: true
  )

  /// Proxies data between a client (e.g. "tart exec") and a VM until both sides hang up.
  ///
  /// When one side hangs up, its EOF is passed on to the other side, which then hangs up too.
  /// Without this, a client that disconnected left the connection to the VM open: the guest
  /// agent's gRPC server keeps an idle connection until it sees EOF, so every "tart exec"
  /// leaked a VirtIO socket connection, and with it a file descriptor in both "tart run" and
  /// Virtualization.framework's VM process, which crashes once it runs out of them.
  static func proxy(
    client: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
    clientInbound: NIOAsyncChannelInboundStream<ByteBuffer>,
    clientOutbound: NIOAsyncChannelOutboundWriter<ByteBuffer>,
    vm: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
    vmInbound: NIOAsyncChannelInboundStream<ByteBuffer>,
    vmOutbound: NIOAsyncChannelOutboundWriter<ByteBuffer>
  ) async {
    await withDiscardingTaskGroup { group in
      // Proxy data from a client (e.g. "tart exec") to a VM
      group.addTask {
        await pipe(clientInbound, to: vmOutbound, of: vm.channel)
      }

      // Proxy data from a VM to a client (e.g. "tart exec")
      group.addTask {
        await pipe(vmInbound, to: clientOutbound, of: client.channel)
      }
    }
  }

  private static func pipe(
    _ inbound: NIOAsyncChannelInboundStream<ByteBuffer>,
    to outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>,
    of channel: Channel
  ) async {
    // Either direction ending, even with an error, leaves the other one running, so that it
    // can still deliver what its side sent before hanging up.
    do {
      for try await message in inbound {
        try await outbound.write(message)
      }

      // A write returns once the channel has the data, not once it's in the socket. Shutting
      // down the output of a channel whose input is already closed closes it completely, which
      // drops writes that are still pending, so wait for them first: writes complete in order.
      try await channel.writeAndFlush(ByteBuffer()).get()
    } catch {
      // The connection is gone, so there is nothing left to deliver over it
    }

    outbound.finish()
  }

  private func duplicateAndCloseConnection(_ connection: VZVirtioSocketConnection) throws -> CInt {
    defer { connection.close() }

    let fd = fcntl(connection.fileDescriptor, F_DUPFD_CLOEXEC, 0)
    guard fd >= 0 else {
      throw Errno(rawValue: errno)
    }

    return fd
  }
}

private final class ControlSocketAcceptErrorHandler: ChannelInboundHandler {
  typealias InboundIn = Channel
  typealias InboundOut = Channel

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    if error is NIOFcntlFailedError {
      context.channel.read()
    } else {
      context.fireErrorCaught(error)
    }
  }
}
