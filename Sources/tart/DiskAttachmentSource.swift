import Foundation
import Virtualization

/// A disk-image-backed source that can become a Virtualization.Framework storage attachment.
protocol DiskAttachmentSource {
  func makeAttachment(
    readOnly: Bool,
    cachingMode: VZDiskImageCachingMode,
    synchronizationMode: VZDiskImageSynchronizationMode
  ) throws -> VZStorageDeviceAttachment
}

struct DiskImageAttachment: DiskAttachmentSource {
  let url: URL

  func makeAttachment(
    readOnly: Bool,
    cachingMode: VZDiskImageCachingMode,
    synchronizationMode: VZDiskImageSynchronizationMode
  ) throws -> VZStorageDeviceAttachment {
    try VZDiskImageStorageDeviceAttachment(
      url: url,
      readOnly: readOnly,
      cachingMode: cachingMode,
      synchronizationMode: synchronizationMode
    )
  }
}
