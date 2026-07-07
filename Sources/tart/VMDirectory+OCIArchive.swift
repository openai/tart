import Foundation

extension VMDirectory {
  func saveToArchive(path: String, concurrency: UInt, labels: [String: String] = [:], tag: String? = nil) async throws {
    let archive = try OCIArchiveWriter()

    let diskSize = try FileManager.default.attributesOfItem(atPath: diskURL.path)[.size] as! Int64

    // Create a standard tar+gzip layer containing VM files
    defaultLogger.appendNewLine("archiving disk... this will take a while...")
    let progress = Progress(totalUnitCount: diskSize)
    ProgressObserver(progress).log(defaultLogger)

    let layerTarGz = archive.tmpDir.appendingPathComponent("layer.tar.gz")

    let tarProcess = Process()
    tarProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    tarProcess.arguments = ["-czf", layerTarGz.path, "-C", baseURL.path,
                            "disk.img", "nvram.bin", "config.json"]

    let tarPipe = Pipe()
    tarProcess.standardError = tarPipe

    try tarProcess.run()
    tarProcess.waitUntilExit()

    if tarProcess.terminationStatus != 0 {
      let errorData = tarPipe.fileHandleForReading.readDataToEndOfFile()
      throw RuntimeError.Generic(
        "creating archive layer failed: \(String(data: errorData, encoding: .utf8) ?? "unknown error")"
      )
    }

    let layerData = try Data(contentsOf: layerTarGz, options: .alwaysMapped)
    let layerDigest = try await archive.pushBlob(fromData: layerData, chunkSizeMb: 0, digest: nil)
    progress.completedUnitCount = diskSize

    let config = try VMConfig(fromURL: configURL)
    var labels = labels
    labels[diskFormatLabel] = config.diskFormat.rawValue

    let ociConfigContainer = OCIConfig.ConfigContainer(Labels: labels)
    let ociConfigJSON = try OCIConfig(architecture: config.arch, os: config.os, config: ociConfigContainer).toJSON()
    let ociConfigDigest = try await archive.pushBlob(fromData: ociConfigJSON, chunkSizeMb: 0, digest: nil)

    let manifest = OCIManifest(
      config: OCIManifestConfig(size: ociConfigJSON.count, digest: ociConfigDigest),
      layers: [
        OCIManifestLayer(mediaType: ociLayerMediaType, size: layerData.count, digest: layerDigest)
      ],
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
