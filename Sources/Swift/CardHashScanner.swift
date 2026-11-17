import Foundation

/// Pulls Apple Wallet pass identifiers out of a syslog line.
///
/// Pass ids look like `Coza99TKbpVUZHdDTiu7KMFfhds=` (about 28 characters,
/// base64 with `-`/`_`). A path such as `/Library/Passes/Cards/<id>.pkpass`
/// must yield only `<id>`. The id charset deliberately excludes `/`.
public enum CardHashScanner {
    private static let identifier = #"([-A-Za-z0-9_+=]{20,44})"#
    private static let identifierEnd = #"(?![-A-Za-z0-9_+=/])"#
    private static let recordPaths: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"/(?:Cards|Passes/Cards)/"# + identifier + #"(?:\.(?:pkpass|cache|pkcache)(?=[/\s\"'),]|$)|(?=[/\s\"'),]|$))"#),
        try! NSRegularExpression(pattern: #"/"# + identifier + #"\.(?:pkpass|cache|pkcache)(?=[/\s\"'),]|$)"#),
    ]
    private static let structuredReferences: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"PDCardFileManager:\s*writing card\s+"# + identifier + identifierEnd, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"PDPassLibrary:\s*wrote pass\s+"# + identifier + identifierEnd, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"VerificationCheck\."# + identifier + identifierEnd, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"selected pass uniqueID\s*:\s*\"?"# + identifier + identifierEnd, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"Dashboard loading[^:\r\n]*:\s*for\s+"# + identifier + identifierEnd, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"Dashboard loading[^:\r\n]*:\s+"# + identifier + #"\s+-"#, options: .caseInsensitive),
    ]
    private static let passList = try! NSRegularExpression(
        pattern: #"passIDs\[(?:InSession|global)\]\s*:\s*(?:\{\s*)?\(([^)]*)\)"#,
        options: .caseInsensitive
    )
    private static let legacyIdentifier = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9+/_=-])([A-Za-z0-9+/_-]{27}=)(?![A-Za-z0-9+/_=-])"#
    )
    private static let legacyContext = try! NSRegularExpression(
        pattern: #"\b(?:card|pass|payment|wallet|face|cache|stockholm)\b|passUniqueID"#,
        options: .caseInsensitive
    )
    private static let walletProcesses: Set<String> = [
        "passd", "nanopassd", "nfcd", "passbook", "wallet", "walletuiservice",
        "passbookuiservice", "pdcardfilemanager", "pdpasslibrary",
    ]

    /// Identifiers in one complete `process(image): message` syslog record.
    /// NFC applet identifiers are deliberately not pass identifiers. Quoted
    /// continuation lines are accepted only inside a named Wallet passIDs list.
    public static func detectedPassIDs(inRecord record: String) -> [String] {
        let firstLine = String(record.prefix { $0 != "\n" && $0 != "\r" })
        let header = String(firstLine.prefix { $0 != ":" }).lowercased()
        let process = String(header.prefix { $0 != "(" && $0 != "[" })
            .trimmingCharacters(in: .whitespaces)
        let processName = (process as NSString).lastPathComponent
        let module = header.split(separator: "(", maxSplits: 1).dropFirst().first
            .map { String($0.prefix { $0 != ")" }) } ?? ""
        let walletModule = ["passkit", "passbook", "wallet", "stockholm"]
            .contains { module.hasPrefix($0) }
        let trusted = walletProcesses.contains(processName) || walletModule
        let strongPath = record.contains("/Library/Passes/Cards/")
        guard trusted || strongPath else { return [] }

        let fullRange = NSRange(record.startIndex..., in: record)
        var found: [(Int, String)] = []
        func collect(_ regex: NSRegularExpression, in text: String, offset: Int = 0) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let value = String(text[range])
                if isValid(value) { found.append((offset + match.range(at: 1).location, value)) }
            }
        }
        // An untrusted origin can establish context only through the full path.
        if trusted {
            for regex in recordPaths { collect(regex, in: record) }
            for regex in structuredReferences { collect(regex, in: record) }
            for match in passList.matches(in: record, range: fullRange) {
                guard let range = Range(match.range(at: 1), in: record) else { continue }
                let contents = String(record[range])
                // Keep parsing inside the actual list, never arbitrary quoted
                // NFC fields before or after it.
                let items = contents.components(separatedBy: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
                    .filter { !$0.isEmpty }
                var listValues: [String] = []
                var validList = true
                for item in items {
                    if item == "<private>" || item == "<redacted>" { continue }
                    var value = item
                    if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                        value = String(value.dropFirst().dropLast())
                    }
                    guard isValid(value) else { validList = false; break }
                    listValues.append(value)
                }
                if validList {
                    found += listValues.enumerated().map { (match.range(at: 1).location + $0.offset, $0.element) }
                }
            }
        } else {
            let fullPath = try! NSRegularExpression(pattern:
                #"/Library/Passes/Cards/"# + identifier + #"(?:\.(?:pkpass|cache|pkcache)(?=[/\s\"'),]|$)|(?=[/\s\"'),]|$))"#)
            collect(fullPath, in: record)
        }
        if !found.isEmpty { return orderedUnique(found) }

        let lower = record.lowercased()
        // A named but redacted/malformed field must not fall through to a
        // different base64-looking value elsewhere in the record.
        let structuredMarkers = ["/cards/", ".pkpass", ".pkcache", ".cache", "pdcardfilemanager:",
            "pdpasslibrary:", "verificationcheck.", "selected pass uniqueid", "dashboard loading",
            "passids", "setactivepaymentapplet", "requestedapplet"]
        guard trusted, processName != "nfcd", !module.hasPrefix("nearfield"),
              !structuredMarkers.contains(where: lower.contains),
              !lower.contains("<private>"), !lower.contains("<redacted>") else { return [] }
        let body = record.firstIndex(of: ":").map { String(record[record.index(after: $0)...]) } ?? ""
        guard legacyContext.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) != nil else { return [] }
        collect(legacyIdentifier, in: record)
        return orderedUnique(found)
    }

    private static func orderedUnique(_ values: [(Int, String)]) -> [String] {
        var seen = Set<String>()
        return values.sorted { $0.0 < $1.0 }.compactMap { seen.insert($0.1).inserted ? $0.1 : nil }
    }

    private static let patterns: [NSRegularExpression] = [
        try! NSRegularExpression(
            pattern: #"/(?:Cards|Passes/Cards)/([-A-Za-z0-9_+=]{20,44})(?:\.pkpass|\.cache|\.pkcache|/|\s|["'),]|$)"#,
            options: []
        ),
        try! NSRegularExpression(
            pattern: #"/([-A-Za-z0-9_+=]{20,44})\.(?:pkpass|cache|pkcache)"#,
            options: []
        ),
        try! NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9+/_-])([A-Za-z0-9+/_-]{27}=)(?![A-Za-z0-9+/_-])"#,
            options: []
        ),
    ]

    /// Known non-card tokens and stock sample ids that show up in passd logs.
    private static let blocked: Set<String> = [
        "PaymentCards", "Cards", "Passes", "Library", "Payment", "Passbook", "passd",
        "M6nDwZrkYbFlsodLgCbvyFZQ1cc=",
        "kJL-D0rr-SZhbj2c8nK-OQ9hCMY=",
        "hwAtAmHKYwsQrJbT5cTNDsaxVME=",
    ]

    public static func isValid(_ hash: String) -> Bool {
        let candidate = hash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.count >= 20, candidate.count <= 44 else { return false }
        guard !candidate.contains("/"), !candidate.contains("\\") else { return false }
        // UUID-shaped strings are not pass unique IDs. Real ids may still contain `-`.
        if candidate.count == 36, candidate.contains("-") { return false }
        if blocked.contains(candidate) { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=_-")
        return candidate.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// A log continuation line that is only a quoted pass id, e.g. `    "AbC…="`.
    /// Payment passes surface their identifiers this way through nfcd instead of
    /// as `.pkpass` resource lookups.
    public static func quotedPassID(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else { return nil }
        let candidate = String(trimmed.dropFirst().dropLast())
        return isValid(candidate) ? candidate : nil
    }

    /// Every pass id a syslog line yields: pattern matches plus a bare quoted id.
    /// Quoted ids can be any valid length, which the 28-char pattern misses.
    public static func passIDs(in line: String) -> [String] {
        var ids = hashes(in: line)
        if let quoted = quotedPassID(in: line), !ids.contains(quoted) {
            ids.append(quoted)
        }
        return ids
    }

    /// Unique pass ids found in one log line, in order of appearance.
    public static func hashes(in line: String) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        let range = NSRange(line.startIndex..., in: line)
        for regex in patterns {
            for match in regex.matches(in: line, range: range) {
                guard match.numberOfRanges > 1,
                      let swiftRange = Range(match.range(at: 1), in: line) else { continue }
                var candidate = String(line[swiftRange])
                candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                while candidate.hasSuffix(".") || candidate.hasSuffix(",") {
                    candidate.removeLast()
                }
                guard isValid(candidate), seen.insert(candidate).inserted else { continue }
                ordered.append(candidate)
            }
        }
        return ordered
    }
}
