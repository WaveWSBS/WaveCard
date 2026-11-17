import AppKit
import Foundation

@main struct WalletPaymentPreviewTests {
    static func main() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("wavecard-payment-preview-\(UUID().uuidString)")
        let wallet = base.appendingPathComponent("Wallet")
        let thumbnails = base.appendingPathComponent("RemoteCards")
        try fm.createDirectory(at: wallet, withIntermediateDirectories: true)
        try fm.createDirectory(at: thumbnails, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let id = "AAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let unknown = "BBBBBBBBBBBBBBBBBBBBBBBBBBBB"
        let hash = Data(repeating: 0x12, count: 20)
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        func archive(_ devices: [[String: Any]]) throws {
            let object: [String: Any] = ["$objects": [], "$top": ["root": devices]]
            try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
                .write(to: wallet.appendingPathComponent("RemoteDevices.archive"))
        }
        func device(_ product: String = "iPhoneTest", _ value: Any = hash) -> [String: Any] {
            ["modelIdentifier": product, "remotePaymentInstruments": [["passID": id, "manifestHash": value], ["passID": unknown, "manifestHash": hash]]]
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 100,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.bitmapData!.initialize(repeating: 255, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let png = bitmap.representation(using: .png, properties: [:])!
        let file = thumbnails.appendingPathComponent(hex + "#80-50")
        func load(_ ids: Set<String> = [id], product: String = "iPhoneTest") -> [String: WalletPreview] {
            WalletPaymentPreviewLoader.load(walletRoot: wallet, thumbnailRoot: thumbnails, product: product, cardIDs: ids)
        }
        var failures = 0; var assertions = 0
        func expect(_ good: Bool, _ message: String) {
            assertions += 1
            print("\(good ? "ok" : "not ok") - \(message)")
            if !good { failures += 1 }
        }
        try archive([device()])
        expect(load().isEmpty, "a known instrument without its exact manifest thumbnail stays unavailable")
        try png.write(to: file)
        let result = load()
        expect(result.count == 1 && result[id] != nil, "exact device-matched manifest hash resolves a thumbnail")
        expect(result[id]?.source == .remotePaymentThumbnail, "thumbnail is explicitly a display preview")
        expect(result[id]?.image.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width == 160,
               "real decoded dimensions are retained rather than guessed from the filename")
        expect(load(product: "")[id] != nil, "offline previews can match one unique cached device by known IDs")
        expect(result[unknown] == nil, "unconfirmed cached instrument never becomes a displayed card")
        expect(load([], product: "iPhoneTest").isEmpty, "an empty card set cannot import cache inventory")
        expect(load(product: "other").isEmpty, "an unrelated device model cannot provide card pictures")
        try archive([device(), device("WatchTest")])
        expect(load(product: "")[id] != nil, "a paired Watch does not hide the uniquely matched iPhone's offline preview")
        try archive([device(), device()])
        expect(load().isEmpty, "two overlapping cached devices suppress ambiguous pictures")
        expect(load(product: "").isEmpty, "offline lookup also suppresses ambiguous cached devices")
        try archive([device("iPhoneTest", Data(repeating: 0, count: 20))])
        expect(load().isEmpty, "a different manifest hash never falls back to a generic cached picture")
        try archive([device("iPhoneTest", Data(repeating: 0, count: 19))])
        expect(load().isEmpty, "malformed manifest hashes cannot become cache paths")
        try archive([device()])
        try Data("corrupt".utf8).write(to: file)
        expect(load().isEmpty, "corrupt matching cache data is rejected")
        try fm.removeItem(at: file)
        let outside = base.appendingPathComponent("outside.png")
        try png.write(to: outside)
        try fm.createSymbolicLink(at: file, withDestinationURL: outside)
        expect(load().isEmpty, "a matching symlink is not followed")
        try fm.removeItem(at: file)
        try png.write(to: thumbnails.appendingPathComponent(hex + "#80-50-extra"))
        expect(load().isEmpty, "malformed size suffixes are rejected")
        try png.write(to: file)
        let large = thumbnails.appendingPathComponent(hex + "#160-100")
        try Data("corrupt".utf8).write(to: large)
        expect(load()[id] != nil, "a corrupt larger thumbnail can fall back to an exact smaller thumbnail")
        expect(!fm.fileExists(atPath: base.appendingPathComponent("Originals").path), "display loading never creates restoration backups")
        print("\(assertions) assertions, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
