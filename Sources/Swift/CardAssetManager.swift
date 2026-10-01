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
                  Self.isBankArtwork(data) else {
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

        // Wallet's FrontFace is a separate rendered bitmap. It already has the
        // last four digits painted on, so it is never a stand-in for the bank art.

        return nil
    }

    /// PNG or JPEG bytes. PDF is rendered separately; other payloads are not card faces.
    private static func isRasterImage(_ data: Data) -> Bool {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true }
        if data.count >= 3, data.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        return false
    }

    /// Bank artwork is full-bleed. Wallet's composited face is a rounded card on a
    /// transparent canvas, with the last four digits already painted into the pixels.
    static func isBankArtwork(_ data: Data) -> Bool {
        guard isRasterImage(data), !isCompositedWalletFace(data) else { return false }
        return true
    }

    static func isCompositedWalletFace(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 4, image.height > 4 else { return false }
        let width = image.width
        let height = image.height
        let corners = [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)]
        return corners.allSatisfy { alpha(of: image, x: $0.0, y: $0.1) == 0 }
    }

    private static func alpha(of image: CGImage, x: Int, y: Int) -> UInt8 {
        guard let cropped = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return 255 }
        var pixel = [UInt8](repeating: 255, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 255 }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return pixel[3]
    }

    // MARK: - Local Cache Directory Operations

    public func originalCacheURL(for cardHash: String) -> URL {
        cacheDirectory.appendingPathComponent(cardHash).appendingPathComponent("original.png")
    }

    public func customCacheURL(for cardHash: String) -> URL {
        cacheDirectory.appendingPathComponent(cardHash).appendingPathComponent("custom.png")
    }

    public func saveCachedOriginal(cardHash: String, data: Data) {
        guard Self.isBankArtwork(data) else { return }
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
        let url = originalCacheURL(for: cardHash)
        let key = url.path as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let data = try? Data(contentsOf: url), Self.isBankArtwork(data) else { return nil }
        return cachedImage(at: url)
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
