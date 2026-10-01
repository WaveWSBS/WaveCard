import Foundation
import zlib

/// Pure Swift implementation of Apple Zip format & Airlift Books plist generation.
/// Zero Python / zero external library dependency.
public struct AirliftZipEntry {
    public let name: String
    public let data: Data
    public let mode: UInt32
    public let isDirectory: Bool

    public init(name: String, data: Data = Data(), mode: UInt32, isDirectory: Bool = false) {
        self.name = name
        self.data = data
        self.mode = mode
        self.isDirectory = isDirectory
    }
}

public enum AirliftZip {
    private static let SZ_EXTRA_ID: UInt16 = 0x5A53
    private static let dosTime: UInt16 = (5 << 11) // 05:00:00
    private static let dosDate: UInt16 = UInt16(((2026 - 1980) << 9) | (9 << 5) | 14) // 2026-09-14

    /// Builds uncompressed PKZip archive with Apple permission extra attributes (SZ_EXTRA_ID).
    public static func buildZip(entries: [AirliftZipEntry]) -> Data {
        var output = Data()
        var centralDirectory = Data()

        for entry in entries {
            let localHeaderOffset = UInt32(output.count)
            let nameData = entry.name.data(using: .utf8) ?? Data()
            let nameLength = UInt16(nameData.count)

            let crc: UInt32
            if entry.data.isEmpty {
                crc = 0
            } else {
                crc = UInt32(entry.data.withUnsafeBytes { ptr in
                    crc32(0, ptr.baseAddress?.assumingMemoryBound(to: Bytef.self), uInt(entry.data.count))
                })
            }
            let dataLength = UInt32(entry.data.count)

            // Extra field: SZ_EXTRA_ID (2 bytes) + len (2 bytes) + mode & 0xFFFF (2 bytes)
            var extra = Data()
            var extraId = SZ_EXTRA_ID.littleEndian
            var extraLen = UInt16(2).littleEndian
            var modeField = UInt16(entry.mode & 0xFFFF).littleEndian
            extra.append(Data(bytes: &extraId, count: 2))
            extra.append(Data(bytes: &extraLen, count: 2))
            extra.append(Data(bytes: &modeField, count: 2))
            let extraLength = UInt16(extra.count)

            // Local file header (30 bytes + name + extra)
            var lh = Data()
            var sig: UInt32 = 0x04034b50
            var ver: UInt16 = 20
            var flags: UInt16 = 0
            var method: UInt16 = 0 // Stored
            var time = dosTime.littleEndian
            var date = dosDate.littleEndian
            var crcLE = crc.littleEndian
            var cSize = dataLength.littleEndian
            var ucSize = dataLength.littleEndian
            var nLen = nameLength.littleEndian
            var eLen = extraLength.littleEndian

            lh.append(Data(bytes: &sig, count: 4))
            lh.append(Data(bytes: &ver, count: 2))
            lh.append(Data(bytes: &flags, count: 2))
            lh.append(Data(bytes: &method, count: 2))
            lh.append(Data(bytes: &time, count: 2))
            lh.append(Data(bytes: &date, count: 2))
            lh.append(Data(bytes: &crcLE, count: 4))
            lh.append(Data(bytes: &cSize, count: 4))
            lh.append(Data(bytes: &ucSize, count: 4))
            lh.append(Data(bytes: &nLen, count: 2))
            lh.append(Data(bytes: &eLen, count: 2))
            lh.append(nameData)
            lh.append(extra)

            output.append(lh)
            output.append(entry.data)

            // Central directory entry (46 bytes + name + extra)
            var cd = Data()
            var cdSig: UInt32 = 0x02014b50
            var verMade: UInt16 = (3 << 8) | 20 // UNIX + v2.0
            var extAttr: UInt32 = UInt32((entry.mode & 0xFFFF) << 16).littleEndian
            var relOffset = localHeaderOffset.littleEndian
            var zero16: UInt16 = 0

            cd.append(Data(bytes: &cdSig, count: 4))
            cd.append(Data(bytes: &verMade, count: 2))
            cd.append(Data(bytes: &ver, count: 2))
            cd.append(Data(bytes: &flags, count: 2))
            cd.append(Data(bytes: &method, count: 2))
            cd.append(Data(bytes: &time, count: 2))
            cd.append(Data(bytes: &date, count: 2))
            cd.append(Data(bytes: &crcLE, count: 4))
            cd.append(Data(bytes: &cSize, count: 4))
            cd.append(Data(bytes: &ucSize, count: 4))
            cd.append(Data(bytes: &nLen, count: 2))
            cd.append(Data(bytes: &eLen, count: 2))
            cd.append(Data(bytes: &zero16, count: 2)) // comment len
            cd.append(Data(bytes: &zero16, count: 2)) // disk start
            cd.append(Data(bytes: &zero16, count: 2)) // int attrs
            cd.append(Data(bytes: &extAttr, count: 4))
            cd.append(Data(bytes: &relOffset, count: 4))
            cd.append(nameData)
            cd.append(extra)

            centralDirectory.append(cd)
        }

        let cdOffset = UInt32(output.count)
        let cdSize = UInt32(centralDirectory.count)
        output.append(centralDirectory)

        // End of central directory record (22 bytes)
        var eocd = Data()
        var eocdSig: UInt32 = 0x06054b50
        var zero16: UInt16 = 0
        var count16 = UInt16(entries.count).littleEndian
        var cdSizeLE = cdSize.littleEndian
        var cdOffsetLE = cdOffset.littleEndian

        eocd.append(Data(bytes: &eocdSig, count: 4))
        eocd.append(Data(bytes: &zero16, count: 2))
        eocd.append(Data(bytes: &zero16, count: 2))
        eocd.append(Data(bytes: &count16, count: 2))
        eocd.append(Data(bytes: &count16, count: 2))
        eocd.append(Data(bytes: &cdSizeLE, count: 4))
        eocd.append(Data(bytes: &cdOffsetLE, count: 4))
        eocd.append(Data(bytes: &zero16, count: 2))

        output.append(eocd)
        return output
    }

