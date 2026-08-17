import Foundation
import Virtualization

#if canImport(DiskImageKit)
  import DiskImageKit
#endif

/// The logical block layout exposed by a disk image.
struct DiskImageBlockLayout {
  let blockSize: UInt64
  let blockCount: UInt64
}

enum DiskImageStackError: Error, Equatable, CustomStringConvertible {
  case unavailable
  case writableOverlayAlreadyExists(URL)
  case writableOverlayMissing(URL)
  case invalidBlockLayout(String)
  case invalidDiskImage(URL, String)

  var description: String {
    switch self {
    case .unavailable:
      "stacked disks require DiskImageKit on macOS 27 or newer"
    case .writableOverlayAlreadyExists(let url):
      "writable overlay already exists: \(url.path)"
    case .writableOverlayMissing(let url):
      "writable overlay is missing: \(url.path)"
    case .invalidBlockLayout(let reason):
      reason
    case .invalidDiskImage(let url, let reason):
      "\(reason): \(url.path)"
    }
  }
}

struct DiskImageStack {
  /// DiskImageKit-ready paths and block layout after Tart disk chunks have been
  /// reconstructed into complete immutable files. The writable overlay stays
  /// private to one VM.
  let baseURL: URL
  let baseFormat: DiskImageFormat
  let immutableOverlayURLs: [URL]
  let writableOverlayURL: URL
  let blockSize: UInt64
  let blockCount: UInt64

  static var isSupported: Bool {
    #if canImport(DiskImageKit)
      if #available(macOS 27.0, *) {
        return true
      }
    #endif

    return false
  }

  static func requireSupport() throws {
    guard isSupported else {
      throw DiskImageStackError.unavailable
    }
  }

  /// Reads a disk image's current block layout without resolving or validating a
  /// whole stack. This is used for the VM's private writable overlay, whose
  /// size may be newer than the pinned immutable parent manifest.
  static func diskImageBlockLayout(at url: URL) throws -> DiskImageBlockLayout {
    #if canImport(DiskImageKit)
      if #available(macOS 27.0, *) {
        let image = try DiskImage(opening: .open(url: url, mode: .readOnly))
        return DiskImageBlockLayout(
          blockSize: UInt64(image.blockSize.rawValue),
          blockCount: UInt64(image.blockCount)
        )
      }
    #endif

    throw DiskImageStackError.unavailable
  }

  static func baseBlockLayout(
    at url: URL,
    expectedFormat: DiskImageFormat
  ) throws -> DiskImageBlockLayout {
    #if canImport(DiskImageKit)
      if #available(macOS 27.0, *) {
        let image = try DiskImage(opening: .open(url: url, mode: .readOnly))
        try validateBase(image, at: url, expectedFormat: expectedFormat)

        return DiskImageBlockLayout(
          blockSize: UInt64(image.blockSize.rawValue),
          blockCount: UInt64(image.blockCount)
        )
      }
    #endif

    throw DiskImageStackError.unavailable
  }

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
    readOnly: Bool = false,
    cachingMode: VZDiskImageCachingMode = .automatic,
    synchronizationMode: VZDiskImageSynchronizationMode = .full
  ) throws -> VZStorageDeviceAttachment {
    #if canImport(DiskImageKit)
      if #available(macOS 27.0, *) {
        return try attachmentWithDiskImageKit(
          readOnly: readOnly,
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
      readOnly: Bool,
      cachingMode: VZDiskImageCachingMode,
      synchronizationMode: VZDiskImageSynchronizationMode
    ) throws -> VZDiskImageStorageDeviceAttachment {
      guard FileManager.default.fileExists(atPath: writableOverlayURL.path) else {
        throw DiskImageStackError.writableOverlayMissing(writableOverlayURL)
      }

      let parent = try validatedParentImage()
      let writableOverlay = try openOverlay(
        at: writableOverlayURL,
        mode: readOnly ? .readOnly : .readWrite
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
        throw DiskImageStackError.invalidBlockLayout("invalid stacked disk block count \(blockCount)")
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
        throw DiskImageStackError.invalidBlockLayout("invalid stacked disk block count \(blockCount)")
      }

      let baseImage = try DiskImage(opening: .open(url: baseURL, mode: .readOnly))
      try Self.validateBase(baseImage, at: baseURL, expectedFormat: baseFormat)

      var image = baseImage

      for overlayURL in immutableOverlayURLs {
        let openedOverlay = try openOverlay(
          at: overlayURL,
          mode: .readOnly
        )
        let stackedImage = try append(openedOverlay, to: image, at: overlayURL)
        try validateAppendedOverlay(stackedImage, at: overlayURL)
        image = stackedImage
      }

      guard image.blockSize == expectedBlockSize else {
        throw DiskImageStackError.invalidBlockLayout("immutable disk stack does not match manifest block size")
      }
      guard image.blockCount == expectedBlockCount else {
        throw DiskImageStackError.invalidBlockLayout("immutable disk stack does not match manifest block count")
      }

      return image
    }

    @available(macOS 27.0, *)
    private static func validateBase(
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
      mode: OpenConfiguration.Mode
    ) throws -> DiskImage {
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
    private func diskImageBlockSize(_ value: UInt64) throws -> DiskImage.BlockSize {
      guard let intValue = Int(exactly: value), let blockSize = DiskImage.BlockSize(rawValue: intValue) else {
        throw DiskImageStackError.invalidBlockLayout("unsupported stacked disk block size \(value)")
      }

      return blockSize
    }
  #endif
}
