import Foundation
import Virtualization

#if canImport(DiskImageKit)
  import DiskImageKit
#endif

/// One immutable complete disk file used by a stacked disk.
///
/// This is a reconstructed base disk or published ASIF overlay, not an OCI
/// layer or an individual Tart disk chunk.
struct DiskImageFile {
  let url: URL
  let contentDigest: String
}

enum DiskImageStackError: Error, Equatable, CustomStringConvertible {
  case unavailable
  case writableOverlayAlreadyExists(URL)
  case writableOverlayMissing(URL)
  case invalidGeometry(String)
  case invalidDiskImage(URL, String)

  var description: String {
    switch self {
    case .unavailable:
      "stacked disks require DiskImageKit on macOS 27 or newer"
    case .writableOverlayAlreadyExists(let url):
      "writable overlay already exists: \(url.path)"
    case .writableOverlayMissing(let url):
      "writable overlay is missing: \(url.path)"
    case .invalidGeometry(let reason):
      reason
    case .invalidDiskImage(let url, let reason):
      "\(reason): \(url.path)"
    }
  }
}

struct DiskImageStack {
  /// DiskImageKit-ready paths and geometry after Tart disk chunks have been
  /// reconstructed into complete immutable files. The writable overlay stays
  /// private to one VM.
  let base: DiskImageFile
  let baseFormat: DiskImageFormat
  let overlays: [DiskImageFile]
  let writableOverlayURL: URL
  let blockSize: UInt64
  let blockCount: UInt64

  func createWritableOverlay() throws {
    #if canImport(DiskImageKit)
      if #available(macOS 27.0, *) {
        try createWritableOverlayWithDiskImageKit()
        return
      }
    #endif

