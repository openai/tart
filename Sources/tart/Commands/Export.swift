import ArgumentParser
import Foundation

struct Export: AsyncParsableCommand {
  static var configuration = CommandConfiguration(abstract: "Export VM to a compressed .tvm file")

  @Argument(help: "Source VM name.", completion: .custom(completeMachines))
  var name: String

  @Argument(help: "Path to the destination file.", completion: .file())
  var path: String?

  func run() async throws {
    let correctedPath: String

    if let path = path {
      correctedPath = path
    } else {
      correctedPath = "\(name).tvm"

      if FileManager.default.fileExists(atPath: correctedPath) {
        while true {
          if userWantsOverwrite(correctedPath) {
            break
          } else {
            return
          }
        }
      }
    }

    print("exporting...")

    try VMStorageHelper.open(name).exportToArchive(path: correctedPath)
  }

  func userWantsOverwrite(_ filename: String) -> Bool {
    print("file \(filename) already exists, are you sure you want to overwrite it? (yes, [no])? ", terminator: "")

    let answer = readLine()

    return answer == "yes"
  }
}
