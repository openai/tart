import Foundation

extension VMDirectory {
  func saveToArchive(path: String, concurrency: UInt, labels: [String: String] = [:], tag: String? = nil) async throws {
    let archive = try OCIArchiveWriter()

    var layers = [OCIManifestLayer]()

    let config = try VMConfig(fromURL: configURL)
    var labels = labels
    labels[diskFormatLabel] = config.diskFormat.rawValue
    let configJSON = try JSONEncoder().encode(config)
    defaultLogger.appendNewLine("saving config...")
    let configDigest = try await archive.pushBlob(fromData: configJSON, chunkSizeMb: 0, digest: nil)
    layers.append(OCIManifestLayer(mediaType: configMediaType, size: configJSON.count, digest: configDigest))

    let diskSize = try FileManager.default.attributesOfItem(atPath: diskURL.path)[.size] as! Int64
    defaultLogger.appendNewLine("saving disk... this will take a while...")
    let progress = Progress(totalUnitCount: diskSize)
    ProgressObserver(progress).log(defaultLogger)

    layers.append(contentsOf: try await DiskV2.push(diskURL: diskURL, registry: archive, chunkSizeMb: 0, concurrency: concurrency, progress: progress))

    defaultLogger.appendNewLine("saving NVRAM...")
    let nvram = try FileHandle(forReadingFrom: nvramURL).readToEnd()!
    let nvramDigest = try await archive.pushBlob(fromData: nvram, chunkSizeMb: 0, digest: nil)
    layers.append(OCIManifestLayer(mediaType: nvramMediaType, size: nvram.count, digest: nvramDigest))

    let ociConfigContainer = OCIConfig.ConfigContainer(Labels: labels)
    let ociConfigJSON = try OCIConfig(architecture: config.arch, os: config.os, config: ociConfigContainer).toJSON()
    let ociConfigDigest = try await archive.pushBlob(fromData: ociConfigJSON, chunkSizeMb: 0, digest: nil)

    let manifest = OCIManifest(
      config: OCIManifestConfig(size: ociConfigJSON.count, digest: ociConfigDigest),
      layers: layers,
      uncompressedDiskSize: UInt64(diskSize),
      uploadDate: Date()
    )

    let tagRef = tag ?? "latest"
    defaultLogger.appendNewLine("saving manifest...")
    _ = try await archive.pushManifest(reference: tagRef, manifest: manifest)

    try archive.finalize(path: path, tag: tagRef)

    defaultLogger.appendNewLine("saved to \(path)")
  }
}
