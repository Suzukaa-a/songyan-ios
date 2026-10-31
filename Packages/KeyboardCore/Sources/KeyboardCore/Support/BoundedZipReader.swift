import Compression
import Foundation

// MARK: - Minimal read-only ZIP reader
//
// Reads only what a folder of snapshots zipped by Finder, Files or another Rime front-end needs:
// stored and deflated entries, no encryption, no ZIP64, no multi-disk archives. Anything else throws,
// so a damaged or unusual archive is refused as a whole. Every size comes from the central directory
// and is checked against the caller's bound before any bytes are inflated; the inflated length and
// CRC-32 must match, so a lying header cannot make the reader allocate or accept more than declared.

public struct BoundedZipReader: Sendable {
    public struct Entry: Equatable, Sendable {
        public let path: String
        public let isDirectory: Bool
        public let uncompressedSize: Int
        fileprivate let method: UInt16
        fileprivate let crc32: UInt32
        fileprivate let compressedSize: Int
        fileprivate let localHeaderOffset: Int
    }

    public enum Failure: Error, Equatable, Sendable {
        case notAnArchive
        case unsupported
        case tooManyEntries
        case entryTooLarge
        case corrupt
    }

    public static let magic: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
    public static let maximumEntries = 4_096

    public let entries: [Entry]
    private let data: Data

    /// Parses the central directory of `data`.
    public init(data: Data) throws {
        self.data = Data(data)  // re-base indices to 0
        guard self.data.count >= 22, self.data.starts(with: Self.magic) else { throw Failure.notAnArchive }
        let end = try Self.endOfCentralDirectory(self.data)
        let count = Int(Self.u16(self.data, end + 10))
        let directorySize = Int(Self.u32(self.data, end + 12))
        let directoryOffset = Int(Self.u32(self.data, end + 16))
        guard Self.u16(self.data, end + 4) == 0, Self.u16(self.data, end + 6) == 0 else { throw Failure.unsupported }
        guard count != 0xFFFF, directorySize != 0xFFFF_FFFF, directoryOffset != 0xFFFF_FFFF else {
            throw Failure.unsupported
        }
        guard count <= Self.maximumEntries else { throw Failure.tooManyEntries }
        guard directoryOffset >= 0, directorySize >= 0, directoryOffset + directorySize <= end else {
            throw Failure.corrupt
        }
        var cursor = directoryOffset
        var found: [Entry] = []
        found.reserveCapacity(count)
        for _ in 0..<count {
            guard cursor + 46 <= end, Self.u32(self.data, cursor) == 0x0201_4B50 else { throw Failure.corrupt }
            let flags = Self.u16(self.data, cursor + 8)
            let method = Self.u16(self.data, cursor + 10)
            let crc = Self.u32(self.data, cursor + 16)
            let compressed = Self.u32(self.data, cursor + 20)
            let size = Self.u32(self.data, cursor + 24)
            let nameLength = Int(Self.u16(self.data, cursor + 28))
            let extraLength = Int(Self.u16(self.data, cursor + 30))
            let commentLength = Int(Self.u16(self.data, cursor + 32))
            let offset = Self.u32(self.data, cursor + 42)
            let nameStart = cursor + 46
            guard nameStart + nameLength + extraLength + commentLength <= end else { throw Failure.corrupt }
            guard flags & 0x0001 == 0, compressed != 0xFFFF_FFFF, size != 0xFFFF_FFFF, offset != 0xFFFF_FFFF,
                method == 0 || method == 8
            else { throw Failure.unsupported }
            let nameBytes = self.data[nameStart..<(nameStart + nameLength)]
            // Bit 11 declares UTF-8; otherwise names are CP437, which only matters for display.
            guard
                let path = String(data: nameBytes, encoding: .utf8)
                    ?? String(data: nameBytes, encoding: .isoLatin1)
            else { throw Failure.corrupt }
            found.append(
                Entry(
                    path: path, isDirectory: path.hasSuffix("/"), uncompressedSize: Int(size),
                    method: method, crc32: crc, compressedSize: Int(compressed),
                    localHeaderOffset: Int(offset)))
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        entries = found
    }

    /// Inflates one entry, refusing anything larger than `limit` before touching its bytes.
    public func contents(of entry: Entry, limit: Int) throws -> Data {
        guard !entry.isDirectory else { throw Failure.corrupt }
        guard entry.uncompressedSize <= limit else { throw Failure.entryTooLarge }
        let header = entry.localHeaderOffset
        guard header >= 0, header + 30 <= data.count, Self.u32(data, header) == 0x0403_4B50 else {
            throw Failure.corrupt
        }
        let start = header + 30 + Int(Self.u16(data, header + 26)) + Int(Self.u16(data, header + 28))
        guard start >= 0, start + entry.compressedSize <= data.count else { throw Failure.corrupt }
        let payload = data[start..<(start + entry.compressedSize)]
        let output: Data
        switch entry.method {
        case 0:
            guard entry.compressedSize == entry.uncompressedSize else { throw Failure.corrupt }
            output = Data(payload)
        default:
            output = try Self.inflate(payload, expected: entry.uncompressedSize)
        }
        guard Self.crc32(output) == entry.crc32 else { throw Failure.corrupt }
        return output
    }

    // MARK: Internals

    private static func inflate(_ payload: Data, expected: Int) throws -> Data {
        if expected == 0 { return Data() }
        var output = Data(count: expected)
        let written: Int = output.withUnsafeMutableBytes { destination in
            payload.withUnsafeBytes { source in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                    let sourceBase = source.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                // COMPRESSION_ZLIB is raw deflate, which is what ZIP stores.
                return compression_decode_buffer(
                    destinationBase, expected, sourceBase, payload.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expected else { throw Failure.corrupt }
        return output
    }

    private static func endOfCentralDirectory(_ data: Data) throws -> Int {
        // The record is 22 bytes plus a comment of at most 65535 bytes.
        let lowest = max(0, data.count - 22 - 0xFFFF)
        var index = data.count - 22
        while index >= lowest {
            if u32(data, index) == 0x0605_4B50, index + 22 + Int(u16(data, index + 20)) == data.count {
                return index
            }
            index -= 1
        }
        throw Failure.corrupt
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(u16(data, offset)) | UInt32(u16(data, offset + 2)) << 16
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xFFFF_FFFF
        for byte in data { value = crcTable[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8) }
        return value ^ 0xFFFF_FFFF
    }
}
