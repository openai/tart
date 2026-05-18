import Foundation
import NIOPosix
import GRPC
import Cirruslabs_TartGuestAgent_Apple_Swift
import Cirruslabs_TartGuestAgent_Grpc_Swift

struct GuestDropOutcome {
  /// Basename of the folder the file was moved into, e.g. "Desktop" or
  /// "Documents". The host shows this in the toast so the user knows where
  /// the dropped file ended up.
  let destinationFolderName: String
}

/// Errors that the host treats as "agent path didn't work; fall back to
/// share-folder behavior." We intentionally swallow these in the caller so
/// the existing share-folder copy remains the visible result.
enum GuestDropError: Error {
  case agentUnreachable
  case execFailed(exitCode: Int32, stderr: String)
  case unexpectedOutput(String)
  case timedOut
}

/// Asks the in-guest tart-guest-agent to relocate `guestFilePath` from the
/// "Dropped Files" share into a user-visible location, then reveal it in
/// Finder. The result is that a drag-and-drop drop appears either in the
/// folder of the user's frontmost Finder window — matching the intuition
/// "I dragged it here, it's here now" — or on the Desktop as a fallback.
///
/// Under the hood we run a single `/bin/sh -c` script in the guest via the
/// agent's Exec RPC. The script uses `osascript` to query Finder for the
/// frontmost window's POSIX path; this runs in the agent's user-GUI session
/// (the `--run-agent` invocation), so the first drop will produce a TCC
/// Automation→Finder prompt in the guest that the user must approve once.
/// If Finder has no window open, isn't responding, or returns the same
/// folder the file is already in (e.g. the user is staring at "Dropped
/// Files"), we fall back to `~/Desktop`. The file is finally revealed with
/// `open -R` so Finder pops a window with it selected.
enum GuestDropSynthesis {
  /// Shell script body executed inside the guest. The dropped file's guest
  /// path is passed as `$1` via the `sh -c CMD -- $1` convention (with
  /// `tartdrop` as `$0` so error messages identify us).
  ///
  /// Exit codes: 0 on success, non-zero on failure (caller treats any
  /// non-zero as "fall back to the share-folder copy that's already on disk").
  private static let relocateAndRevealScript = #"""
    set -e
    src=$1
    if [ -z "$src" ] || [ ! -e "$src" ]; then
      echo "tartdrop: missing or nonexistent source: $src" >&2
      exit 2
    fi
    name=$(basename "$src")
    src_dir=$(dirname "$src")

    # Ask Finder for the frontmost window's folder. Suppress stderr so a TCC
    # denial or "no windows" error doesn't pollute the agent log; we detect
    # those by an empty result. The agent runs in the user's GUI session, so
    # osascript here goes through the user's TCC consent (Automation→Finder).
    dest_dir=$(/usr/bin/osascript <<'OSA' 2>/dev/null || true
    tell application "Finder"
      if (count of Finder windows) is 0 then return ""
      try
        return POSIX path of (target of front Finder window as alias)
      on error
        return ""
      end try
    end tell
    OSA
    )
    # AppleScript appends a trailing slash to folder POSIX paths.
    dest_dir=${dest_dir%/}

    # Reject empty / nonexistent / non-writable destinations, and reject the
    # source's own parent (which would either be a no-op rename or leave us
    # putting the file right back into "Dropped Files").
    if [ -z "$dest_dir" ] || [ ! -d "$dest_dir" ] || [ ! -w "$dest_dir" ] || [ "$dest_dir" = "$src_dir" ]; then
      dest_dir=$HOME/Desktop
    fi

