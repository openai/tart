import Foundation
import zlib

struct MacOSDisk {
  private static let copyBufferSizeBytes: UInt64 = 8 * 1024 * 1024

  static func resize(_ diskURL: URL, to size: UInt64, stagingURL: URL) throws {
    let source = try FileHandle(forReadingFrom: diskURL)
    defer { try? source.close() }
    let currentSize = try source.seekToEnd()
    guard size >= currentSize else {
      throw RuntimeError.InvalidDiskSize("new disk size must not be smaller than the current disk size")
    }

    var table = try PartitionTable(source, diskSize: currentSize)
    guard size.isMultiple(of: table.blockSize) else {
      throw RuntimeError.InvalidDiskSize("new disk size must align to the disk block size")
    }
    let lastBlock = size / table.blockSize - 1
    let lastUsableBlock = lastBlock - table.tableBlocks - 1
    let recoveryBlocks = table.recoveryEnd - table.recoveryStart + 1
    let recoveryStart = lastUsableBlock - recoveryBlocks + 1
    guard recoveryStart >= table.recoveryStart else {
      throw RuntimeError.InvalidDiskSize("new disk size leaves insufficient space for Recovery")
    }
    if size == currentSize && recoveryStart == table.recoveryStart {
      return
    }

    try FileManager.default.copyItem(at: diskURL, to: stagingURL)
    defer { try? FileManager.default.removeItem(at: stagingURL) }
    let destination = try FileHandle(forUpdating: stagingURL)
    defer { try? destination.close() }
    try destination.truncate(atOffset: size)

    try source.seek(toOffset: table.recoveryStart * table.blockSize)
    try destination.seek(toOffset: recoveryStart * table.blockSize)
    var remaining = recoveryBlocks * table.blockSize
    while remaining > 0 {
      try Task.checkCancellation()
      let count = Int(min(remaining, copyBufferSizeBytes))
      let data = try source.readExactly(count)
      try destination.write(contentsOf: data)
      remaining -= UInt64(count)
    }

    table.entries.setUInt64(recoveryStart, at: GPTEntry.recoveryOffset + GPTEntry.firstBlockOffset)
    table.entries.setUInt64(lastUsableBlock, at: GPTEntry.recoveryOffset + GPTEntry.lastBlockOffset)
    let checksum = table.entries.crc32Checksum
    table.primary.setUInt64(lastBlock, at: GPTHeader.alternateBlockOffset)
    table.primary.setUInt64(lastUsableBlock, at: GPTHeader.lastUsableBlockOffset)
    table.primary.setUInt32(checksum, at: GPTHeader.entriesChecksumOffset)
    table.primary.updateHeaderChecksum()
    table.backup.setUInt64(lastBlock, at: GPTHeader.currentBlockOffset)
    table.backup.setUInt64(lastUsableBlock, at: GPTHeader.lastUsableBlockOffset)
    table.backup.setUInt64(lastBlock - table.tableBlocks, at: GPTHeader.entriesBlockOffset)
    table.backup.setUInt32(checksum, at: GPTHeader.entriesChecksumOffset)
    table.backup.updateHeaderChecksum()
    table.mbr.setUInt32(UInt32(min(lastBlock, UInt64(UInt32.max))), at: ProtectiveMBR.partitionSizeOffset)

    try destination.write(table.entries, at: (lastBlock - table.tableBlocks) * table.blockSize)
    try destination.write(table.backup, at: lastBlock * table.blockSize)
    try destination.write(table.entries, at: GPTHeader.primaryEntriesBlock * table.blockSize)
    try destination.write(table.primary, at: GPTHeader.primaryBlock * table.blockSize)
    try destination.write(table.mbr, at: 0)
    try destination.synchronize()
    try destination.close()

    let staged = try FileHandle(forReadingFrom: stagingURL)
    defer { try? staged.close() }
    _ = try PartitionTable(staged, diskSize: size)
    try Task.checkCancellation()
    if rename(stagingURL.path, diskURL.path) != 0 {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  private struct PartitionTable {
    private static let supportedBlockSizes: [UInt64] = [512, 4096]
    private static let minimumBlockCount: UInt64 = 68
    private static let partitionTypes = [GPTEntry.iBootType, GPTEntry.apfsType, GPTEntry.recoveryType]

    let blockSize: UInt64
    let tableBlocks: UInt64
    var mbr: Data
    var primary: Data
    var backup: Data
    var entries: Data
    let recoveryStart: UInt64
    let recoveryEnd: UInt64

    init(_ file: FileHandle, diskSize: UInt64) throws {
      guard let blockSize = try Self.supportedBlockSizes.first(where: {
        try file.readExactly(GPTHeader.signature.count, at: $0) == GPTHeader.signature
      }) else {
        throw RuntimeError.FailedToResizeDisk("disk does not contain a supported GPT")
      }
      self.blockSize = blockSize
      guard diskSize.isMultiple(of: blockSize), diskSize / blockSize >= Self.minimumBlockCount else {
        throw RuntimeError.FailedToResizeDisk("invalid GPT disk size")
      }
      tableBlocks = UInt64(GPTEntry.tableSize) / blockSize
      mbr = try file.readExactly(Int(blockSize), at: 0)
      primary = try file.readExactly(Int(blockSize), at: GPTHeader.primaryBlock * blockSize)
      try Self.validateHeader(primary)
      let backupBlock = primary.uint64(at: GPTHeader.alternateBlockOffset)
      let firstUsableBlock = primary.uint64(at: GPTHeader.firstUsableBlockOffset)
      let lastUsableBlock = primary.uint64(at: GPTHeader.lastUsableBlockOffset)
      guard primary.uint64(at: GPTHeader.currentBlockOffset) == GPTHeader.primaryBlock,
            primary.uint64(at: GPTHeader.entriesBlockOffset) == GPTHeader.primaryEntriesBlock,
            backupBlock >= GPTHeader.primaryEntriesBlock + 2 * tableBlocks + 1,
            backupBlock < diskSize / blockSize,
            firstUsableBlock >= GPTHeader.primaryEntriesBlock + tableBlocks,
            lastUsableBlock < backupBlock - tableBlocks,
            firstUsableBlock <= lastUsableBlock else {
        throw RuntimeError.FailedToResizeDisk("invalid primary GPT bounds")
      }
      backup = try file.readExactly(Int(blockSize), at: backupBlock * blockSize)
      try Self.validateHeader(backup)
      guard backup.uint64(at: GPTHeader.currentBlockOffset) == backupBlock,
            backup.uint64(at: GPTHeader.alternateBlockOffset) == GPTHeader.primaryBlock,
            backup.uint64(at: GPTHeader.entriesBlockOffset) == backupBlock - tableBlocks,
            backup[GPTHeader.usableBlocksAndDiskGUIDRange] == primary[GPTHeader.usableBlocksAndDiskGUIDRange],
            backup[GPTHeader.entriesMetadataRange] == primary[GPTHeader.entriesMetadataRange] else {
        throw RuntimeError.FailedToResizeDisk("primary and backup GPT headers do not match")
      }
      entries = try file.readExactly(GPTEntry.tableSize, at: GPTHeader.primaryEntriesBlock * blockSize)
      let backupEntries = try file.readExactly(GPTEntry.tableSize, at: (backupBlock - tableBlocks) * blockSize)
      guard entries == backupEntries, entries.crc32Checksum == primary.uint32(at: GPTHeader.entriesChecksumOffset) else {
        throw RuntimeError.FailedToResizeDisk("invalid GPT partition checksum or backup")
      }

      var previousEnd = firstUsableBlock - 1
      for (index, type) in Self.partitionTypes.enumerated() {
        let offset = index * GPTEntry.size
        let start = entries.uint64(at: offset + GPTEntry.firstBlockOffset)
        let end = entries.uint64(at: offset + GPTEntry.lastBlockOffset)
        guard entries[offset..<offset + GPTEntry.typeSize] == type,
              start > previousEnd, end >= start, end <= lastUsableBlock else {
          throw RuntimeError.FailedToResizeDisk("expected iBoot, APFS and Recovery partitions in disk order")
        }
        previousEnd = end
      }
      for index in Self.partitionTypes.count..<GPTEntry.count {
        let offset = index * GPTEntry.size
        guard entries[offset..<offset + GPTEntry.typeSize].allSatisfy({ $0 == 0 }) else {
          throw RuntimeError.FailedToResizeDisk("disk contains additional partitions")
        }
      }
      guard mbr[ProtectiveMBR.signatureRange] == ProtectiveMBR.signature,
            mbr[ProtectiveMBR.partitionTypeOffset] == ProtectiveMBR.partitionType,
            mbr.uint32(at: ProtectiveMBR.partitionStartOffset) == GPTHeader.primaryBlock,
            mbr[ProtectiveMBR.unusedEntriesRange].allSatisfy({ $0 == 0 }) else {
        throw RuntimeError.FailedToResizeDisk("invalid protective MBR")
      }
      recoveryStart = entries.uint64(at: GPTEntry.recoveryOffset + GPTEntry.firstBlockOffset)
      recoveryEnd = entries.uint64(at: GPTEntry.recoveryOffset + GPTEntry.lastBlockOffset)
    }

    private static func validateHeader(_ header: Data) throws {
      guard header.prefix(GPTHeader.signature.count) == GPTHeader.signature,
            header.uint32(at: GPTHeader.revisionOffset) == GPTHeader.revision,
            header.uint32(at: GPTHeader.sizeOffset) == GPTHeader.size,
            header.uint32(at: GPTHeader.reservedOffset) == 0,
            header.uint32(at: GPTHeader.entryCountOffset) == GPTEntry.count,
            header.uint32(at: GPTHeader.entrySizeOffset) == GPTEntry.size else {
        throw RuntimeError.FailedToResizeDisk("unsupported GPT header")
      }
      var bytes = header.prefix(GPTHeader.size)
      bytes.setUInt32(0, at: GPTHeader.checksumOffset)
      guard bytes.crc32Checksum == header.uint32(at: GPTHeader.checksumOffset) else {
        throw RuntimeError.FailedToResizeDisk("invalid GPT header checksum")
      }
    }
  }
}

private enum GPTHeader {
  static let signature = Data("EFI PART".utf8)
  static let revision: UInt32 = 0x00010000
  static let size = 92
  static let primaryBlock: UInt64 = 1
  static let primaryEntriesBlock: UInt64 = 2

  static let revisionOffset = 8
  static let sizeOffset = 12
  static let checksumOffset = 16
  static let reservedOffset = 20
  static let currentBlockOffset = 24
  static let alternateBlockOffset = 32
  static let firstUsableBlockOffset = 40
  static let lastUsableBlockOffset = 48
  static let entriesBlockOffset = 72
  static let entryCountOffset = 80
  static let entrySizeOffset = 84
  static let entriesChecksumOffset = 88

  static let usableBlocksAndDiskGUIDRange = firstUsableBlockOffset..<entriesBlockOffset
  static let entriesMetadataRange = entryCountOffset..<size
}

private enum GPTEntry {
  static let count = 128
  static let size = 128
  static let tableSize = count * size
  static let typeSize = 16
  static let firstBlockOffset = 32
  static let lastBlockOffset = 40
  static let recoveryOffset = 2 * size

  static let iBootType = Data([0x61, 0x69, 0x64, 0x69, 0x00, 0x67, 0xAA, 0x11, 0xAA, 0x11, 0x00, 0x30, 0x65, 0x43, 0xEC, 0xAC])
  static let apfsType = Data([0xEF, 0x57, 0x34, 0x7C, 0x00, 0x00, 0xAA, 0x11, 0xAA, 0x11, 0x00, 0x30, 0x65, 0x43, 0xEC, 0xAC])
  static let recoveryType = Data([0x72, 0x76, 0x63, 0x52, 0x00, 0x79, 0xAA, 0x11, 0xAA, 0x11, 0x00, 0x30, 0x65, 0x43, 0xEC, 0xAC])
}

private enum ProtectiveMBR {
  static let signature = Data([0x55, 0xAA])
  static let signatureOffset = 510
  static let signatureRange = signatureOffset..<signatureOffset + signature.count
  static let partitionType: UInt8 = 0xEE
  static let partitionTableOffset = 446
  static let partitionEntrySize = 16
  static let partitionTypeOffset = partitionTableOffset + 4
  static let partitionStartOffset = partitionTableOffset + 8
  static let partitionSizeOffset = partitionTableOffset + 12
  static let unusedEntriesRange = partitionTableOffset + partitionEntrySize..<signatureOffset
}

private extension FileHandle {
  func readExactly(_ count: Int, at offset: UInt64? = nil) throws -> Data {
    if let offset {
      try seek(toOffset: offset)
    }
    guard let data = try read(upToCount: count), data.count == count else {
      throw RuntimeError.FailedToResizeDisk("unexpected end of disk image")
    }
    return data
  }

  func write(_ data: Data, at offset: UInt64) throws {
    try seek(toOffset: offset)
    try write(contentsOf: data)
  }
}

private extension Data {
  func uint32(at offset: Int) -> UInt32 {
    withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
  }

  func uint64(at offset: Int) -> UInt64 {
    withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
  }

  mutating func setUInt32(_ value: UInt32, at offset: Int) {
    Swift.withUnsafeBytes(of: value.littleEndian) { replaceSubrange(offset..<offset + MemoryLayout<UInt32>.size, with: $0) }
  }

  mutating func setUInt64(_ value: UInt64, at offset: Int) {
    Swift.withUnsafeBytes(of: value.littleEndian) { replaceSubrange(offset..<offset + MemoryLayout<UInt64>.size, with: $0) }
  }

  var crc32Checksum: UInt32 {
    withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, UInt32(count))) }
  }

  mutating func updateHeaderChecksum() {
    setUInt32(0, at: GPTHeader.checksumOffset)
    setUInt32(prefix(GPTHeader.size).crc32Checksum, at: GPTHeader.checksumOffset)
  }
}
