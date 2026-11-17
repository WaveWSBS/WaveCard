import Foundation
import CoreFoundation

// PropertyListSerialization preserves binary NSKeyedArchiver references as
// opaque CF UID values. Resolve references without instantiating archived classes.
@_silgen_name("_CFKeyedArchiverUIDGetTypeID")
private func walletUIDTypeID() -> CFTypeID
@_silgen_name("_CFKeyedArchiverUIDGetValue")
private func walletUIDValue(_ uid: CFTypeRef) -> UInt32

/// Names for passes already observed on the connected device. The Mac cache is
/// a naming aid, not an authoritative inventory of cards on an iPhone.
public enum WalletMetadataCatalog {
    public static func names(
        root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Passes"),
        product: String,
        confirmedIDs: Set<String>
    ) -> [String: String] {
        let confirmed = Set(confirmedIDs.filter(validID))
        guard !confirmed.isEmpty else { return [:] }
        var names: [String: String] = [:]
        for instrument in matchedPaymentInstruments(root: root, product: product, confirmed: confirmed) {
            guard let id = instrument["passID"] as? String, confirmed.contains(id),
                  let name = cleanName(instrument["displayName"]) ?? cleanName(instrument["organizationName"]) else { continue }
            if names[id] == nil { names[id] = name }
        }
        for id in confirmed where names[id] == nil {
            guard let metadata = nonPaymentMetadata(root: root, id: id) else { continue }
            var parts: [String] = []
            for value in [metadata["organizationName"], metadata["description"]] {
                if let name = cleanName(value), !parts.contains(name) { parts.append(name) }
            }
            if !parts.isEmpty { names[id] = String(parts.joined(separator: " · ").prefix(200)) }
        }
        return names
    }

    /// IDs whose local pass.json declares a non-payment style (ticket, generic
    /// ID, boarding pass...). Such passes never carry cardBackgroundCombined
    /// bank artwork, so probing the phone for it only costs AirTraffic syncs.
    /// Payment passes keep no pass.json on the Mac and are never matched.
    public static func nonPaymentPassIDs(
        root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Passes"),
        ids: Set<String>
    ) -> Set<String> {
        Set(ids.filter { validID($0) && nonPaymentMetadata(root: root, id: $0) != nil })
    }

    private static let nonPaymentStyles = ["generic", "storeCard", "boardingPass", "eventTicket", "coupon"]

    private static func nonPaymentMetadata(root: URL, id: String) -> [String: Any]? {
        let file = root.appendingPathComponent("Cards", isDirectory: true)
            .appendingPathComponent(id + ".pkpass", isDirectory: true).appendingPathComponent("pass.json")
        guard let bytes = read(file, beneath: root, limit: 1024 * 1024),
              let metadata = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              nonPaymentStyles.contains(where: { metadata[$0] is [String: Any] }) else { return nil }
        return metadata
    }

    /// Exact remote instrument -> thumbnail identity. Only a uniquely matched
    /// device can supply these hashes; no cache file is an inventory entry.
    static func paymentManifestHashes(root: URL, product: String, confirmedIDs: Set<String>) -> [String: Data] {
        let confirmed = Set(confirmedIDs.filter(validID))
        guard !confirmed.isEmpty else { return [:] }
        var result: [String: Data] = [:]
        for instrument in matchedPaymentInstruments(root: root, product: product, confirmed: confirmed, allowAnyProduct: product.isEmpty) {
            guard let id = instrument["passID"] as? String, confirmed.contains(id),
                  let hash = instrument["manifestHash"] as? Data, hash.count == 20 else { continue }
            if let previous = result[id], previous != hash { return [:] }
            result[id] = hash
        }
        return result
    }

