import Foundation
import AppKit
import CoreGraphics

/// Manages card asset processing, aspect-fill resizing to exact Apple Wallet specs,
/// vector PDF generation, and local card caching.
public final class CardAssetManager {
    public static let shared = CardAssetManager()

    /// Standard Apple Wallet Pass card dimensions:
    /// @3x: 1536 x 969
    /// @2x: 1024 x 646
    public static let cardTargetSize3x = CGSize(width: 1536, height: 969)
    public static let cardTargetSize2x = CGSize(width: 1024, height: 646)

    private let cacheDirectory: URL
    private let imageCache = NSCache<NSString, NSImage>()

    private init() {
        let appSupport = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheDirectory = appSupport.appendingPathComponent("com.mak5er.aircard/cards", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - CoreGraphics Aspect-Fill Scaling & PNG Export

    /// Renders an NSImage to an exact target CGSize using Aspect Fill cropping.
    public func renderAspectFill(image: NSImage, targetSize: CGSize) -> CGImage? {
        guard let tiff = image.tiffRepresentation,
              let source = CGImageSourceCreateWithData(tiff as CFData, nil),
              let srcImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let srcWidth = CGFloat(srcImage.width)
        let srcHeight = CGFloat(srcImage.height)
        guard srcWidth > 0 && srcHeight > 0 else { return nil }

        let targetAspect = targetSize.width / targetSize.height
        let srcAspect = srcWidth / srcHeight

        var drawRect = CGRect(origin: .zero, size: targetSize)

        if srcAspect > targetAspect {
            let scale = targetSize.height / srcHeight
            let scaledWidth = srcWidth * scale
            drawRect.origin.x = (targetSize.width - scaledWidth) / 2.0
            drawRect.size.width = scaledWidth
        } else {
            let scale = targetSize.width / srcWidth
            let scaledHeight = srcHeight * scale
            drawRect.origin.y = (targetSize.height - scaledHeight) / 2.0
            drawRect.size.height = scaledHeight
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let context = CGContext(
            data: nil,
            width: Int(targetSize.width),
            height: Int(targetSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(srcImage, in: drawRect)

        return context.makeImage()
    }

    /// Converts CGImage to PNG Data.
    public func cgImageToPNG(cgImage: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }

    /// Generates vector/raster PDF matching cardTargetSize.
    public func createPDF(from cgImage: CGImage, targetSize: CGSize) -> Data? {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: targetSize)

        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return nil
        }

        pdfContext.beginPage(mediaBox: &mediaBox)
        pdfContext.interpolationQuality = .high
        pdfContext.draw(cgImage, in: mediaBox)
        pdfContext.endPage()
        pdfContext.closePDF()

        return data as Data
    }

    /// Prepares complete asset bundle (@3x.png, @2x.png, .pdf) for Apple Wallet skin flashing.
    public func prepareCardAssets(from image: NSImage) -> (png3x: Data, png2x: Data, pdf: Data)? {
        guard let cg3x = renderAspectFill(image: image, targetSize: Self.cardTargetSize3x),
              let png3x = cgImageToPNG(cgImage: cg3x) else {
            return nil
        }

        guard let cg2x = renderAspectFill(image: image, targetSize: Self.cardTargetSize2x),
              let png2x = cgImageToPNG(cgImage: cg2x) else {
            return nil
        }

        guard let pdf = createPDF(from: cg3x, targetSize: Self.cardTargetSize3x) else {
            return nil
        }

        return (png3x, png2x, pdf)
    }

    // MARK: - Native Card Background Loading from iPhone

    /// Extracts original card background data from connected device via Airlift.
    public func fetchOriginalArtworkData(udid: String, cardHash: String) async -> Data? {
        // Return existing cached version immediately if available
        if let cached = loadCachedOriginal(for: cardHash), let tiff = cached.tiffRepresentation {
            return tiff
        }

        guard CardHashScanner.isValid(cardHash) else { return nil }

        let pkpassDir = "/var/mobile/Library/Passes/Cards/\(cardHash).pkpass"
        // Most Apple Pay passes use @2x.png; try @2x first. One attempt per
        // name: a missing file still costs a full Airlift round trip.
        let candidates = [
            "cardBackgroundCombined@2x.png",
            "cardBackgroundCombined@3x.png",
            "cardBackgroundCombined.png"
        ]

        for leaf in candidates {
            guard let data = AirliftBridge.shared.readFile(udid: udid, target: pkpassDir, leaf: leaf, retries: 1),
                  Self.isRasterImage(data) else {
                continue
            }
            saveCachedOriginal(cardHash: cardHash, data: data)
            return data
        }

        // Fallback: Check if PDF exists and render page 1
        if let pdfData = AirliftBridge.shared.readFile(udid: udid, target: pkpassDir, leaf: "cardBackgroundCombined.pdf", retries: 1),
           pdfData.starts(with: Data("%PDF".utf8)),
           let provider = CGDataProvider(data: pdfData as CFData),
           let pdfDoc = CGPDFDocument(provider),
           let page = pdfDoc.page(at: 1) {
            let rect = page.getBoxRect(.mediaBox)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            if let context = CGContext(data: nil, width: Int(rect.width), height: Int(rect.height), bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo.rawValue) {
                context.drawPDFPage(page)
                if let cgImage = context.makeImage(), let png = cgImageToPNG(cgImage: cgImage) {
                    saveCachedOriginal(cardHash: cardHash, data: png)
                    return png
                }
            }
        }

        // Fallback: non-payment passes keep no .pkpass artwork, but Wallet caches
        // the rendered face in <hash>.cache / <hash>.pkcache as a keyed archive.
        if let data = fetchCachedImageSetFace(udid: udid, cardHash: cardHash) {
            saveCachedOriginal(cardHash: cardHash, data: data)
            return data
        }

        return nil
    }

    /// Reads Wallet's rendered face image set (FrontFace/PlaceHolder/Preview) from
    /// the pass render cache and extracts the archived face image.
    private func fetchCachedImageSetFace(udid: String, cardHash: String) -> Data? {
        let base = "/var/mobile/Library/Passes/Cards/\(cardHash)"
        for ext in [".cache", ".pkcache"] {
            for leaf in ["FrontFace", "Preview", "PlaceHolder"] {
                guard let raw = AirliftBridge.shared.readFile(udid: udid, target: base + ext, leaf: leaf, retries: 1) else {
                    continue
                }
                if let image = Self.decodeImageSetFace(from: raw), Self.isRasterImage(image) {
                    return image
                }
            }
        }
        return nil
    }

    /// Unarchives a `PK*ImageSet` and pulls the face image bytes out of it.
    private static func decodeImageSetFace(from raw: Data) -> Data? {
        guard let start = raw.range(of: Data("bplist00".utf8))?.lowerBound else { return nil }
        let payload = raw.subdata(in: start..<raw.endIndex)

        if let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: payload) {
            unarchiver.requiresSecureCoding = false
            unarchiver.decodingFailurePolicy = .setErrorAndReturn
            for name in ["PKPassFrontFaceImageSet", "PKPassPlaceHolderImageSet", "PKPassPreviewImageSet", "PKPassImageSet"] {
                unarchiver.setClass(PKImageSetShim.self, forClassName: name)
            }
            unarchiver.setClass(PKImageShim.self, forClassName: "PKImage")
            unarchiver.setClass(PKColorShim.self, forClassName: "PKColor")
            if let set = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? PKImageSetShim,
               let image = set.images.first {
                return image
            }
        }

        return decodeLargestEmbeddedImage(from: payload)
    }

    /// Last-resort scan for the biggest PNG/JPEG stored in the archive's data objects.
    private static func decodeLargestEmbeddedImage(from payload: Data) -> Data? {
        guard let plist = try? PropertyListSerialization.propertyList(from: payload, options: [], format: nil),
              let dict = plist as? [String: Any],
              let objects = dict["$objects"] as? [Any] else { return nil }

        var best: Data?
        for case let object as [String: Any] in objects {
            guard let data = object["NS.data"] as? Data, isRasterImage(data) else { continue }
            if best == nil || data.count > best!.count {
                best = data
            }
        }
        return best
    }

    /// PNG or JPEG bytes. PDF is rendered separately; other payloads are not card faces.
    private static func isRasterImage(_ data: Data) -> Bool {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true }
        if data.count >= 3, data.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        return false
    }

    // MARK: - Local Cache Directory Operations

    public func originalCacheURL(for cardHash: String) -> URL {
        cacheDirectory.appendingPathComponent(cardHash).appendingPathComponent("original.png")
    }

    public func customCacheURL(for cardHash: String) -> URL {
        cacheDirectory.appendingPathComponent(cardHash).appendingPathComponent("custom.png")
    }

    public func saveCachedOriginal(cardHash: String, data: Data) {
        let dir = cacheDirectory.appendingPathComponent(cardHash)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = originalCacheURL(for: cardHash)
        try? data.write(to: url)
        imageCache.removeObject(forKey: url.path as NSString)
    }

    public func saveCachedCustom(cardHash: String, data: Data) {
        let dir = cacheDirectory.appendingPathComponent(cardHash)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = customCacheURL(for: cardHash)
        try? data.write(to: url)
        imageCache.removeObject(forKey: url.path as NSString)
    }

    public func loadCachedOriginal(for cardHash: String) -> NSImage? {
        cachedImage(at: originalCacheURL(for: cardHash))
    }

    public func loadCachedCustom(for cardHash: String) -> NSImage? {
        cachedImage(at: customCacheURL(for: cardHash))
    }

    /// Decodes a card image once. The card grid reads this on every redraw.
    public func cachedImage(at url: URL) -> NSImage? {
        let key = url.path as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard FileManager.default.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }

    public func clearCachedCustom(cardHash: String) {
        let url = customCacheURL(for: cardHash)
        imageCache.removeObject(forKey: url.path as NSString)
        try? FileManager.default.removeItem(at: url)
    }
}

@objc(AirCardPKImageShim)
private final class PKImageShim: NSObject, NSCoding {
    let imageData: Data?

    init?(coder: NSCoder) {
        imageData = coder.decodeObject(forKey: "imageData") as? Data
    }

    func encode(with coder: NSCoder) {}
}

@objc(AirCardPKImageSetShim)
private final class PKImageSetShim: NSObject, NSCoding {
    let images: [Data]

    init?(coder: NSCoder) {
        let keys = ["faceImage", "placeHolderImage", "iconImage", "rawIcon", "image"]
        images = keys.compactMap {
            (coder.decodeObject(forKey: $0) as? PKImageShim)?.imageData
        }
    }

    func encode(with coder: NSCoder) {}
}

@objc(AirCardPKColorShim)
private final class PKColorShim: NSObject, NSCoding {
    init?(coder: NSCoder) {}

    func encode(with coder: NSCoder) {}
}
