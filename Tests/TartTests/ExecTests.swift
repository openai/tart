import Foundation
@preconcurrency import GRPC
import NIOCore
import NIOPosix
import SwiftProtobuf
import XCTest
import Cirruslabs_TartGuestAgent_Grpc_Swift
import Cirruslabs_TartGuestAgent_Apple_Swift
@testable import tart

final class ExecTests: XCTestCase {
  func testFileInputIsBoundedByStalledHTTP2Reader() async throws {
    try await checkStalledFile(earlyExit: true)
  }

  func testStalledFileResumesWithoutLosingBytesOrEOF() async throws {
    try await checkStalledFile(earlyExit: false)
  }

  private func checkStalledFile(earlyExit: Bool) async throws {
    // A modest file is enough: the HTTP/2 window is only 65,535 bytes.
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let bytes = (0..<256).reduce(into: Data()) { data, index in
      data.append(Data(repeating: UInt8(index), count: ExecInput.chunkSize))
    }
    try bytes.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let input = try FileHandle(forReadingFrom: url)
    defer { try? input.close() }
    let provider = ExecTestProvider()
    provider.stall = true
    provider.onEOF = { context in
      context.sendResponse(.with { $0.type = .exit(.with { $0.code = 23 }) }).whenSuccess {
        context.statusPromise.succeed(.ok)
      }
    }
    try await withServer(provider) { channel in
      let attempted = self.expectation(description: "first stdin write reaches HTTP/2")
      let observer = ExecWriteObserver { attempted.fulfill() }
      // Observe messages and their real transport promises without replacing the
      // gRPC/HTTP2/socket stack or acknowledging messages in the test.
      let instrumented = ExecTestChannel(base: channel, observer: observer, paused: provider.paused!.futureResult)
      let finished = self.expectation(description: "remote exit cancels stalled stdin write")
      let command = try Exec.parse(["-i", "test", "cat"])
      let task = Task {
        do {
          try await command.execute(instrumented, input: input)
          XCTFail("Expected exit status")
        } catch let error as ExecCustomExitCodeError {
          XCTAssertEqual(error.exitCode, 23)
        } catch { XCTFail("\(error)") }
        finished.fulfill()
      }
      defer { task.cancel() }
      await self.fulfillment(of: [attempted], timeout: 10)
      let snapshot = observer.snapshot()
      XCTAssertLessThanOrEqual(try input.offset(), UInt64(2 * ExecInput.chunkSize))
      XCTAssertLessThanOrEqual(snapshot.bytes, 2 * ExecInput.chunkSize + 128)
      XCTAssertEqual(snapshot.completed, 0, "The stalled peer cannot grant the remaining window")
      try await Task.sleep(for: .milliseconds(200))
      XCTAssertEqual(observer.snapshot().bytes, snapshot.bytes, "No further reads/writes while stalled")
      XCTAssertEqual(observer.snapshot().completed, 0)
      if earlyExit {
        // No read resumption: exit/trailers must win over an outstanding write's
        // failure, even when the command still has redirected stdin available.
        try await provider.exit(23)
      } else {
        try await provider.loop!.flatSubmit {
          provider.readsPaused = false
          return provider.connection!.setOption(ChannelOptions.autoRead, value: true).map {
            provider.connection!.read()
          }
        }.get()
      }
      await self.fulfillment(of: [finished], timeout: 10)
      if !earlyExit {
        let chunks = try await provider.loop!.submit {
          provider.requests.compactMap { request -> Data? in
            if case .standardInput(let chunk) = request.type { return chunk.data }
            return nil
          }
        }.get()
        XCTAssertEqual(chunks.reduce(into: Data()) { $0.append($1) }, bytes)
        XCTAssertEqual(chunks.filter(\.isEmpty).count, 1)
      }
    }
  }