    /// Builds single-payload Airlift ZIP archive.
    public static func buildArchive(target: String, payload: Data) throws -> Data {
        let metadata = try PropertyListSerialization.data(
            fromPropertyList: ["Version": 2],
            format: .binary,
            options: 0
        )
        let targetTail = target.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var entries: [AirliftZipEntry] = []

        // META-INF
        entries.append(AirliftZipEntry(name: "META-INF/", mode: 0o40755, isDirectory: true))
        entries.append(AirliftZipEntry(name: "META-INF/com.apple.ZipMetadata.plist", data: metadata, mode: 0o100600))

        // Intermediate directories
        entries.append(AirliftZipEntry(name: "p0/", mode: 0o40755, isDirectory: true))
        entries.append(AirliftZipEntry(name: "p0/p1/", mode: 0o40755, isDirectory: true))
        entries.append(AirliftZipEntry(name: "p0/p1/p2/", mode: 0o40755, isDirectory: true))

        // Symlink pointing to target
        let linkData = "../../../\(targetTail)".data(using: .utf8) ?? Data()
        entries.append(AirliftZipEntry(name: "p0/p1/p2/link", data: linkData, mode: 0o120777))

        // Target directory path components
        var cursor = ""
        for component in targetTail.components(separatedBy: "/") {
            guard !component.isEmpty else { continue }
            cursor += component + "/"
            entries.append(AirliftZipEntry(name: cursor, mode: 0o40755, isDirectory: true))
        }

        // Payload
        entries.append(AirliftZipEntry(name: "payload", data: payload, mode: 0o100600))

        return buildZip(entries: entries)
    }

    /// Builds multi-payload Airlift ZIP archive for batch flashing.
    public static func buildArchiveMulti(target: String, files: [(leaf: String, payload: Data)]) throws -> Data {
        let metadata = try PropertyListSerialization.data(
            fromPropertyList: ["Version": 2],
            format: .binary,
            options: 0
        )
        let targetTail = target.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var entries: [AirliftZipEntry] = []

        // META-INF
        entries.append(AirliftZipEntry(name: "META-INF/", mode: 0o40755, isDirectory: true))
        entries.append(AirliftZipEntry(name: "META-INF/com.apple.ZipMetadata.plist", data: metadata, mode: 0o100600))

        // Intermediate directories
        entries.append(AirliftZipEntry(name: "p0/", mode: 0o40755, isDirectory: true))
        entries.append(AirliftZipEntry(name: "p0/p1/", mode: 0o40755, isDirectory: true))
        entries.append(AirliftZipEntry(name: "p0/p1/p2/", mode: 0o40755, isDirectory: true))

        // Symlink
        let linkData = "../../../\(targetTail)".data(using: .utf8) ?? Data()
        entries.append(AirliftZipEntry(name: "p0/p1/p2/link", data: linkData, mode: 0o120777))

        // Target directories
        var cursor = ""
        for component in targetTail.components(separatedBy: "/") {
            guard !component.isEmpty else { continue }
            cursor += component + "/"
            entries.append(AirliftZipEntry(name: cursor, mode: 0o40755, isDirectory: true))
        }

        // Multiple payloads
        for (idx, file) in files.enumerated() {
            entries.append(AirliftZipEntry(name: "payload_\(idx)", data: file.payload, mode: 0o100600))
        }
        if let first = files.first {
            entries.append(AirliftZipEntry(name: "payload", data: first.payload, mode: 0o100600))
        }

        return buildZip(entries: entries)
    }

    /// Builds binary Books.plist for AirTraffic sync relocation.
    public static func buildBooks(identifiers: [String]) throws -> Data {
        let rows = identifiers.enumerated().map { index, identifier in
            [
                "Persistent ID": identifier,
                "Item ID": String(index + 1),
                "DSID": "1"
            ]
        }
        let dict = ["Books": rows]
        return try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
    }
}
