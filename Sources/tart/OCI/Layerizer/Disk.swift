import Foundation

protocol Disk {
  static func push(diskURL: URL, registry: any BlobStorage, chunkSizeMb: Int, concurrency: UInt, progress: Progress) async throws -> [OCIManifestLayer]
  static func pull(registry: Registry, diskLayers: [OCIManifestLayer], diskURL: URL, concurrency: UInt, progress: Progress, localLayerCache: LocalLayerCache?, deduplicate: Bool) async throws
}