  func testAsyncWriterDoesNotWaitForHTTP2FlowControl() async throws {
    // Dependency-level regression witness: the API formerly used by Exec can
    // enqueue this entire transfer while the server is not reading any stdin.
    let provider = ExecTestProvider()
    provider.stall = true
    try await withServer(provider) { channel in
      let observer = ExecWriteObserver {}
      let instrumented = ExecTestChannel(base: channel, observer: observer, paused: provider.paused!.futureResult)
      let call = AgentAsyncClient(channel: instrumented).makeExecCall()
      defer { call.cancel() }
      try await call.requestStream.send(.with { $0.type = .command(.with { $0.name = "cat" }) })
      try await provider.paused!.futureResult.get()
      let data = Data(repeating: 0xA7, count: ExecInput.chunkSize)
      for _ in 0..<256 {
        try await call.requestStream.send(.with { $0.type = .standardInput(.with { $0.data = data }) })
      }
      // Interceptors run on the call's event loop; wait until all 256 are seen.
      await self.fulfillment(of: [observer.expectBytes(16 * 1024 * 1024)], timeout: 10)
      let snapshot = observer.snapshot()
      XCTAssertEqual(snapshot.bytes, 16 * 1024 * 1024)
      XCTAssertEqual(snapshot.completed, 0)
      let received = try await provider.loop!.submit { provider.requests.count }.get()
      XCTAssertEqual(received, 1, "Only the initial command reached the service")
    }
  }

  func testPipeBytesEOFCommandAndOutputRouting() async throws {
    let provider = ExecTestProvider()
    let pipe = Pipe()
    let bytes = Data((0..<17003).map { UInt8(truncatingIfNeeded: $0) })
    // Write asynchronously: pipe capacity is platform dependent.
    let writer = Task.detached {
      try pipe.fileHandleForWriting.write(contentsOf: bytes)
      try pipe.fileHandleForWriting.close()
    }
    let outURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let errURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    FileManager.default.createFile(atPath: outURL.path, contents: nil)
    FileManager.default.createFile(atPath: errURL.path, contents: nil)
    defer {
      try? FileManager.default.removeItem(at: outURL)
      try? FileManager.default.removeItem(at: errURL)
    }
    let out = try FileHandle(forWritingTo: outURL)
    let err = try FileHandle(forWritingTo: errURL)
    defer { try? out.close(); try? err.close() }
    provider.onEOF = { context in
      context.sendResponse(.with { $0.type = .standardOutput(.with { $0.data = bytes }) }).flatMap {
        context.sendResponse(.with { $0.type = .standardError(.with { $0.data = Data("stderr".utf8) }) })
      }.flatMap {
        context.sendResponse(.with { $0.type = .exit(.with { $0.code = 7 }) })
      }.whenSuccess { context.statusPromise.succeed(.ok) }
    }
    try await withServer(provider) { channel in
      let command = try Exec.parse(["-i", "test", "cat", "arg one", "--arg"])
      do {
        try await command.execute(channel, input: pipe.fileHandleForReading, stdout: out, stderr: err)
        XCTFail("Expected exit status")
      } catch let error as ExecCustomExitCodeError { XCTAssertEqual(error.exitCode, 7) }
      let requests = try await provider.loop!.submit { provider.requests }.get()
      XCTAssertEqual(requests.first?.command.name, "cat")
      XCTAssertEqual(requests.first?.command.args, ["arg one", "--arg"])
      XCTAssertEqual(requests.first?.command.interactive, true)
      XCTAssertEqual(requests.first?.command.tty, false)
      let chunks = requests.dropFirst().compactMap { request -> Data? in
        if case .standardInput(let chunk) = request.type { return chunk.data }
        return nil
      }
      XCTAssertEqual(chunks.filter(\.isEmpty).count, 1)
      XCTAssertEqual(chunks.reduce(into: Data()) { $0.append($1) }, bytes)
    }
    try await writer.value
    XCTAssertEqual(try Data(contentsOf: outURL), bytes)
    XCTAssertEqual(try Data(contentsOf: errURL), Data("stderr".utf8))
  }

