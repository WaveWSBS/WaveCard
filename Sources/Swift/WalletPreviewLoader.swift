import AppKit
import Foundation
import ImageIO

/// Display-only artwork. These images must never become restoration backups.
public struct WalletPreview {
    public enum Source: String { case walletCache, ticketAssets, remotePaymentThumbnail }
    public let image: NSImage
    public let source: Source
}

/// Loads local Wallet pictures without starting a device session or downloading data.
public enum WalletPreviewLoader {
    public static func load(
        root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Passes"),
        cardIDs: Set<String>
    ) -> [String: WalletPreview] {
        var result: [String: WalletPreview] = [:]
        for id in cardIDs.sorted() where validID(id) {
            let cards = root.appendingPathComponent("Cards", isDirectory: true)
            // Only ordinary image files are supported here. Wallet's wrapped
            // FrontFace files can contain several separate PNG layers: decoding
            // the first embedded PNG would not reconstruct the whole pass.
            var cached: CGImage?
            for suffix in [".cache", ".pkcache"] where cached == nil {
                for leaf in ["FrontFace", "Preview", "PlaceHolder"] where cached == nil {
                    let file = cards.appendingPathComponent(id + suffix).appendingPathComponent(leaf)
                    if let data = read(file, root: root, limit: 16 * 1024 * 1024) {
                        cached = decodeImage(data)
                    }
                }
            }
            if let cached {
                result[id] = WalletPreview(image: NSImage(cgImage: cached, size: .zero), source: .walletCache)
                continue
            }
            let bundle = cards.appendingPathComponent(id + ".pkpass", isDirectory: true)
            guard let data = read(bundle.appendingPathComponent("pass.json"), root: root, limit: 1024 * 1024),
                  let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  ["eventTicket", "boardingPass", "generic", "storeCard", "coupon"].contains(where: { metadata[$0] is [String: Any] }) else { continue }
            func asset(_ name: String) -> CGImage? {
                for leaf in [name + "@3x.png", name + "@2x.png", name + ".png"] {
                    if let data = read(bundle.appendingPathComponent(leaf), root: root, limit: 16 * 1024 * 1024),
                       let image = decodeImage(data) { return image }
                }
                return nil
            }
            let strip = asset("strip")
            let logo = asset("logo")
            guard strip != nil || logo != nil else { continue }
            let background = color(metadata["backgroundColor"] as? String) ?? NSColor.white
            if let image = render(strip: strip, logo: logo, background: background) {
                result[id] = WalletPreview(image: image, source: .ticketAssets)
            }
        }
        return result
    }

    private static func validID(_ id: String) -> Bool {
        guard (20...44).contains(id.count), !(id.count == 36 && id.contains("-")) else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_+=-")
        return id.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func read(_ file: URL, root: URL, limit: Int) -> Data? {
        let file = file.standardizedFileURL
        let root = root.standardizedFileURL
        guard file.path.hasPrefix(root.path + "/") else { return nil }
        var cursor = file
        while true {
            guard let values = try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]),
                  values.isSymbolicLink == false else { return nil }
            if cursor == root { break }
            let parent = cursor.deletingLastPathComponent()
            guard parent != cursor else { return nil }
            cursor = parent
        }
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: limit + 1), bytes.count <= limit else { return nil }
        return bytes
    }

    private static func decodeImage(_ data: Data) -> CGImage? {
        // Reject containers and wrappers rather than letting ImageIO guess at
        // embedded layers. A real bitmap preview may be PNG, JPEG or HEIF.
        let png = data.starts(with: Data([137, 80, 78, 71, 13, 10, 26, 10]))
        let jpeg = data.starts(with: Data([255, 216, 255]))
        let heif = data.count >= 12 && data[4..<8] == Data("ftyp".utf8)
        guard png || jpeg || heif,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192,
              width * height <= 24_000_000 else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    private static func color(_ value: String?) -> NSColor? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("rgb("), text.hasSuffix(")") else { return nil }
        let values = text.dropFirst(4).dropLast().split(separator: ",", omittingEmptySubsequences: false)
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard values.count == 3, values.allSatisfy({ $0.isFinite && (0...255).contains($0) }) else { return nil }
        return NSColor(srgbRed: values[0] / 255, green: values[1] / 255, blue: values[2] / 255, alpha: 1)
    }

    private static func render(strip: CGImage?, logo: CGImage?, background: NSColor) -> NSImage? {
        let width = 1024, height = 646
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(background.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        func fit(_ image: CGImage, in box: CGRect) {
            let scale = min(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            context.draw(image, in: CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2,
                                         width: size.width, height: size.height))
        }
        // This is an artwork preview, not a reproduction of ticket text,
        // admission credentials, barcodes or other personal pass fields.
        if let strip { fit(strip, in: CGRect(x: 0, y: 95, width: width, height: 390)) }
        if let logo { fit(logo, in: CGRect(x: 32, y: 500, width: 360, height: 114)) }
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }
}
