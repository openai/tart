import NIO
import XCTest
@testable import NIOPosix
@testable import tart

// Avoid NSObject.bind and Tart's Darwin type shadowing the system function.
private let bindTestSocket = bind

@available(macOS 14, *)
final class ControlSocketTests: XCTestCase {
  func testInitializerCreatesControlSocketBeforeReturning() async throws {
    let temporaryDirectory = try makeTemporaryDirectory()
    let originalDirectory = FileManager.default.currentDirectoryPath
    defer {
      FileManager.default.changeCurrentDirectoryPath(originalDirectory)
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    let socketURL = URL(fileURLWithPath: "control.sock", relativeTo: temporaryDirectory)
    var controlSocket: ControlSocket? = try await ControlSocket(socketURL)
    let eventLoopGroup = try XCTUnwrap(controlSocket?.eventLoopGroup)

    do {
      let serverChannel = try XCTUnwrap(controlSocket?.serverChannel)
      XCTAssertTrue(FileManager.default.fileExists(atPath: socketURL.path))

      try await serverChannel.executeThenClose { _ in }
    }

    controlSocket = nil
    try await eventLoopGroup.shutdownGracefully()
  }

  func testAcceptErrorsRetryReadingAndForwardOtherErrors() async throws {
    let temporaryDirectory = try makeTemporaryDirectory()
    let originalDirectory = FileManager.default.currentDirectoryPath
    defer {
      FileManager.default.changeCurrentDirectoryPath(originalDirectory)
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    let socketURL = URL(fileURLWithPath: "control.sock", relativeTo: temporaryDirectory)
    let controlSocket = try await ControlSocket(socketURL)
    let channel = controlSocket.serverChannel.channel
    let observations = try await channel.eventLoop.submit {
      let observer = AcceptErrorObserver()
      // Placing this after the recovery handler also detects context.read(), which
      // bypasses downstream backpressure handlers instead of starting at the tail.
      try channel.pipeline.syncOperations.addHandler(observer)
      for _ in 0..<3 {
        channel.pipeline.fireErrorCaught(NIOFcntlFailedError())
      }
      let retries = observer.readCount
      let transientErrors = observer.errors.count
      channel.pipeline.fireErrorCaught(ChannelError.inputClosed)
      return (retries, transientErrors, observer.readCount,
              observer.errors.count, observer.errors.first as? ChannelError)
    }.get()

    try await controlSocket.serverChannel.executeThenClose { _ in }
    try await controlSocket.eventLoopGroup.shutdownGracefully()

    XCTAssertEqual(observations.0, 3)
    XCTAssertEqual(observations.1, 0)
    XCTAssertEqual(observations.2, 3)
    XCTAssertEqual(observations.3, 1)
    XCTAssertEqual(observations.4, .inputClosed)
  }

  func testAcceptErrorsDoNotEndInboundConnections() async throws {
    let temporaryDirectory = try makeTemporaryDirectory()
    let originalDirectory = FileManager.default.currentDirectoryPath
    defer {
      FileManager.default.changeCurrentDirectoryPath(originalDirectory)
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    let socketURL = URL(fileURLWithPath: "control.sock", relativeTo: temporaryDirectory)
    let controlSocket = try await ControlSocket(socketURL)
    let serverChannel = controlSocket.serverChannel

    do {
      try await serverChannel.executeThenClose { inbound in
        // Bound the wait if the listener stays open but stops accepting connections.
        let timeout = serverChannel.channel.eventLoop.scheduleTask(in: .seconds(10)) {
          serverChannel.channel.close(promise: nil)
        }
        defer { timeout.cancel() }

        var iterator = inbound.makeAsyncIterator()
        for _ in 0..<3 {
          try await serverChannel.channel.eventLoop.submit {
            serverChannel.channel.pipeline.fireErrorCaught(NIOFcntlFailedError())
          }.get()

          let clientChannel = try await ClientBootstrap(group: controlSocket.eventLoopGroup)
            .connectTimeout(.seconds(5))
            .connect(unixDomainSocketPath: socketURL.path)
            .get()
          defer { clientChannel.close(promise: nil) }

          // ControlSocket.run() consumes this stream. A recoverable accept error
          // must not prevent it from receiving the next connection.
          let nextChannel = try await iterator.next()
          let acceptedChannel = try XCTUnwrap(nextChannel, "The listener stopped delivering connections after an accept error")
          try await acceptedChannel.executeThenClose { _, _ in }
        }
      }
    } catch {
      try? await controlSocket.eventLoopGroup.shutdownGracefully()
      throw error
    }
    try await controlSocket.eventLoopGroup.shutdownGracefully()
  }

  func testInitializerPropagatesControlSocketCreationFailure() async throws {
    let temporaryDirectory = try makeTemporaryDirectory()
    let originalDirectory = FileManager.default.currentDirectoryPath
    defer {
      FileManager.default.changeCurrentDirectoryPath(originalDirectory)
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    let socketURL = URL(fileURLWithPath: "missing/control.sock", relativeTo: temporaryDirectory)

    do {
      _ = try await ControlSocket(socketURL)
      XCTFail("Binding should fail when the socket's parent directory does not exist")
    } catch {
      XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
    }
  }

  func testInitializerReplacesStaleSocketInLongEncodedPath() async throws {
    let temporaryDirectory = try makeTemporaryDirectory()
    let originalDirectory = FileManager.default.currentDirectoryPath
    defer {
      FileManager.default.changeCurrentDirectoryPath(originalDirectory)
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    let vmDirectory = temporaryDirectory.appendingPathComponent(
      "Tart Home %# 虚拟机 " + String(repeating: "v", count: 104), isDirectory: true
    )
    try FileManager.default.createDirectory(at: vmDirectory, withIntermediateDirectories: false)
    let socketURL = URL(fileURLWithPath: "control.sock", relativeTo: vmDirectory)
    XCTAssertGreaterThan(socketURL.path.utf8.count, 104)

    // Closing a POSIX socket leaves its path behind, as exiting "tart run" does.
    XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(vmDirectory.path))
    let expectedDirectory = FileManager.default.currentDirectoryPath
    let address = try SocketAddress(unixDomainSocketPath: "control.sock")
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    XCTAssertEqual(address.withSockAddr { bindTestSocket(descriptor, $0, socklen_t($1)) }, 0)
    XCTAssertEqual(close(descriptor), 0)
    XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(originalDirectory))

    var controlSocket: ControlSocket? = try await ControlSocket(socketURL)
    let eventLoopGroup = try XCTUnwrap(controlSocket?.eventLoopGroup)
    do {
      let serverChannel = try XCTUnwrap(controlSocket?.serverChannel)
      XCTAssertEqual(FileManager.default.currentDirectoryPath, expectedDirectory)
      XCTAssertTrue(FileManager.default.fileExists(atPath: socketURL.path))
      try await serverChannel.executeThenClose { _ in }
    }
    controlSocket = nil
    try await eventLoopGroup.shutdownGracefully()
  }

  func testProxyPassesClientHangUpToVM() async throws {
    try await withProxy { client, vm in
      // "tart exec" closes its connection once it has its response. The guest agent
      // only closes its end once it sees EOF, so the proxy has to pass it on.
      try await client.executeThenClose { _, outbound in
        try await outbound.write(ByteBuffer(string: "request"))
      }

      try await vm.executeThenClose { inbound, _ in
        let received = try await Self.readToEnd(inbound)
        XCTAssertEqual(received, Array("request".utf8))
      }
    }
  }

  func testProxyPassesVMHangUpToClient() async throws {
    try await withProxy { client, vm in
      try await vm.executeThenClose { _, outbound in
        try await outbound.write(ByteBuffer(string: "response"))
      }

      try await client.executeThenClose { inbound, _ in
        let received = try await Self.readToEnd(inbound)
        XCTAssertEqual(received, Array("response".utf8))
      }
    }
  }

  func testProxyDeliversBufferedDataBeforeHangingUp() async throws {
    let request = (0..<(8 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) }
    let response = (0..<(8 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 17) }

    try await withProxy { client, vm in
      // Each side writes more than the socket buffers hold and hangs up right away,
      // so the proxy still holds unwritten data when it sees the EOF.
      async let clientReceived: [UInt8] = client.executeThenClose { inbound, outbound in
        try await outbound.write(ByteBuffer(bytes: request))
        outbound.finish()
        return try await Self.readToEnd(inbound)
      }
      async let vmReceived: [UInt8] = vm.executeThenClose { inbound, outbound in
        try await outbound.write(ByteBuffer(bytes: response))
        outbound.finish()
        return try await Self.readToEnd(inbound)
      }

      let (fromVM, fromClient) = try await (clientReceived, vmReceived)
      XCTAssertEqual(fromClient.count, request.count)
      XCTAssertTrue(fromClient == request, "The VM did not receive the client's data intact")
      XCTAssertEqual(fromVM.count, response.count)
      XCTAssertTrue(fromVM == response, "The client did not receive the VM's data intact")
    }
  }

  private typealias ProxyEnd = NIOAsyncChannel<ByteBuffer, ByteBuffer>

  /// Runs ControlSocket's proxy between two socket pairs, as "tart run" does between a control
  /// socket client and a VM, and hands `body` the far ends: the client's and the VM's.
  private func withProxy(_ body: (ProxyEnd, ProxyEnd) async throws -> Void) async throws {
    let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    do {
      let (client, proxyClient) = try await makeSocketPair(eventLoopGroup)
      let (proxyVM, vm) = try await makeSocketPair(eventLoopGroup)

      let proxy = Task {
        try await proxyClient.executeThenClose { clientInbound, clientOutbound in
          try await proxyVM.executeThenClose { vmInbound, vmOutbound in
            await ControlSocket.proxy(
              client: proxyClient, clientInbound: clientInbound, clientOutbound: clientOutbound,
              vm: proxyVM, vmInbound: vmInbound, vmOutbound: vmOutbound
            )
          }
        }
      }

      // A proxy that doesn't pass on an EOF would leave the reads in `body` waiting forever.
      let timeout = Task {
        try await Task.sleep(for: .seconds(10))
        XCTFail("The proxy did not pass on a hang-up")
        proxyClient.channel.close(promise: nil)
        proxyVM.channel.close(promise: nil)
      }
      defer { timeout.cancel() }

      try await body(client, vm)
      try await proxy.value
    } catch {
      try? await eventLoopGroup.shutdownGracefully()
      throw error
    }
    try await eventLoopGroup.shutdownGracefully()
  }

  private func makeSocketPair(_ eventLoopGroup: EventLoopGroup) async throws -> (ProxyEnd, ProxyEnd) {
    var descriptors: [CInt] = [-1, -1]
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)

    func wrap(_ descriptor: CInt) async throws -> ProxyEnd {
      try await ClientBootstrap(group: eventLoopGroup)
        .channelOption(.allowRemoteHalfClosure, value: true)
        .withConnectedSocket(descriptor) { channel in
          channel.eventLoop.makeCompletedFuture {
            try ProxyEnd(wrappingChannelSynchronously: channel, configuration: ControlSocket.proxiedChannelConfiguration)
          }
        }
    }

    return (try await wrap(descriptors[0]), try await wrap(descriptors[1]))
  }

  private static func readToEnd(_ inbound: NIOAsyncChannelInboundStream<ByteBuffer>) async throws -> [UInt8] {
    var received: [UInt8] = []
    for try await buffer in inbound {
      received += buffer.readableBytesView
    }
    return received
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
  }
}

private final class AcceptErrorObserver: ChannelDuplexHandler {
  typealias InboundIn = Channel
  typealias OutboundIn = ByteBuffer

  var readCount = 0
  var errors: [Error] = []

  func read(context: ChannelHandlerContext) {
    readCount += 1
    context.read()
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    errors.append(error)
  }
}