  func testEarlyExitAndNormalCompletionCancelOpenPipe() async throws {
    for explicitExit in [true, false] {
      let provider = ExecTestProvider()
      provider.onCommand = { context in
        if explicitExit {
          context.sendResponse(.with { $0.type = .exit(.with { $0.code = 31 }) }).whenSuccess {
            context.statusPromise.succeed(.ok)
          }
        } else { context.statusPromise.succeed(.ok) }
      }
      try await withServer(provider) { channel in
        let pipe = Pipe()
        let command = try Exec.parse(["-i", "test", "exit"])
        let done = self.expectation(description: "open stdin does not prevent completion")
        let task = Task {
          do {
            try await command.execute(channel, input: pipe.fileHandleForReading)
            XCTAssertFalse(explicitExit)
          } catch let error as ExecCustomExitCodeError {
            XCTAssertTrue(explicitExit)
            XCTAssertEqual(error.exitCode, 31)
          } catch { XCTFail("\(error)") }
          done.fulfill()
        }
        defer { task.cancel() }
        await self.fulfillment(of: [done], timeout: 5)
        try pipe.fileHandleForWriting.write(contentsOf: Data([1]))
      }
    }
  }

  func testOutputErrorPropagatesAndRestoresDescriptors() async throws {
    let provider = ExecTestProvider()
    provider.onCommand = { context in
      context.sendResponse(.with { $0.type = .standardOutput(.with { $0.data = Data([1]) }) }).whenSuccess {
        context.statusPromise.succeed(.ok)
      }
    }
    try await withServer(provider) { channel in
      let pipe = Pipe()
      let fd = pipe.fileHandleForReading.fileDescriptor
      let flags = execTestFileStatus(fd)
      let command = try Exec.parse(["test", "output"])
      do {
        try await command.execute(channel, stdout: pipe.fileHandleForReading)
        XCTFail("A read-only stdout must fail")
      } catch { XCTAssertTrue(error is POSIXError, "\(error)") }
      XCTAssertEqual(execTestFileStatus(fd), flags)
    }
  }

  func testSlowOutputIsBoundedAndResumesInOrder() async throws {
    try await checkSlowOutput(cancel: false)
  }

  func testCancellationWhileOutputIsBlockedRestoresAliasedFlags() async throws {
    try await checkSlowOutput(cancel: true)
  }

