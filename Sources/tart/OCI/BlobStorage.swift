import Foundation

protocol BlobStorage {
  func pushBlob(fromData: Data, chunkSizeMb: Int, digest: String?) async throws -> String
  func blobExists(_ digest: String) async throws -> Bool
  func pushManifest(reference: String, manifest: OCIManifest) async throws -> String
}