    throw DiskImageStackError.unavailable
  }

  func copyWritableOverlay(to destinationURL: URL) throws {
    guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
      throw DiskImageStackError.writableOverlayAlreadyExists(destinationURL)
    }

    try FileManager.default.copyItem(at: writableOverlayURL, to: destinationURL)
  }

  func makeAttachment(
    cachingMode: VZDiskImageCachingMode = .automatic,
    synchronizationMode: VZDiskImageSynchronizationMode = .full
  ) throws -> VZDiskImageStorageDeviceAttachment {
    #if canImport(DiskImageKit)
      if #available(macOS 27.0, *) {
        return try attachmentWithDiskImageKit(
          cachingMode: cachingMode,
          synchronizationMode: synchronizationMode
        )
      }
    #endif

    throw DiskImageStackError.unavailable
  }

  func growWritableOverlay(toBlockCount blockCount: UInt64) throws {
    #if canImport(DiskImageKit)
      if #available(macOS 27.0, *) {
        try growWritableOverlayWithDiskImageKit(toBlockCount: blockCount)
        return
      }
    #endif

    throw DiskImageStackError.unavailable
  }

  #if canImport(DiskImageKit)
    @available(macOS 27.0, *)
    private func createWritableOverlayWithDiskImageKit() throws {
      guard !FileManager.default.fileExists(atPath: writableOverlayURL.path) else {
        throw DiskImageStackError.writableOverlayAlreadyExists(writableOverlayURL)
      }

      let parent = try validatedParentImage()
      let stackedImage = try parent.appending(.asifLayer(url: writableOverlayURL, type: .overlay))
      try validateAppendedOverlay(stackedImage, at: writableOverlayURL)
    }

    @available(macOS 27.0, *)
    private func attachmentWithDiskImageKit(
      cachingMode: VZDiskImageCachingMode,
      synchronizationMode: VZDiskImageSynchronizationMode
    ) throws -> VZDiskImageStorageDeviceAttachment {
      guard FileManager.default.fileExists(atPath: writableOverlayURL.path) else {
        throw DiskImageStackError.writableOverlayMissing(writableOverlayURL)
      }

      let parent = try validatedParentImage()
      let writableOverlay = try openOverlay(
        at: writableOverlayURL,
        mode: .readWrite
      )
      let stackedImage = try append(writableOverlay, to: parent, at: writableOverlayURL)
      try validateAppendedOverlay(stackedImage, at: writableOverlayURL)

      return try VZDiskImageStorageDeviceAttachment(
        diskImage: stackedImage,
        cachingMode: cachingMode,
        synchronizationMode: synchronizationMode
      )
    }

    @available(macOS 27.0, *)
    private func growWritableOverlayWithDiskImageKit(toBlockCount blockCount: UInt64) throws {
      guard blockCount > 0, let desiredBlockCount = Int(exactly: blockCount) else {
        throw DiskImageStackError.invalidGeometry("invalid stacked disk block count \(blockCount)")
      }

      let parent = try validatedParentImage()
      let overlay = try openOverlay(
        at: writableOverlayURL,
        mode: .readWrite
      )
      let currentBlockCount = overlay.blockCount
      let stackedImage = try append(overlay, to: parent, at: writableOverlayURL)
      try validateAppendedOverlay(stackedImage, at: writableOverlayURL)
      guard desiredBlockCount >= currentBlockCount else {
        throw DiskImageStackError.invalidDiskImage(writableOverlayURL, "ASIF overlay block count shrinks the stacked disk")
      }

      guard let writableOverlay = stackedImage.layers.last else {
        throw DiskImageStackError.invalidDiskImage(writableOverlayURL, "disk image must be an ASIF overlay")
      }
      if desiredBlockCount > currentBlockCount {
        try writableOverlay.truncate(blockCount: desiredBlockCount)
      }
    }

    @available(macOS 27.0, *)
    private func validatedParentImage() throws -> DiskImage {
      let expectedBlockSize = try diskImageBlockSize(blockSize)
      guard blockCount > 0, let expectedBlockCount = Int(exactly: blockCount) else {
        throw DiskImageStackError.invalidGeometry("invalid stacked disk block count \(blockCount)")
      }

      try verifyContentDigest(base)
      let baseImage = try DiskImage(opening: .open(url: base.url, mode: .readOnly))
      try validateBase(baseImage, at: base.url, expectedFormat: baseFormat)

      var image = baseImage

      for overlay in overlays {
        let openedOverlay = try openOverlay(
          at: overlay.url,
          expectedDigest: overlay.contentDigest,
          mode: .readOnly
        )
        let stackedImage = try append(openedOverlay, to: image, at: overlay.url)
        try validateAppendedOverlay(stackedImage, at: overlay.url)
        image = stackedImage
      }

      guard image.blockSize == expectedBlockSize else {
        throw DiskImageStackError.invalidGeometry("immutable disk stack does not match manifest block size")
      }
      guard image.blockCount == expectedBlockCount else {
        throw DiskImageStackError.invalidGeometry("immutable disk stack does not match manifest block count")
      }

      return image
    }

    @available(macOS 27.0, *)
    private func validateBase(
      _ image: DiskImage,
      at url: URL,
      expectedFormat: DiskImageFormat
    ) throws {
      let matchesFormat = switch expectedFormat {
      case .raw:
        image.format == .raw
      case .asif:
        image.format == .asif
      }
      guard matchesFormat else {
        throw DiskImageStackError.invalidDiskImage(url, "base disk format does not match")
      }
      guard image.layerType == nil, image.parentUUID == nil else {
        throw DiskImageStackError.invalidDiskImage(url, "base disk must not be an overlay")
      }
      if expectedFormat == .asif && image.layerUUID == nil {
        throw DiskImageStackError.invalidDiskImage(url, "ASIF base disk is missing a UUID")
      }
    }

    @available(macOS 27.0, *)
    private func openOverlay(
      at url: URL,
      expectedDigest: String? = nil,
      mode: OpenConfiguration.Mode
    ) throws -> DiskImage {
      if let expectedDigest {
        try verifyContentDigest(DiskImageFile(url: url, contentDigest: expectedDigest))
      }

      let image = try DiskImage(opening: .open(url: url, mode: mode))
      guard image.format == .asif else {
        throw DiskImageStackError.invalidDiskImage(url, "overlay must use ASIF format")
      }

      return image
    }

    @available(macOS 27.0, *)
    private func append(_ overlay: DiskImage, to parent: DiskImage, at url: URL) throws -> any StackedImage {
      do {
        return try parent.appending(overlay)
      } catch is IncompatibleStackingError {
        throw DiskImageStackError.invalidDiskImage(url, "ASIF overlay is incompatible with its parent")
      }
    }

    @available(macOS 27.0, *)
    private func validateAppendedOverlay(_ image: any StackedImage, at url: URL) throws {
      guard image.layers.last?.layerType == .overlay else {
        throw DiskImageStackError.invalidDiskImage(url, "disk image must be an ASIF overlay")
      }
    }

    @available(macOS 27.0, *)
    private func verifyContentDigest(_ diskImage: DiskImageFile) throws {
      guard try Digest.hash(diskImage.url) == diskImage.contentDigest else {
        throw DiskImageStackError.invalidDiskImage(diskImage.url, "disk image content digest does not match")
      }
    }

    @available(macOS 27.0, *)
    private func diskImageBlockSize(_ value: UInt64) throws -> DiskImage.BlockSize {
      guard let intValue = Int(exactly: value), let blockSize = DiskImage.BlockSize(rawValue: intValue) else {
        throw DiskImageStackError.invalidGeometry("unsupported stacked disk block size \(value)")
      }

      return blockSize
    }
  #endif
}