  private func checkSlowOutput(cancel: Bool) async throws {
    let provider = ExecTestProvider()
    let stalled = expectation(description: "output spans multiple HTTP/2 windows")
    let chunk = Data((0..<(96 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
    let chunks = 16
    provider.onCommand = { context in
      provider.sendOutput(chunk, remaining: chunks, started: stalled)
    }
    try await withServer(provider) { channel in
      let input = Pipe()
      let output = Pipe()
      let flags = execTestFileStatus(output.fileHandleForWriting.fileDescriptor)
      let command = try Exec.parse(["-i", "test", "output"])
      let done = self.expectation(description: "output command finished")
      let task = Task {
        do {
          try await command.execute(channel, input: input.fileHandleForReading,
                                    stdout: output.fileHandleForWriting, stderr: output.fileHandleForWriting)
          XCTFail("Expected exit or cancellation")
        } catch let error as ExecCustomExitCodeError {
          XCTAssertFalse(cancel)
          XCTAssertEqual(error.exitCode, 0)
        } catch { XCTAssertTrue(cancel, "\(error)") }
        done.fulfill()
      }
      defer { task.cancel() }
      await self.fulfillment(of: [stalled], timeout: 5)
      // A sustained stalled interval checks that reads do not keep replenishing
      // the HTTP/2 window while the host's pipe has no reader.
      try await Task.sleep(for: .milliseconds(200))
      let attempts = try await provider.loop!.submit { provider.outputAttempts }.get()
      XCTAssertLessThanOrEqual(attempts, 3)
      if cancel {
        task.cancel()
        await self.fulfillment(of: [done], timeout: 5)
      } else {
        let drained = self.expectation(description: "all output drained")
        let received = ExecTestBytes()
        let reader = Task.detached {
          do {
            var count = 0
            while count < chunk.count * chunks {
              guard let data = try output.fileHandleForReading.read(upToCount: 64 * 1024), !data.isEmpty else { break }
              count += data.count
              _ = received.append(data)
            }
          } catch { XCTFail("\(error)") }
          drained.fulfill()
        }
        defer { reader.cancel() }
        await self.fulfillment(of: [done, drained], timeout: 10)
        XCTAssertEqual(received.data, (0..<chunks).reduce(into: Data()) { data, _ in data.append(chunk) })
      }
      XCTAssertEqual(execTestFileStatus(output.fileHandleForWriting.fileDescriptor), flags)
    }
  }

  func testTerminalOptionsAndResizeWithOpenStdin() async throws {
    let previous = signal(SIGWINCH, SIG_IGN)
    defer { signal(SIGWINCH, previous) }
    let provider = ExecTestProvider()
    let inputReceived = expectation(description: "stdin running after resize source is installed")
    let resized = expectation(description: "resize received")
    provider.onInput = { _ in inputReceived.fulfill() }
    provider.onResize = { size in
      XCTAssertEqual(size.cols, 80)
      XCTAssertEqual(size.rows, 24)
      resized.fulfill()
    }
    try await withServer(provider) { channel in
      let (master, slave) = try makeExecTestPTY()
      let flags = execTestFileStatus(slave.fileDescriptor)
      let command = try Exec.parse(["-i", "-t", "test", "sh"])
      let done = self.expectation(description: "PTY command exited")
      let task = Task {
        do {
          try await command.execute(channel, input: slave, stdout: slave, stderr: slave, terminalSize: { (80, 24) })
          XCTFail("Expected exit")
        } catch let error as ExecCustomExitCodeError { XCTAssertEqual(error.exitCode, 0) }
        catch { XCTFail("\(error)") }
        done.fulfill()
      }
      defer { task.cancel() }
      try master.write(contentsOf: Data([1]))
      await self.fulfillment(of: [inputReceived], timeout: 5)
      XCTAssertEqual(kill(getpid(), SIGWINCH), 0)
      await self.fulfillment(of: [resized], timeout: 5)
      let initial = try await provider.loop!.submit { provider.requests.first!.command }.get()
      XCTAssertTrue(initial.tty)
      XCTAssertTrue(initial.interactive)
      XCTAssertEqual(initial.terminalSize.cols, 80)
      XCTAssertEqual(initial.terminalSize.rows, 24)
      try await provider.exit(0)
      await self.fulfillment(of: [done], timeout: 5)
      XCTAssertEqual(execTestFileStatus(slave.fileDescriptor), flags)
    }
  }

  func testCancellationAndRemoteFailureWithIdleStdin() async throws {
    for cancel in [true, false] {
      let provider = ExecTestProvider()
      let started = expectation(description: "command received")
      provider.onCommand = { _ in started.fulfill() }
      try await withServer(provider) { channel in
        let pipe = Pipe()
        let command = try Exec.parse(["-i", "test", "sleep"])
        let done = self.expectation(description: "terminated")
        let task = Task {
          do {
            try await command.execute(channel, input: pipe.fileHandleForReading)
            XCTFail("Expected failure")
          } catch {
            if !cancel { XCTAssertEqual((error as? GRPCStatus)?.code, .unavailable) }
          }
          done.fulfill()
        }
        await self.fulfillment(of: [started], timeout: 5)
        if cancel { task.cancel() } else {
          try await provider.loop!.submit {
            provider.context!.statusPromise.succeed(GRPCStatus(code: .unavailable))
          }.get()
        }
        await self.fulfillment(of: [done], timeout: 5)
        task.cancel()
      }
    }
  }

  private func withServer(
    _ provider: ExecTestProvider,
    body: (GRPCChannel) async throws -> Void
  ) async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    provider.loop = group.next()
    provider.paused = provider.stall ? provider.loop!.makePromise() : nil
    var server: Server? = try await Server.insecure(group: group)
      .withServiceProviders([provider])
      .withHTTPTargetWindowSize(65535)
      .withDebugChannelInitializer { channel in
        provider.connection = channel
        return channel.pipeline.addHandler(ExecPauseObserver(provider: provider), position: .first)
      }
      .bind(host: "127.0.0.1", port: 0).get()
    let channel = try GRPCChannelPool.with(
      target: .host("127.0.0.1", port: server!.channel.localAddress!.port!),
      transportSecurity: .plaintext,
      eventLoopGroup: MultiThreadedEventLoopGroup.singleton
    ) { $0.http2.targetWindowSize = 65535 }
    do {
      try await body(channel)
      try await channel.close().get()
      let peer = try await provider.loop!.submit { provider.connection }.get()
      if let peer { try? await peer.close().get() }
      try await server!.close().get()
      server = nil
      try await group.shutdownGracefully()
    } catch {
      try? await channel.close().get()
      let peer = try? await provider.loop!.submit { provider.connection }.get()
      if let peer { try? await peer.close().get() }
      try? await server!.close().get()
      server = nil
      try? await group.shutdownGracefully()
      throw error
    }
  }
}

private final class ExecTestProvider: AgentProvider, @unchecked Sendable {
  var interceptors: AgentServerInterceptorFactoryProtocol? { nil }
  var loop: EventLoop?
  var connection: Channel?
  var context: StreamingResponseCallContext<ExecResponse>?
  var requests: [ExecRequest] = []
  var stall = false
  var paused: EventLoopPromise<Void>?
  var pauseRequested = false
  var readsPaused = false
  var outputAttempts = 0
  var onCommand: ((StreamingResponseCallContext<ExecResponse>) -> Void)?
  var onInput: ((Data) -> Void)?
  var onResize: ((TerminalSize) -> Void)?
  var onEOF: ((StreamingResponseCallContext<ExecResponse>) -> Void)?

  func exec(context: StreamingResponseCallContext<ExecResponse>) -> EventLoopFuture<(StreamEvent<ExecRequest>) -> Void> {
    self.context = context
    return context.eventLoop.makeSucceededFuture { event in
      guard case .message(let request) = event else { return }
      self.requests.append(request)
      switch request.type {
      case .command:
        if self.stall {
          self.pauseRequested = true
          self.readsPaused = true
          self.connection!.setOption(ChannelOptions.autoRead, value: false).whenFailure { XCTFail("\($0)") }
        }
        self.onCommand?(context)
      case .standardInput(let chunk):
        if chunk.data.isEmpty { self.onEOF?(context) } else { self.onInput?(chunk.data) }
      case .terminalResize(let size):
        self.onResize?(size)
      default: break
      }
    }
  }

  func sendOutput(_ data: Data, remaining: Int, started: XCTestExpectation) {
    guard remaining > 0 else {
      context!.sendResponse(.with { $0.type = .exit(.with { $0.code = 0 }) }).whenSuccess {
        self.context!.statusPromise.succeed(.ok)
      }
      return
    }
    outputAttempts += 1
    if outputAttempts == 2 { started.fulfill() }
    context!.sendResponse(.with { $0.type = .standardOutput(.with { $0.data = data }) }).whenSuccess {
      self.sendOutput(data, remaining: remaining - 1, started: started)
    }
  }

  func exit(_ code: Int32) async throws {
    try await loop!.flatSubmit {
      self.context!.sendResponse(.with { $0.type = .exit(.with { $0.code = code }) }).map {
        self.context!.statusPromise.succeed(.ok)
      }
    }.get()
  }

  func resolveIP(request: ResolveIPRequest, context: StatusOnlyCallContext) -> EventLoopFuture<ResolveIPResponse> {
    context.eventLoop.makeFailedFuture(GRPCStatus(code: .unimplemented))
  }
}

private final class ExecPauseObserver: ChannelDuplexHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer
  typealias OutboundIn = ByteBuffer
  let provider: ExecTestProvider

  init(provider: ExecTestProvider) { self.provider = provider }

  // Disabling autoRead alone does not stall HTTP/2: a child stream may still
  // request an explicit parent read. Hold those requests too until resumed.
  func read(context: ChannelHandlerContext) {
    if !provider.readsPaused { context.read() }
  }

  func channelReadComplete(context: ChannelHandlerContext) {
    context.fireChannelReadComplete()
    if provider.pauseRequested {
      provider.pauseRequested = false
      provider.paused!.succeed(())
    }
  }
}

private final class ExecWriteObserver: @unchecked Sendable {
  private let lock = NSLock()
  private var bytes = 0
  private var completed = 0
  private var notified = false
  private var byteExpectation: (Int, XCTestExpectation)?
  let onFirstWrite: () -> Void

