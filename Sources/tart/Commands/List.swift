import ArgumentParser
import Dispatch
import SwiftUI

fileprivate struct VMInfo: Encodable {
  let Source: String
  let Name: String
  let Disk: HumanReadableByteCount
  let Size: HumanReadableByteCount
  let Accessed: String
  let Running: Bool
  let State: String
}

struct List: AsyncParsableCommand {
  static var configuration = CommandConfiguration(abstract: "List created VMs")

  @Option(help: ArgumentHelp("Only display VMs from the specified source (e.g. --source local, --source oci)."))
  var source: String?

  @Option(help: "Output format: text or json", completion: .list(["text", "json"]))
  var format: Format = .text

  @Flag(name: [.short, .long], help: ArgumentHelp("Only display VM names."))
  var quiet: Bool = false

  func validate() throws {
    guard let source = source else {
      return
    }

    if !["local", "oci"].contains(source) {
      throw ValidationError("'\(source)' is not a valid <source>")
    }
  }

  func run() async throws {
    var infos: [VMInfo] = []

    if source == nil || source == "local" {
      infos += sortedInfos(try VMStorageLocal().list().map { (name, vmDir) in
        try VMInfo(
          Source: "local",
          Name: name,
          Disk: HumanReadableByteCount(try vmDir.sizeBytes()) { $0 / 1000 / 1000 / 1000 },
          Size: HumanReadableByteCount(try vmDir.allocatedSizeBytes()) { $0 / 1000 / 1000 / 1000 },
          Accessed: formatAccessDate(try vmDir.accessDate()),
          Running: vmDir.running(),
          State: vmDir.state().rawValue
        )
      })
    }

    if source == nil || source == "oci" {
      infos += sortedInfos(try VMStorageOCI().list().map { (name, vmDir, _) in
        try VMInfo(
          Source: "OCI",
          Name: name,
          Disk: HumanReadableByteCount(try vmDir.sizeBytes()) { $0 / 1000 / 1000 / 1000 },
          Size: HumanReadableByteCount(try vmDir.allocatedSizeBytes()) { $0 / 1000 / 1000 / 1000 },
          Accessed: formatAccessDate(try vmDir.accessDate()),
          Running: vmDir.running(),
          State: vmDir.state().rawValue
        )
      })
    }

    if (quiet) {
      for info in infos {
        print(info.Name)
      }
    } else {
      print(format.renderList(infos))
    }
  }

  private func sortedInfos(_ infos: [VMInfo]) -> [VMInfo] {
    infos.sorted(by: { left, right in left.Name < right.Name })
  }

  private func formatAccessDate(_ accessDate: Date) -> String {
    switch format {
    case .text:
      let formatter = RelativeDateTimeFormatter()
      formatter.unitsStyle = .full
      return formatter.localizedString(for: accessDate, relativeTo: Date())
    case .json:
      let formatter = ISO8601DateFormatter()
      return formatter.string(from: accessDate)
    }
  }
}
