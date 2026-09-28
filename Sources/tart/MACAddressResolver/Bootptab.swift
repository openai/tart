import Foundation
import Network

struct Bootptab {
  private var reservations: [MACAddress: Swift.Set<IPv4Address>] = [:]

  init?(_ fromURL: URL = URL(fileURLWithPath: "/etc/bootptab")) throws {
    let contents: String

    do {
      contents = try String(contentsOf: fromURL, encoding: .utf8)
    } catch {
      if error.isFileNotFound() {
        return nil
      }

      throw error
    }

    for line in contents.split(whereSeparator: \.isNewline) {
      let fields = line.split(whereSeparator: \.isWhitespace)

      // Skip lines that don't look like reservation fields
      guard fields.count >= 4 else {
        continue
      }

      // Assign reservation fields
      let hardwareType = fields[1]
      let hardwareAddress = fields[2]
      let ipAddress = fields[3]

      // Skip non-Ethernet reservations
      guard hardwareType == "1" else {
        continue
      }

      // Skip malformed MAC addresses
      guard let mac = MACAddress(fromString: String(hardwareAddress)) else {
        continue
      }

      // Skip malformed IPv4 addresses
      guard let ip = IPv4Address(String(ipAddress)) else {
        continue
      }

      reservations[mac, default: []].insert(ip)
    }
  }

  func ResolveMACAddress(macAddress: MACAddress) throws -> IPv4Address? {
    guard let addresses = reservations[macAddress] else {
      return nil
    }

    if addresses.count > 1 {
      let addresses = addresses.map { $0.debugDescription }.sorted().joined(separator: ", ")

      throw RuntimeError.Generic("multiple DHCP reservations in /etc/bootptab for \(macAddress): \(addresses)")
    }

    return addresses.first
  }
}