  init(onFirstWrite: @escaping () -> Void) { self.onFirstWrite = onFirstWrite }

  func sent(_ data: Data, promise: EventLoopPromise<Void>?) {
    lock.lock()
    bytes += data.count
    let notify = !notified
    notified = true
    if let (target, expectation) = byteExpectation, bytes >= target {
      byteExpectation = nil
      expectation.fulfill()
    }
    lock.unlock()
    promise?.futureResult.whenSuccess {
      self.lock.lock()
      self.completed += 1
      self.lock.unlock()
    }
    if notify { onFirstWrite() }
  }

  func expectBytes(_ target: Int) -> XCTestExpectation {
    lock.lock()
    defer { lock.unlock() }
    let expectation = XCTestExpectation(description: "all bytes enqueued")
    if bytes >= target { expectation.fulfill() } else { byteExpectation = (target, expectation) }
    return expectation
  }

  func snapshot() -> (bytes: Int, completed: Int) {
    lock.lock()
    defer { lock.unlock() }
    return (bytes, completed)
  }
}

private final class ExecObserveInterceptor<Request, Response>: ClientInterceptor<Request, Response>, @unchecked Sendable {
  let observer: ExecWriteObserver
  let paused: EventLoopFuture<Void>

  init(observer: ExecWriteObserver, paused: EventLoopFuture<Void>) {
    self.observer = observer
    self.paused = paused
  }

