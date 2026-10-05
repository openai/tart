import Foundation
import Network
import Virtualization

struct ARPCommandFailedError: Error, CustomStringConvertible {
  var terminationReason: Process.TerminationReason
  var terminationStatus: Int32

  var description: String {
    var reason: String

    switch terminationReason {
    case .exit:
      reason = "exit code \(terminationStatus)"
    case .uncaughtSignal:
      reason = "uncaught signal"
    default:
      reason = "unknown reason"
    }

    return "arp command failed: \(reason)"
  }
}

struct ARPCommandYieldedInvalidOutputError: Error, CustomStringConvertible {
  var explanation: String

  var description: String {
    "arp command yielded invalid output: \(explanation)"
  }
}

struct ARPCacheInternalError: Error, CustomStringConvertible {
  var explanation: String

  var description: String {
    "ARPCache internal error: \(explanation)"
  }
}

struct ARPCache {
  let arpCommandOutput: Data

  init(arpCommandURL: URL = URL(fileURLWithPath: "/usr/sbin/arp")) throws {
    let process = Process.init()
    process.executableURL = arpCommandURL
    process.arguments = ["-an"]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    process.standardInput = FileHandle.nullDevice

    try process.run()

    let arpCommandOutput = try pipe.fileHandleForReading.readToEnd() ?? Data()

    process.waitUntilExit()

    if !(process.terminationReason == .exit && process.terminationStatus == 0) {
      throw ARPCommandFailedError(
        terminationReason: process.terminationReason,
        terminationStatus: process.terminationStatus)
    }

    self.arpCommandOutput = arpCommandOutput
  }

  func ResolveMACAddress(macAddress: MACAddress) throws -> IPv4Address? {
    let output = String(decoding: arpCommandOutput, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if output.isEmpty {
      return nil
    }
    let lines = output.components(separatedBy: "\n")

    // Based on https://opensource.apple.com/source/network_cmds/network_cmds-606.40.2/arp.tproj/arp.c.auto.html
    let regex = try NSRegularExpression(pattern: #"^.* \((?<ip>.*)\) at (?<mac>.*) on (?<interface>.*) .*$"#)

    for line in lines {
      let nsLineRange = NSRange(line.startIndex..<line.endIndex, in: line)

      guard let match = regex.firstMatch(in: line, range: nsLineRange) else {
        throw ARPCommandYieldedInvalidOutputError(explanation: "unparseable entry \"\(line)\"")
      }

      let rawIP = try match.getCaptureGroup(name: "ip", for: line)
      guard let ip = IPv4Address(rawIP) else {
        throw ARPCommandYieldedInvalidOutputError(explanation: "failed to parse IPv4 address \(rawIP)")
      }

      let rawMAC = try match.getCaptureGroup(name: "mac", for: line)
      if rawMAC == "(incomplete)" {
        continue
      }
      guard let mac = MACAddress(fromString: rawMAC) else {
        throw ARPCommandYieldedInvalidOutputError(explanation: "failed to parse MAC address \(rawMAC)")
      }

      if macAddress == mac {
        return ip
      }
    }

    return nil
  }
}

extension NSTextCheckingResult {
  func getCaptureGroup(name: String, for string: String) throws -> String {
    let nsRange = self.range(withName: name)

    if nsRange.location == NSNotFound {
      throw ARPCacheInternalError(explanation: "attempted to retrieve non-existent named capture group \(name)")
    }

    guard let range = Range.init(nsRange, in: string) else {
      throw ARPCacheInternalError(explanation: "failed to convert NSRange to Range")
    }

    return String(string[range])
  }
}
