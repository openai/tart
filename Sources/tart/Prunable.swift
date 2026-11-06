import Foundation

protocol PrunableStorage {
  func prunables() throws -> [Prunable]
  func prunables(simulatingRemovalOf removedURLs: Swift.Set<URL>) throws -> [Prunable]
}

extension PrunableStorage {
  func prunables(simulatingRemovalOf removedURLs: Swift.Set<URL>) throws -> [Prunable] {
    try prunables().filter { !removedURLs.contains($0.url) }
  }
}

protocol Prunable {
  var url: URL { get }
  func delete() throws
  func accessDate() throws -> Date
  // size on disk as seen in Finder including empty blocks
  func sizeBytes() throws -> Int
  // actual size on disk without empty blocks
  func allocatedSizeBytes() throws -> Int
}
