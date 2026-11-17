import Foundation

struct ImageInfo: Codable {
  let sizeInfo: SizeInfo?
  let size: UInt64?

  enum CodingKeys: String, CodingKey {
    case sizeInfo = "Size Info"
    case size = "Size"
  }

  func totalBytes() throws -> Int {
    if let totalBytes = self.sizeInfo?.totalBytes {
      return Int(totalBytes)
    }

    if let size = self.size {
      return Int(size)
    }

    throw RuntimeError.Generic("Could not find size information in disk image info")
  }
}

struct SizeInfo: Codable {
  let totalBytes: UInt64?

  enum CodingKeys: String, CodingKey {
    case totalBytes = "Total Bytes"
  }
}

struct Diskutil {
  static func imageCreate(diskURL: URL, sizeGB: UInt16) throws {
    do {
      _ = try run([
        "image", "create", "blank",
        "--format", "ASIF",
        "--size", "\(sizeGB)G",
        "--volumeName", "Tart",
        diskURL.path
      ])
    } catch {
      throw RuntimeError.FailedToCreateDisk("Failed to create ASIF disk image: \(error)")
    }
  }

  static func imageCreate(from sourceURL: URL, overlays: [URL], format: DiskImageFormat, to diskURL: URL) throws {
    var arguments = ["image", "create", "from", "--format", format.rawValue.uppercased()]
    for overlayURL in overlays {
      arguments += ["--shadow", overlayURL.path]
    }
    arguments += [sourceURL.path, diskURL.path]

    do {
      _ = try run(arguments)
    } catch {
      throw RuntimeError.FailedToCreateDisk("Failed to flatten disk image: \(error)")
    }
  }

  static func imageInfo(_ diskURL: URL) throws -> ImageInfo {
    do {
      let (stdoutData, _) = try run([
        "image", "info", "--plist",
        diskURL.path
      ])

      do {
        return try PropertyListDecoder().decode(ImageInfo.self, from: stdoutData)
      } catch {
        throw RuntimeError.Generic("Failed to parse \"diskutil image info --plist\" output: \(error)")
      }
    }
  }

  private static func run(_ arguments: [String]) throws -> (Data, Data) {
    guard let diskutilURL = resolveBinaryPath("diskutil") else {
      throw RuntimeError.Generic("\"diskutil\" binary is not found in PATH")
    }

    let process = Process()
    process.executableURL = diskutilURL
    process.arguments = arguments

    let stdoutPipe = Pipe()
    process.standardOutput = stdoutPipe
    let stderrPipe = Pipe()
    process.standardError = stderrPipe

    do {
      try process.run()
    } catch {
      throw RuntimeError.Generic("\"\(arguments.joined(separator: " "))\" failed: \(error)")
    }
    process.waitUntilExit()

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

    if process.terminationStatus != 0 {
      let stdoutString = String(data: stdoutData, encoding: .utf8) ?? ""
      let stderrString = String(data: stderrData, encoding: .utf8) ?? ""

      throw RuntimeError.Generic("\"\(arguments.joined(separator: " "))\" failed with exit code \(process.terminationStatus): \(firstNonEmptyLine(stderrString, stdoutString))")
    }

    return (stdoutData, stderrData)
  }

  private static func firstNonEmptyLine(_ outputs: String...) -> String {
    for output in outputs {
      for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
        if !line.isEmpty {
          return String(line)
        }
      }
    }

    return ""
  }
}
