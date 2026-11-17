import Foundation

@main
struct WalletMetadataCatalogTest {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("wavecard-wallet-names-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let a = "AAAAAAAAAAAAAAAAAAAAAAAAAAA="
        let b = "BBBBBBBBBBBBBBBBBBBBBBBBBBB="
        let c = "CCCCCCCCCCCCCCCCCCCCCCCCCCC="
        let d = "DDDDDDDDDDDDDDDDDDDDDDDDDDD="
        let e = "EEEEEEEEEEEEEEEEEEEEEEEEEEE="
        let f = "FFFFFFFFFFFFFFFFFFFFFFFFFFF="
        let product = "iPhone18,2"
        let archive = root.appendingPathComponent("RemoteDevices.archive")
        var failures = 0
        var assertions = 0
        func expect(_ condition: Bool, _ message: String) {
            assertions += 1
            print("\(condition ? "ok" : "not ok") - \(message)")
            if !condition { failures += 1 }
        }
        func instrument(_ id: String, _ name: Any) -> [String: Any] {
            ["passID": id, "displayName": name]
        }
        func device(_ ids: [[String: Any]], model: String = "iPhone18,2") -> [String: Any] {
            ["modelIdentifier": model, "remotePaymentInstruments": ids]
        }
        func writeArchive(_ devices: [[String: Any]]) throws {
            try NSKeyedArchiver.archivedData(withRootObject: devices, requiringSecureCoding: true).write(to: archive)
        }
        func names(_ ids: Set<String> = [a, b]) -> [String: String] {
            WalletMetadataCatalog.names(root: root, product: product, confirmedIDs: ids)
        }
        func metadata(_ id: String, _ dictionary: [String: Any]) throws -> URL {
            let directory = root.appendingPathComponent("Cards/\(id).pkpass")
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("pass.json")
            try JSONSerialization.data(withJSONObject: dictionary).write(to: file)
            return file
        }

        expect(names().isEmpty, "missing cache leaves names unavailable")
        try writeArchive([device([instrument(a, "  HSBC fixture  "), instrument(b, "Second card"), instrument(c, "Unobserved")])])
        expect(names() == [a: "HSBC fixture", b: "Second card"], "native binary UID archive yields names for confirmed IDs only")
        expect(names([]).isEmpty, "empty confirmation never imports a cache inventory")
        expect(names([d]).isEmpty, "matching model alone is insufficient without an observed ID overlap")
        try writeArchive([device([instrument(a, "Wrong model")], model: "iPhone17,1")])
        expect(names().isEmpty, "another device model cannot supply payment names")
        try writeArchive([device([instrument(a, "First phone")]), device([instrument(a, "Second phone")])])
        expect(names().isEmpty, "two overlapping cached devices withhold ambiguous payment names")
        try writeArchive([device([instrument(a, "This phone")]), device([instrument(c, "Other phone")])])
        expect(names() == [a: "This phone"], "one observed overlap disambiguates multiple devices of the same model")
        try writeArchive([device([["passID": a, "displayName": " \n", "organizationName": "Fallback bank"], instrument(b, 42)])])
        expect(names() == [a: "Fallback bank"], "blank display names fall back to organization and malformed names are ignored")
        try writeArchive([device([instrument(a, String(repeating: "X", count: 300)), instrument(b, "Line\nBreak")])])
        expect(names()[a]?.count == 200 && names()[b] == "Line Break", "names are bounded and control characters cannot inject console lines")

        // Explicit CF$UID dictionaries exercise malformed graphs in binary plists.
        func graph(_ objects: [Any], rootReference: Any = ["CF$UID": 1]) throws {
            let graph: [String: Any] = ["$objects": objects, "$top": ["root": rootReference]]
            try PropertyListSerialization.data(fromPropertyList: graph, format: .binary, options: 0).write(to: archive)
        }
        try graph(["$null", [device([instrument(a, "Dictionary bank")])]])
        expect(names() == [a: "Dictionary bank"], "explicit dictionary UID references resolve without unarchiving classes")
        let xmlArchive: [String: Any] = ["$objects": ["$null", [device([instrument(a, "XML bank")])]], "$top": ["root": ["CF$UID": 1.5]]]
        try PropertyListSerialization.data(fromPropertyList: xmlArchive, format: .xml, options: 0).write(to: archive)
        expect(names().isEmpty, "XML archives cannot silently coerce fractional UID references")
        try graph(["$null", ["CF$UID": 1]])
        expect(names().isEmpty, "cyclic archive references are rejected")
        try graph(["$null"], rootReference: ["CF$UID": 999])
        expect(names().isEmpty, "out of bounds references are rejected")
        try graph(["$null", [device([instrument(a, "Invalid")])]], rootReference: ["CF$UID": -1])
        expect(names().isEmpty, "negative references are rejected")
        try graph(["$null", [device([instrument(a, "Invalid")])]], rootReference: ["CF$UID": true])
        expect(names().isEmpty, "boolean references are rejected")
        try graph(["$null", [device([instrument(a, "Invalid")])]], rootReference: ["CF$UID": 1.5])
        expect(names().isEmpty, "fractional references are rejected")
        var deep: Any = [device([instrument(a, "Too deep")])]
        for _ in 0..<50 { deep = [deep] }
        try graph(["$null", deep])
        expect(names().isEmpty, "excessive archive nesting is rejected")
        try Data(repeating: 0, count: 16 * 1024 * 1024 + 1).write(to: archive)
        expect(names().isEmpty, "archive read limit rejects oversized data")
        try Data("not a plist".utf8).write(to: archive)
        expect(names().isEmpty, "malformed archive does not interrupt local ticket metadata lookup")

        let ticket = try metadata(a, ["organizationName": "Cvent fixture", "description": "Admission", "eventTicket": [:]])
        expect(names() == [a: "Cvent fixture · Admission"], "confirmed event ticket names combine issuer and description")
        _ = try metadata(b, ["organizationName": "Same", "description": "Same", "generic": [:]])
        expect(names()[b] == "Same", "repeated local labels are not duplicated")
        _ = try metadata(c, ["organizationName": "Unconfirmed ticket", "eventTicket": [:]])
        expect(names()[c] == nil, "local cache entries are never added without confirmation")
        _ = try metadata(d, ["organizationName": "No supported pass style"])
        expect(names([d]).isEmpty, "metadata without a supported nonpayment pass style is ignored")
        _ = try metadata(e, ["organizationName": "Malformed style", "eventTicket": "invalid"])
        expect(names([e]).isEmpty, "invalid pass style values are ignored")
        expect(names(["../" + a]).isEmpty, "unsafe card IDs cannot become filesystem paths")
        try writeArchive([device([instrument(a, "Payment takes precedence")])])
        expect(names()[a] == "Payment takes precedence", "device-matched payment names take precedence over local pass metadata")
        try fm.removeItem(at: archive)
        let outside = root.appendingPathComponent("outside.json")
        try Data("{\"organizationName\":\"Linked data\",\"eventTicket\":{}}".utf8).write(to: outside)
        try fm.removeItem(at: ticket)
        try fm.createSymbolicLink(at: ticket, withDestinationURL: outside)
        expect(names()[a] == nil, "symlinked pass metadata is not followed")
        let unknownPayment = "GGGGGGGGGGGGGGGGGGGGGGGGGGG="
        expect(WalletMetadataCatalog.nonPaymentPassIDs(root: root, ids: [a, b, c, d, e, unknownPayment]) == [b, c],
               "only real pass.json files with a non-payment style are skipped; symlinked metadata and payment passes are kept")
        expect(WalletMetadataCatalog.nonPaymentPassIDs(root: root, ids: ["../escape", ""]).isEmpty, "invalid ids are never resolved")
        let linkedDirectory = root.appendingPathComponent("Cards/\(f).pkpass")
        try fm.createSymbolicLink(at: linkedDirectory, withDestinationURL: ticket.deletingLastPathComponent())
        expect(names([f]).isEmpty, "symlinked pass bundles are not followed")
        expect(WalletMetadataCatalog.nonPaymentPassIDs(root: root, ids: [f]).isEmpty, "symlinked pass bundles are not classified")
        let archiveTarget = root.appendingPathComponent("other.archive")
        try NSKeyedArchiver.archivedData(withRootObject: [device([instrument(a, "Linked bank")])], requiringSecureCoding: true).write(to: archiveTarget)
        try fm.createSymbolicLink(at: archive, withDestinationURL: archiveTarget)
        expect(names()[a] == nil, "symlinked remote archives are not followed")
        try fm.removeItem(at: archive)
        try fm.removeItem(at: ticket)
        try Data(repeating: 0, count: 1024 * 1024 + 1).write(to: ticket)
        expect(names()[a] == nil, "ticket metadata is bounded to one MiB")
        print("\(assertions) assertions, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
