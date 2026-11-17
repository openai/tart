import ArgumentParser
import Foundation
import GRPC
import NIOPosix
import Cirruslabs_TartGuestAgent_Grpc_Swift

struct ExecCustomExitCodeError: Error {
  let exitCode: Int32
}

struct Exec: AsyncParsableCommand {
  static var configuration = CommandConfiguration(abstract: "Execute a command in a running VM", discussion: """
  Requires Tart Guest Agent running in a guest VM.

  Note that all non-vanilla Cirrus Labs VM images already have the Tart Guest Agent installed.
  """)

  @Flag(name: [.customShort("i")], help: "Attach host's standard input to a remote command")
  var interactive: Bool = false

  @Flag(name: [.customShort("t")], help: "Allocate a remote pseudo-terminal (PTY)")
  var tty: Bool = false

  @Argument(help: "VM name", completion: .custom(completeLocalMachines))
  var name: String

  @Argument(parsing: .captureForPassthrough, help: "Command to execute")
  var command: [String]

  func run() async throws {
    // We only have withThrowingDiscardingTaskGroup available starting from macOS 14
    if #unavailable(macOS 14) {
      throw RuntimeError.Generic("\"tart exec\" is only available on macOS 14 (Sonoma) or newer")
    }

    // Open VM's directory
    let vmDir = try VMStorageLocal().open(name)

    // Ensure that the VM is running
    if try !vmDir.running() {
      throw RuntimeError.VMNotRunning(name)
    }

    // Change the current working directory to a VM's base directory
    // to work around Unix domain socket 104 byte limitation [1]
    //
    // [1]: https://blog.8-p.info/en/2020/06/11/unix-domain-socket-length/
    if let baseURL = vmDir.controlSocketURL.baseURL {
      FileManager.default.changeCurrentDirectoryPath(baseURL.absoluteURL.path(percentEncoded: false))
    }

    // Switch controlling terminal into raw mode when remote pseudo-terminal is requested
    var state: State? = nil

    if tty && Term.IsTerminal() {
      state = try Term.MakeRaw()
    }
    defer {
      // Restore terminal to its initial state
      if let state {
        try! Term.Restore(state)
      }
    }

    // Execute a command in a running VM
    do {
      let controlSocketPath = vmDir.controlSocketURL.relativePath
      try await withGuestAgentChannel(unixDomainSocketPath: controlSocketPath) { channel in
        try await execute(channel)
      }
    } catch let error as GRPCConnectionPoolError {
      throw RuntimeError.Generic("Failed to connect to the VM using its control socket: \(error.localizedDescription), is the Tart Guest Agent running?")
    }
  }

  // File handles are parameters so the protocol can be exercised without a VM or
  // replacing the process's standard descriptors.
  func execute(
    _ channel: GRPCChannel,
    input: FileHandle = .standardInput,
    stdout: FileHandle = .standardOutput,
    stderr: FileHandle = .standardError,
    terminalSize: @escaping () throws -> (width: UInt16, height: UInt16) = Term.GetSize
  ) async throws {
    let eventLoop = MultiThreadedEventLoopGroup.singleton.next()
    let io = try ExecIO(fileDescriptors: [stdout.fileDescriptor, stderr.fileDescriptor] +
      (interactive ? [input.fileDescriptor] : []))
    let output = ExecOutput(eventLoop: eventLoop, stdout: io.channels[0], stderr: io.channels[1])
    let execCall = AgentNIOClient(channel: channel).exec(
      callOptions: CallOptions(eventLoopPreference: .exact(eventLoop)),
      handler: output.receive
    )
    execCall.status.whenComplete { result in
      output.end(result.flatMap { status in
        status.isOk ? .success(()) : .failure(status)
      })
    }

    do {
      try await withTaskCancellationHandler {
        defer {
          execCall.cancel(promise: nil)
          output.cancel()
        }
        try Task.checkCancellation()
        let subchannel = try await execCall.subchannel.get()
        try await output.configure(subchannel)

        let initialSize = try tty ? terminalSize() : nil
        try await execCall.sendMessage(.with {
          $0.type = .command(.with {
            $0.name = command[0]
            $0.args = Array(command.dropFirst(1))
            $0.interactive = interactive
            $0.tty = tty
            if let initialSize {
              $0.terminalSize = .with {
                $0.cols = UInt32(initialSize.width)
                $0.rows = UInt32(initialSize.height)
              }
            }
          })
        }).get()

        let stdin = interactive ? ExecInput(io: io.channels[2]) : nil
        defer { stdin?.cancel() }
        let resize = tty ? ExecResize(size: terminalSize) { width, height in
          execCall.sendMessage(.with {
            $0.type = .terminalResize(.with {
              $0.cols = UInt32(width)
              $0.rows = UInt32(height)
            })
          })
        } onError: { error in
          output.end(.failure(error))
        } : nil
        defer { resize?.cancel() }

        try await withThrowingTaskGroup(of: Bool.self) { group in
          if let stdin {
            group.addTask {
              do {
                try await sendExecInput(stdin) { data in
                  // Unlike grpc-swift 1.x's async writer, this future follows the
                  // write through HTTP/2 flow control and the socket write buffer.
                  try await execCall.sendMessage(.with {
                    $0.type = .standardInput(.with { $0.data = data })
                  }).get()
                }
              } catch {
                // Resolve errors on the response path so an exit already received
                // wins over the failure of an outstanding write on the closed RPC.
                output.end(.failure(error))
              }
              return false
            }
          }
          group.addTask {
            try await output.completion.futureResult.get()
            return true
          }
          defer {
            group.cancelAll()
            stdin?.cancel()
            execCall.cancel(promise: nil)
            output.cancel()
          }
          // Stdin EOF must not end the response reader. Conversely, normal RPC
          // completion must cancel idle stdin just as an explicit exit event does.
          while let responsesEnded = try await group.next() {
            if responsesEnded { break }
          }
        }
      } onCancel: {
        execCall.cancel(promise: nil)
        output.cancel()
      }
    } catch {
      await io.close()
      throw error
    }
    await io.close()
  }
}