    private static func matchedPaymentInstruments(root: URL, product: String, confirmed: Set<String>, allowAnyProduct: Bool = false) -> [[String: Any]] {
        // XML parsing can coerce fractional CF$UID references before validation.
        // Wallet uses binary archives, which preserve their original UID types.
        guard let bytes = read(root.appendingPathComponent("RemoteDevices.archive"), beneath: root, limit: 16 * 1024 * 1024),
              bytes.starts(with: Data("bplist00".utf8)),
              let archive = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
              let devices = try? ArchiveDecoder(archive).decode() as? [[String: Any]] else { return [] }
        let matches = devices.filter { device in
            // Offline previews still belong to an iPhone. A paired Watch can
            // share known cards and must not make the phone's image ambiguous.
            guard let model = device["modelIdentifier"] as? String,
                  allowAnyProduct ? model.hasPrefix("iPhone") : model == product,
                  let instruments = device["remotePaymentInstruments"] as? [[String: Any]] else { return false }
            return instruments.contains { instrument in
                guard let id = instrument["passID"] as? String else { return false }
                return confirmed.contains(id)
            }
        }
        guard matches.count == 1 else { return [] }
        return matches[0]["remotePaymentInstruments"] as? [[String: Any]] ?? []
    }

    private static let identifierCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_+=-")

    private static func validID(_ value: String) -> Bool {
        guard (20...44).contains(value.count), !(value.count == 36 && value.contains("-")) else { return false }
        return value.unicodeScalars.allSatisfy { identifierCharacters.contains($0) }
    }

    private static func cleanName(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let cleaned = value.components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(200))
    }

    private static func read(_ file: URL, beneath root: URL, limit: Int) -> Data? {
        let root = root.standardizedFileURL
        let file = file.standardizedFileURL
        guard file.path.hasPrefix(root.path + "/") else { return nil }
        var current = file
        while true {
            guard let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]),
                  values.isSymbolicLink == false else { return nil }
            if current == root { break }
            let parent = current.deletingLastPathComponent()
            guard parent != current else { return nil }
            current = parent
        }
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: limit + 1), bytes.count <= limit else { return nil }
        return bytes
    }

    private final class ArchiveDecoder {
        private let objects: [Any]
        private let root: Any
        private var memo: [Int: Any] = [:]
        private var remainingNodes = 200_000
        private enum Invalid: Error { case archive }

        init(_ archive: [String: Any]) throws {
            guard let objects = archive["$objects"] as? [Any], objects.count <= 100_000,
                  let top = archive["$top"] as? [String: Any], let root = top["root"] else { throw Invalid.archive }
            self.objects = objects
            self.root = root
        }

        func decode() throws -> Any { try resolve(root, trail: [], depth: 0) }

        private func index(_ value: Any) throws -> Int? {
            if CFGetTypeID(value as CFTypeRef) == walletUIDTypeID() {
                return Int(walletUIDValue(value as CFTypeRef))
            }
            if let dictionary = value as? [String: Any], let raw = dictionary["CF$UID"] {
                guard dictionary.count == 1, let number = raw as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue >= 0,
                      number.doubleValue < Double(Int.max), number.doubleValue.rounded(.towardZero) == number.doubleValue else { throw Invalid.archive }
                return number.intValue
            }
            return nil
        }

        private func resolve(_ value: Any, trail: Set<Int>, depth: Int) throws -> Any {
            remainingNodes -= 1
            guard remainingNodes >= 0, depth <= 40 else { throw Invalid.archive }
            if let i = try index(value) {
                guard objects.indices.contains(i), !trail.contains(i) else { throw Invalid.archive }
                if let cached = memo[i] { return cached }
                var next = trail; next.insert(i)
                let result = try resolve(objects[i], trail: next, depth: depth + 1)
                memo[i] = result
                return result
            }
            if let dictionary = value as? [String: Any] {
                if let raw = dictionary["NS.objects"] {
                    guard let raw = raw as? [Any] else { throw Invalid.archive }
                    let values = try raw.map { try resolve($0, trail: trail, depth: depth + 1) }
                    if let rawKeys = dictionary["NS.keys"] {
                        guard let rawKeys = rawKeys as? [Any], rawKeys.count == values.count else { throw Invalid.archive }
                        var result: [String: Any] = [:]
                        for (key, value) in zip(rawKeys, values) {
                            guard let key = try resolve(key, trail: trail, depth: depth + 1) as? String else { throw Invalid.archive }
                            result[key] = value
                        }
                        return result
                    }
                    return values
                }
                var result: [String: Any] = [:]
                for (key, value) in dictionary where !key.hasPrefix("$") {
                    result[key] = try resolve(value, trail: trail, depth: depth + 1)
                }
                return result
            }
            if let array = value as? [Any] { return try array.map { try resolve($0, trail: trail, depth: depth + 1) } }
            return (value as? String) == "$null" ? NSNull() : value
        }
    }
}