    # Pick a non-clobbering filename: "foo.txt" → "foo 2.txt", "foo 3.txt"…
    final=$dest_dir/$name
    if [ -e "$final" ]; then
      stem=${name%.*}
      ext=${name##*.}
      if [ "$stem" = "$name" ]; then
        i=2
        while [ -e "$dest_dir/$name $i" ]; do i=$((i+1)); done
        final="$dest_dir/$name $i"
      else
        i=2
        while [ -e "$dest_dir/$stem $i.$ext" ]; do i=$((i+1)); done
        final="$dest_dir/$stem $i.$ext"
      fi
    fi

    mv -- "$src" "$final"
    /usr/bin/open -R "$final"
    # Last line of stdout is the destination folder's basename so the host
    # can show "Copied to Desktop" / "Copied to Documents" in the toast.
    printf 'tartdrop-dest=%s\n' "$(basename "$dest_dir")"
    """#

  static func perform(
    controlSocketURL: URL,
    guestFilePath: String
  ) async throws -> GuestDropOutcome {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { try? group.syncShutdownGracefully() }

    // Work around the 104-byte UDS path limit by chdir'ing to the socket's
    // parent directory and connecting via the relative name (same trick as
    // Exec.swift). Restore cwd afterwards so we don't surprise the rest of
    // the host process.
    let originalCWD = FileManager.default.currentDirectoryPath
    if let baseURL = controlSocketURL.baseURL {
      FileManager.default.changeCurrentDirectoryPath(baseURL.path())
    }
    defer { FileManager.default.changeCurrentDirectoryPath(originalCWD) }

    let channel: GRPCChannel
    do {
      channel = try GRPCChannelPool.with(
        target: .unixDomainSocket(controlSocketURL.relativePath),
        transportSecurity: .plaintext,
        eventLoopGroup: group
      )
    } catch {
      throw GuestDropError.agentUnreachable
    }
    defer { try? channel.close().wait() }

    // 5 s: enough headroom for a first-run osascript that's blocked on a
    // user TCC Automation prompt inside the guest, while still failing fast
    // when the agent isn't running so the toast can show "Copied to Shared
    // Files" before hiding. Steady-state calls finish in well under 500 ms.
    let callOptions = CallOptions(timeLimit: .timeout(.seconds(5)))
    let client = AgentAsyncClient(channel: channel, defaultCallOptions: callOptions)
    let execCall = client.makeExecCall()

    // Pass the guest path as $1 (with "tartdrop" as $0 so error messages
    // identify us). The script does the Finder-window lookup, picks a
    // destination, moves the file out of "Dropped Files", and reveals it.
    let command = ExecRequest.with {
      $0.type = .command(ExecRequest.Command.with {
        $0.name = "/bin/sh"
        $0.args = ["-c", relocateAndRevealScript, "tartdrop", guestFilePath]
        $0.interactive = false
        $0.tty = false
      })
    }

    do {
      try await execCall.requestStream.send(command)
      execCall.requestStream.finish()
    } catch let error as GRPCConnectionPoolError {
      _ = error
      throw GuestDropError.agentUnreachable
    }

    var stdout = ""
    var stderr = ""
    var exitCode: Int32 = -1

    do {
      for try await response in execCall.responseStream {
        switch response.type {
        case .standardOutput(let chunk):
          stdout += String(data: chunk.data, encoding: .utf8) ?? ""
        case .standardError(let chunk):
          stderr += String(data: chunk.data, encoding: .utf8) ?? ""
        case .exit(let exit):
          exitCode = exit.code
        default:
          continue
        }
      }
    } catch let error as GRPCStatus {
      if error.code == .deadlineExceeded {
        throw GuestDropError.timedOut
      }
      throw GuestDropError.execFailed(exitCode: -1, stderr: error.localizedDescription)
    }

    if exitCode != 0 {
      throw GuestDropError.execFailed(exitCode: exitCode, stderr: stderr)
    }

    // Parse the `tartdrop-dest=<basename>` line the script prints after `mv`.
    // Tolerate other stdout (a future agent build might add a banner) by
    // scanning lines instead of demanding an exact match.
    var folderName: String?
    for line in stdout.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
      if line.hasPrefix("tartdrop-dest=") {
        folderName = String(line.dropFirst("tartdrop-dest=".count))
      }
    }
    guard let dest = folderName, !dest.isEmpty else {
      throw GuestDropError.unexpectedOutput(stdout)
    }
    return GuestDropOutcome(destinationFolderName: dest)
  }
}
