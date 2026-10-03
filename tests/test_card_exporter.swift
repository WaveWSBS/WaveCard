import Foundation

@main
struct CardExporterTest {
    static func main() {
        var failed = 0
        func expect(_ condition: Bool, _ message: String) {
            if !condition {
                print("not ok - \(message)")
                failed += 1
            } else {
                print("ok - \(message)")
            }
        }

        let hash = "Coza99TKbpVUZHdDTiu7KMFfhds="
        let short = String(hash.prefix(8))

        expect(
            CardExporter.proposedFilename(label: "Chase Sapphire", cardHash: hash) == "Chase-Sapphire-\(short).png",
            "spaces become dashes and the hash suffix is appended"
        )

        expect(
            CardExporter.proposedFilename(label: "Apple Card", cardHash: hash) == "Apple-Card-\(short).png",
            "multi-word labels collapse to a single dash-joined stem"
        )

        expect(
            !CardExporter.proposedFilename(label: "a/b:c*d?e\"f<g>h|i\\j", cardHash: hash).contains("/"),
            "path separators are stripped"
        )

        let illegal = CardExporter.proposedFilename(label: "a/b:c*d?e\"f<g>h|i\\j", cardHash: hash)
        for ch: Character in ["/", ":", "*", "?", "\"", "<", ">", "|", "\\"] {
            expect(!illegal.contains(ch), "illegal character \(ch) is removed")
        }

        expect(
            CardExporter.proposedFilename(label: "   ", cardHash: hash) == "card-\(short).png",
            "a blank label falls back to 'card'"
        )

        expect(
            CardExporter.proposedFilename(label: "...hidden", cardHash: hash) == "hidden-\(short).png",
            "leading dots are stripped so the file stays visible"
        )

        expect(
            CardExporter.proposedFilename(label: "trailing.", cardHash: hash) == "trailing-\(short).png",
            "trailing dots are stripped"
        )

        let preSuffixed = CardExporter.proposedFilename(label: "Card-\(short)", cardHash: hash)
        expect(preSuffixed == "Card-\(short).png", "an already-suffixed label is not double suffixed")

        // uniqueDestination
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wavecard-exporter-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let name = "Card-\(short).png"
        let first = CardExporter.uniqueDestination(in: dir, filename: name)
        expect(first.lastPathComponent == name, "an unused filename is returned untouched")

        expect(CardExporter.write(png: Data([0x89, 0x50, 0x4E, 0x47]), to: first), "write succeeds into a free path")

        let second = CardExporter.uniqueDestination(in: dir, filename: name)
        expect(second.lastPathComponent == "Card-\(short)-2.png", "a taken filename gets a -2 suffix")

        expect(CardExporter.write(png: Data([0x89, 0x50, 0x4E, 0x47]), to: second), "write succeeds into the deduped path")

        let third = CardExporter.uniqueDestination(in: dir, filename: name)
        expect(third.lastPathComponent == "Card-\(short)-3.png", "the counter keeps climbing past one collision")

        if failed > 0 {
            print("\n\(failed) test(s) failed")
            exit(1)
        }
        print("\nall tests passed")
    }
}
