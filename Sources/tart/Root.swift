import ArgumentParser
import Darwin
import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import OpenTelemetryProtocolExporterHttp

@main
struct Root: AsyncParsableCommand {
  static var configuration = CommandConfiguration(
    commandName: "tart",
    version: CI.version,
    subcommands: [
      Create.self,
      Clone.self,
      Run.self,
      Set.self,
      Get.self,
      List.self,
      Login.self,
      Logout.self,
      IP.self,
      Exec.self,
      Pull.self,
      Push.self,
      Import.self,
      Export.self,
      Prune.self,
      Rename.self,
      Stop.self,
      Delete.self,
      FQN.self,
    ])

  // Note: main() is intentionally synchronous. Swift's asynchronous main() entry
  // point implicitly starts an executor that owns the main thread — and since
  // Swift 6.4 that executor is no longer backed by the Dispatch main queue — so
  // running an AppKit/SwiftUI run loop nested inside it leaves the main run loop
  // unable to drain Tasks or DispatchQueue.main, and a VM started via "tart run"
  // never boots. Keeping main() synchronous lets a command that needs the main
  // run loop own it at the top level, exactly like a plain SwiftUI app.
  public static func main() {
    // Add commands that are only available on specific macOS versions
    if #available(macOS 14, *) {
      configuration.subcommands.append(Suspend.self)
    }

    // Ensure the default SIGINT handler is disabled, otherwise there's a race
    // between two handlers. We handle cancellation by Ctrl+C ourselves below.
    signal(SIGINT, SIG_IGN)

    // Set line-buffered output for stdout
    setlinebuf(stdout)

    // Parse the command up-front, synchronously, so we can decide who gets to own
    // the main thread before any concurrency is involved.
    //
    // ParsableCommand isn't Sendable, but we only ever hand it to the single task
    // spawned below and never touch it again afterwards, so transferring it into
    // that task is safe.
    nonisolated(unsafe) let command: ParsableCommand
    do {
      command = try parseAsRoot()
    } catch {
      exit(withError: error)
    }

    if let mainThreadCommand = command as? MainThreadCommand {
      // This command drives a run loop on the main thread, so run it right here,
      // letting it own the main thread at the top level.
      MainActor.assumeIsolated {
        runOnMainThread(mainThreadCommand)
      }
    } else {
      // Every other command is asynchronous and doesn't touch the main thread, so
      // drive it from a detached task and let the Dispatch main queue keep the
      // process alive until the command exits.
      let task = Task.detached {
        await runInBackground(command)
      }

      // Handle cancellation by Ctrl+C ourselves
      let sigintSrc = DispatchSource.makeSignalSource(signal: SIGINT)
      sigintSrc.setEventHandler {
        task.cancel()
      }
      sigintSrc.activate()

      dispatchMain()
    }
  }

  @MainActor
  private static func runOnMainThread(_ command: MainThreadCommand) {
    let span = startCommandSpan(for: command)
    runGarbageCollection(for: command)

    do {
      // Enters the run loop and only returns once the command exits via
      // Foundation.exit(), so the lines below are a best-effort fallback.
      try command.runOnMainThread()
    } catch {
      handleError(error, span: span)
    }

    span.end()
    OTel.shared.flush()
    Foundation.exit(0)
  }

  private static func runInBackground(_ command: ParsableCommand) async {
    let span = startCommandSpan(for: command)
    runGarbageCollection(for: command)

    do {
      if var asyncCommand = command as? AsyncParsableCommand {
        try await asyncCommand.run()
      } else {
        var command = command
        try command.run()
      }
    } catch {
      handleError(error, span: span)
    }

    span.end()
    OTel.shared.flush()
    Foundation.exit(0)
  }

  // Create a root span for the command we're about to run.
  private static func startCommandSpan(for command: ParsableCommand) -> Span {
    let span = OTel.shared.tracer.spanBuilder(spanName: type(of: command)._commandName).startSpan()
    OpenTelemetry.instance.contextProvider.setActiveSpan(span)

    // Enrich root command span with command's arguments
    let commandLineArguments = ProcessInfo.processInfo.arguments.map { argument in
      AttributeValue.string(argument)
    }
    span.setAttribute(key: "Command-line arguments", value: .array(AttributeArray(values: commandLineArguments)))

    // Enrich root command span with Cirrus CI-specific tags
    if let tags = ProcessInfo.processInfo.environment["CIRRUS_SENTRY_TAGS"] {
      for (key, value) in tags.split(separator: ",").compactMap(splitEnvironmentVariable) {
        span.setAttribute(key: key, value: .string(value))
      }
    }

    return span
  }

  // Run garbage-collection before each command (shouldn't take too long).
  private static func runGarbageCollection(for command: ParsableCommand) {
    if type(of: command) != type(of: Pull()) && type(of: command) != type(of: Clone()) {
      do {
        try Config().gc()
      } catch {
        fputs("Failed to perform garbage collection: \(error)\n", stderr)
      }
    }
  }

  private static func handleError(_ error: Error, span: Span) -> Never {
    // Not an error, just a custom exit code from "tart exec"
    if let execCustomExitCodeError = error as? ExecCustomExitCodeError {
      span.end()
      OTel.shared.flush()
      Foundation.exit(execCustomExitCodeError.exitCode)
    }

    // Capture the error into OpenTelemetry
    OpenTelemetry.instance.contextProvider.activeSpan?.recordException(error)
    span.end()

    // Handle a non-ArgumentParser's exception that requires a specific exit code to be set
    if let errorWithExitCode = error as? HasExitCode {
      fputs("\(error)\n", stderr)

      OTel.shared.flush()
      Foundation.exit(errorWithExitCode.exitCode)
    }

    // Handle any other exception, including ArgumentParser's ones
    OTel.shared.flush()
    exit(withError: error)
  }

  private static func splitEnvironmentVariable(_ tag: String.SubSequence) -> (String, String)? {
    let splits = tag.split(separator: "=", maxSplits: 1)
    if splits.count != 2 {
      return nil
    }

    return (String(splits[0]), String(splits[1]))
  }
}

// A command that drives an AppKit/SwiftUI run loop and therefore has to own the
// main thread at the top level, rather than running inside Swift's asynchronous
// main() executor. See Root.main() for the rationale.
protocol MainThreadCommand: ParsableCommand {
  @MainActor func runOnMainThread() throws
}
