import ArgumentParser
import Foundation
import GRPC
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
      FileManager.default.changeCurrentDirectoryPath(baseURL.path())
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

  private func execute(_ channel: GRPCChannel) async throws {
    let agentAsyncClient = AgentAsyncClient(channel: channel)
    let execCall = agentAsyncClient.makeExecCall()

    try await execCall.requestStream.send(.with {
      $0.type = .command(.with {
        $0.name = command[0]
        $0.args = Array(command.dropFirst(1))
        $0.interactive = interactive
        $0.tty = tty
        if tty {
          $0.terminalSize = .with {
            let (width, height) = try! Term.GetSize()

            $0.cols = UInt32(width)
            $0.rows = UInt32(height)
          }
        }
      })
    })

    // Process command events and optionally send our standard input and/or terminal dimensions
    try await withThrowingTaskGroup { group in
      // Stream host's standard input if interactive mode is enabled
      if interactive {
        let stdinStream = AsyncThrowingStream<Data, Error> { continuation in
          let handle = FileHandle.standardInput

          if isRegularFile(handle.fileDescriptor) {
            // Standard input can be a regular file when input redirection (<) is used,
            // in which case the handle won't receive any new readability events, so we
            // just read the file normally here in chunks and consider done with it
            //
            // Ideally this is best handled by using non-blocking I/O, but Swift's
            // standard library only offers inefficient bytes[1] property and SwiftNIO's
            // NIOFileSystem doesn't seem to support opening raw file descriptors.
            //
            // [1]: https://developer.apple.com/documentation/foundation/filehandle/bytes
            while true {
              do {
                let data = try handle.read(upToCount: 64 * 1024)
                if let data = data {
                  continuation.yield(data)
                } else {
                  continuation.finish()
                  break
                }
              } catch (let error) {
                continuation.finish(throwing: error)
                break
              }
            }
          } else {
            handle.readabilityHandler = { handle in
              let data = handle.availableData

              if data.isEmpty {
                continuation.finish()
              } else {
                continuation.yield(data)
              }
            }
          }
        }

        group.addTask {
          for try await stdinData in stdinStream {
            try await execCall.requestStream.send(.with {
              $0.type = .standardInput(.with {
                $0.data = stdinData
              })
            })
          }

          // Signal EOF as we're done reading standard input
          try await execCall.requestStream.send(.with {
            $0.type = .standardInput(.with {
              $0.data = Data()
            })
          })
        }
      }

      // Stream host's terminal dimensions if pseudo-terminal is requested
      signal(SIGWINCH, SIG_IGN)
      let sigwinchSrc = DispatchSource.makeSignalSource(signal: SIGWINCH)
      sigwinchSrc.activate()

      if tty {
        let terminalDimensionsStream = AsyncStream { continuation in
          sigwinchSrc.setEventHandler {
            continuation.yield(try! Term.GetSize())
          }
        }

        group.addTask {
          for await (width, height) in terminalDimensionsStream {
            try await execCall.requestStream.send(.with {
              $0.type = .terminalResize(.with {
                $0.cols = UInt32(width)
                $0.rows = UInt32(height)
              })
            })
          }
        }
      }

      // Process command events
      group.addTask {
        for try await response in execCall.responseStream {
          switch response.type {
          case .standardOutput(let ioChunk):
            try FileHandle.standardOutput.write(contentsOf: ioChunk.data)
          case .standardError(let ioChunk):
            try FileHandle.standardError.write(contentsOf: ioChunk.data)
          case .exit(let exit):
            throw ExecCustomExitCodeError(exitCode: exit.code)
          default:
            // Unknown event, do nothing
            continue
          }
        }
      }

      while !group.isEmpty {
        do {
          try await group.next()
        } catch {
          group.cancelAll()

          throw error
        }
      }
    }
  }
}

private func isRegularFile(_ fileDescriptor: Int32) -> Bool {
  var stat = stat()

  if fstat(fileDescriptor, &stat) != 0 {
    return false
  }

  return (stat.st_mode & S_IFMT) == S_IFREG
}