  override func send(
    _ part: GRPCClientRequestPart<Request>,
    promise: EventLoopPromise<Void>?,
    context: ClientInterceptorContext<Request, Response>
  ) {
    if case .message(let message, _) = part, let request = message as? ExecRequest {
      switch request.type {
      case .command:
        // The command write is complete only after the test server finishes its
        // current read cycle and disables further TCP reads. No timing sleeps.
        let written = context.eventLoop.makePromise(of: Void.self)
        context.send(part, promise: written)
        if let promise {
          written.futureResult.and(paused.hop(to: context.eventLoop)).map { _ in () }.cascade(to: promise)
        }
        return
      case .standardInput(let chunk):
        context.send(part, promise: promise)
        observer.sent(chunk.data, promise: promise)
        return
      default: break
      }
    }
    context.send(part, promise: promise)
  }
}

private final class ExecTestChannel: GRPCChannel, @unchecked Sendable {
  let base: GRPCChannel
  let observer: ExecWriteObserver
  let paused: EventLoopFuture<Void>

  init(base: GRPCChannel, observer: ExecWriteObserver, paused: EventLoopFuture<Void>) {
    self.base = base
    self.observer = observer
    self.paused = paused
  }

  func makeCall<Request: SwiftProtobuf.Message, Response: SwiftProtobuf.Message>(
    path: String, type: GRPCCallType, callOptions: CallOptions,
    interceptors: [ClientInterceptor<Request, Response>]
  ) -> Call<Request, Response> {
    base.makeCall(path: path, type: type, callOptions: callOptions,
                  interceptors: interceptors + [ExecObserveInterceptor(observer: observer, paused: paused)])
  }

  func makeCall<Request: GRPCPayload, Response: GRPCPayload>(
    path: String, type: GRPCCallType, callOptions: CallOptions,
    interceptors: [ClientInterceptor<Request, Response>]
  ) -> Call<Request, Response> {
    base.makeCall(path: path, type: type, callOptions: callOptions, interceptors: interceptors)
  }

  func close() -> EventLoopFuture<Void> { base.close() }
}
