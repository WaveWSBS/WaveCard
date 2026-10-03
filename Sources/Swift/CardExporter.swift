import Foundation

/// Writes stored originals out of the app as plain PNG files.
public enum CardExporter {
    /// `<label>-<hash8>.png`, with anything a filesystem would object to folded away.
    public static func proposedFilename(label: String, cardHash: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters)
        var base = label.components(separatedBy: illegal).joined()
        base = base.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        base = base.trimmingCharacters(in: .whitespacesAndNewlines)

        // A leading dot hides the file; trailing dots and spaces upset Finder.
        while base.hasPrefix(".") { base.removeFirst() }
        while base.hasSuffix(".") || base.hasSuffix(" ") { base.removeLast() }
        if base.count > 120 { base = String(base.prefix(120)) }
        if base.isEmpty { base = "card" }

        let suffix = String(cardHash.prefix(8))
        return base.hasSuffix("-\(suffix)") ? "\(base).png" : "\(base)-\(suffix).png"
    }

    /// Appends `-2`, `-3`, … until nothing is in the way.
    public static func uniqueDestination(in directory: URL, filename: String) -> URL {
        let target = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: target.path) else { return target }

        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var counter = 2
        while true {
            let candidate = directory.appendingPathComponent("\(stem)-\(counter).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    /// Writes the stored PNG bytes verbatim. Re-rendering would resample an
    /// image that is already the factory original.
    @discardableResult
    public static func write(png data: Data, to url: URL) -> Bool {
        (try? data.write(to: url, options: .atomic)) != nil
    }
}
