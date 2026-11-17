import AppKit
import Foundation

@main
struct WalletPreviewLoaderTest {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("wavecard-preview-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var assertions = 0, failures = 0
        func expect(_ value: Bool, _ message: String) {
            assertions += 1
            if !value { failures += 1 }
            print("\(value ? "ok" : "not ok") - \(message)")
        }
        func png(_ color: NSColor, width: Int = 40, height: Int = 20) -> Data {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
        }
        func bundle(_ id: String) throws -> URL {
            let path = root.appendingPathComponent("Cards/\(id).pkpass")
            try fm.createDirectory(at: path, withIntermediateDirectories: true)
            return path
        }
        func metadata(_ path: URL, extra: [String: Any] = [:]) throws {
            var values: [String: Any] = ["eventTicket": [:], "backgroundColor": "rgb(0,0,255)"]
            values.merge(extra) { _, new in new }
            try JSONSerialization.data(withJSONObject: values).write(to: path.appendingPathComponent("pass.json"))
        }
        func pixel(_ image: NSImage, _ x: Int, _ y: Int) -> [UInt8] {
            let source = CGImageSourceCreateWithData(image.tiffRepresentation! as CFData, nil)!
            let cg = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            let context = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
                bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
            let index = (cg.height - y - 1) * cg.width * 4 + x * 4
            return [bytes[index], bytes[index + 1], bytes[index + 2]]
        }
        let ticket = "AAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let bank = "BBBBBBBBBBBBBBBBBBBBBBBBBBBB"
        let empty = "CCCCCCCCCCCCCCCCCCCCCCCCCCCC"
        let path = try bundle(ticket)
        try metadata(path, extra: ["eventTicket": ["primaryFields": [["value": "PRIVATE-ATTENDEE"]]],
                                    "barcode": ["message": "PRIVATE-CREDENTIAL"]])
        try png(.red).write(to: path.appendingPathComponent("strip.png"))
        try png(.green).write(to: path.appendingPathComponent("logo.png"))
        let loaded = WalletPreviewLoader.load(root: root, cardIDs: [ticket, bank])
        expect(loaded.count == 1 && loaded[ticket]?.source == .ticketAssets, "ticket assets produce a preview without creating a missing bank image")
        let image = loaded[ticket]!.image
        expect(image.size == NSSize(width: 1024, height: 646), "ticket artwork renders at the card preview size")
        let stripPixel = pixel(image, 512, 300)
        expect(stripPixel[0] > 240 && stripPixel[1] < 15 && stripPixel[2] < 15, "preview includes the actual strip artwork")
        let logoPixel = pixel(image, 200, 560)
        expect(logoPixel[1] > 240 && logoPixel[0] < 15, "preview includes the actual issuer logo")
        let backgroundPixel = pixel(image, 1000, 640)
        expect(backgroundPixel[2] > 240 && backgroundPixel[0] < 15, "preview respects the ticket background color")
        let first = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        expect(first.starts(with: Data([137, 80, 78, 71])), "rendered preview is a decodable bitmap")
        try metadata(path, extra: ["eventTicket": ["primaryFields": [["value": "DIFFERENT-PERSON"]]],
                                    "barcode": ["message": "DIFFERENT-SECRET"]])
        let second = WalletPreviewLoader.load(root: root, cardIDs: [ticket])[ticket]!.image
        expect(NSBitmapImageRep(data: second.tiffRepresentation!)!.representation(using: .png, properties: [:]) == first,
               "attendee fields and barcode credentials do not affect the artwork preview")

        let cache = root.appendingPathComponent("Cards/\(bank).cache")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try png(.orange, width: 320, height: 200).write(to: cache.appendingPathComponent("FrontFace"))
        let cached = WalletPreviewLoader.load(root: root, cardIDs: [bank])[bank]
        expect(cached?.source == .walletCache, "an ordinary cached face image is available without pass metadata")
        expect(cached?.image.size == NSSize(width: 320, height: 200), "cached face images retain their dimensions")
        let ticketCache = root.appendingPathComponent("Cards/\(ticket).cache")
        try fm.createDirectory(at: ticketCache, withIntermediateDirectories: true)
        var wrapper = Data([0, 0, 0, 28]); wrapper.append(png(.black))
        try wrapper.write(to: ticketCache.appendingPathComponent("FrontFace"))
        expect(WalletPreviewLoader.load(root: root, cardIDs: [ticket])[ticket]?.source == .ticketAssets,
               "wrapped cache layers are not mistaken for the complete pass")
        try png(.orange).write(to: ticketCache.appendingPathComponent("FrontFace"))
        expect(WalletPreviewLoader.load(root: root, cardIDs: [ticket])[ticket]?.source == .walletCache,
               "a directly decodable cached face takes precedence over reconstructed artwork")

        let missing = try bundle(empty)
        try metadata(missing)
        expect(WalletPreviewLoader.load(root: root, cardIDs: [empty]).isEmpty, "metadata alone cannot fabricate artwork")
        try Data("broken image".utf8).write(to: missing.appendingPathComponent("strip.png"))
        expect(WalletPreviewLoader.load(root: root, cardIDs: [empty]).isEmpty, "corrupt images do not produce a preview")
        try fm.removeItem(at: missing.appendingPathComponent("strip.png"))
        try fm.createSymbolicLink(at: missing.appendingPathComponent("strip.png"), withDestinationURL: path.appendingPathComponent("strip.png"))
        expect(WalletPreviewLoader.load(root: root, cardIDs: [empty]).isEmpty, "symlinked artwork is not followed")
        try fm.removeItem(at: missing.appendingPathComponent("strip.png"))
        try Data(repeating: 0, count: 16 * 1024 * 1024 + 1).write(to: missing.appendingPathComponent("strip.png"))
        expect(WalletPreviewLoader.load(root: root, cardIDs: [empty]).isEmpty, "oversized artwork is rejected before decoding")
        try png(.red).write(to: missing.appendingPathComponent("strip.png"))
        try Data(repeating: 32, count: 1024 * 1024 + 1).write(to: missing.appendingPathComponent("pass.json"))
        expect(WalletPreviewLoader.load(root: root, cardIDs: [empty]).isEmpty, "ticket metadata is bounded to one MiB")
        try metadata(missing, extra: ["eventTicket": "invalid"])
        expect(WalletPreviewLoader.load(root: root, cardIDs: [empty]).isEmpty, "malformed pass style metadata is rejected")
        try metadata(missing)
        try png(.green).write(to: missing.appendingPathComponent("strip@3x.png"))
        let highResolution = WalletPreviewLoader.load(root: root, cardIDs: [empty])[empty]!
        expect(pixel(highResolution.image, 512, 300)[1] > 240, "highest available strip resolution is preferred")
        expect(WalletPreviewLoader.load(root: root, cardIDs: ["../AAAAAAAAAAAAAAAAAAAA", "AAAAAAAA/AAAAAAAAAAAA"]).isEmpty,
               "unsafe identifiers cannot escape the Wallet card directory")
        let symlinkRoot = root.appendingPathComponent("symlink-root")
        try fm.createSymbolicLink(at: symlinkRoot, withDestinationURL: root)
        expect(WalletPreviewLoader.load(root: symlinkRoot, cardIDs: [ticket]).isEmpty, "symlinked Wallet roots are rejected")
        expect(!fm.fileExists(atPath: root.appendingPathComponent("Originals").path), "display previews never create restoration backups")
        print("\(assertions) assertions, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
