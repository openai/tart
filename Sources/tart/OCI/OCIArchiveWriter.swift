import Foundation

class OCIArchiveWriter {
  private let tmpDir: URL
  private let blobsDir: URL
  private var manifestDigest: String?
  private var manifestSize: Int?
  private var manifestReferences: [String] = []
  private var manifestData: Data?

  init() throws {
    tmpDir = try Config().tartTmpDir.appendingPathComponent(UUID().uuidString)
    blobsDir = tmpDir.appendingPathComponent("blobs/sha256")
    try FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: tmpDir)
  }
}

extension OCIArchiveWriter: BlobStorage {
  func pushBlob(fromData: Data, chunkSizeMb: Int, digest: String?) async throws -> String {
    let resolvedDigest = digest ?? Digest.hash(fromData)
    let hex = resolvedDigest.replacingOccurrences(of: "sha256:", with: "")
    let blobPath = blobsDir.appendingPathComponent(hex)
    try fromData.write(to: blobPath)
    return resolvedDigest
  }

  func blobExists(_ digest: String) async throws -> Bool {
    let hex = digest.replacingOccurrences(of: "sha256:", with: "")
    let blobPath = blobsDir.appendingPathComponent(hex)
    return FileManager.default.fileExists(atPath: blobPath.path)
  }

  func pushManifest(reference: String, manifest: OCIManifest) async throws -> String {
    if let existingDigest = manifestDigest, let existingData = manifestData {
      let newData = try manifest.toJSON()
      if newData == existingData {
        manifestReferences.append(reference)
        return existingDigest
      }
    }

    let data = try manifest.toJSON()
    let digest = Digest.hash(data)
    let hex = digest.replacingOccurrences(of: "sha256:", with: "")
    let blobPath = blobsDir.appendingPathComponent(hex)
    try data.write(to: blobPath)
    manifestDigest = digest
    manifestSize = data.count
    manifestData = data
    manifestReferences.append(reference)
    return digest
  }

  func finalize(path: String, tag: String? = nil) throws {
    guard let manifestDigest = manifestDigest, let manifestSize = manifestSize else {
      throw RuntimeError.Generic("no manifest was pushed")
    }

    let ociLayoutData = try JSONSerialization.data(withJSONObject: ["imageLayoutVersion": "1.0.0"])
    try ociLayoutData.write(to: tmpDir.appendingPathComponent("oci-layout"))

    var manifests: [[String: Any]] = []

    let baseDescriptor: [String: Any] = [
      "mediaType": dockerManifestMediaType,
      "digest": manifestDigest,
      "size": manifestSize,
    ]

    let refs = manifestReferences.isEmpty
      ? (tag.map { [$0] } ?? ["latest"])
      : manifestReferences

    for ref in refs {
      var entry = baseDescriptor
      entry["annotations"] = [
        "org.opencontainers.image.ref.name": ref
      ]
      manifests.append(entry)
    }

    let index: [String: Any] = [
      "schemaVersion": 2,
      "manifests": manifests
    ]

    let indexData = try JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted, .sortedKeys])
    try indexData.write(to: tmpDir.appendingPathComponent("index.json"))

    let absolutePath = URL(fileURLWithPath: path).path

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    process.arguments = ["-cf", absolutePath, "-C", tmpDir.path, "."]

    let pipe = Pipe()
    process.standardError = pipe

    try process.run()
    process.waitUntilExit()

    if process.terminationStatus != 0 {
      let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
      throw RuntimeError.Generic(
        "creating OCI archive failed: \(String(data: errorData, encoding: .utf8) ?? "unknown error")"
      )
    }
  }
}
