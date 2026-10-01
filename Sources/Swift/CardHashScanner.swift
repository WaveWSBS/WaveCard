import Foundation

/// Pulls Apple Wallet pass identifiers out of a syslog line.
///
/// Pass ids look like `Coza99TKbpVUZHdDTiu7KMFfhds=` (about 28 characters,
/// base64 with `-`/`_`). A path such as `/Library/Passes/Cards/<id>.pkpass`
/// must yield only `<id>`. The id charset deliberately excludes `/`.
public enum CardHashScanner {
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
