import AppKit
import ImageIO
import SwiftUI

/// CGImage is immutable; decoding completes before the image is handed to AppKit.
private struct DecodedThumbnail: @unchecked Sendable { let image: CGImage }
private enum ThumbnailSource: Sendable { case encoded(String), file(URL) }

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let images = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<DecodedThumbnail?, Never>] = [:]

    init() { images.countLimit = 256; images.totalCostLimit = 32 * 1024 * 1024 }

    func image(encoded: String) async -> NSImage? {
        await image(key: encoded, source: .encoded(encoded))
    }

    func image(file: URL) async -> NSImage? { await image(key: "file:" + file.path, source: .file(file)) }

    private func image(key: String, source input: ThumbnailSource) async -> NSImage? {
        if let cached = images.object(forKey: key as NSString) { return cached }
        let task = inFlight[key] ?? Task.detached(priority: .utility) {
            let data: Data?
            switch input {
            case .encoded(let encoded): data = encoded.utf8.count <= 8 * 1024 * 1024 ? Data(base64Encoded: encoded) : nil
            case .file(let url):
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8 * 1024 * 1024 {
                    data = try? Data(contentsOf: url)
                } else { data = nil }
            }
            guard let data, let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 128,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return nil }
            return DecodedThumbnail(image: image)
        }
        inFlight[key] = task
        let decoded = await task.value
        inFlight[key] = nil
        guard let decoded else { return nil }
        let image = NSImage(cgImage: decoded.image, size: NSSize(width: decoded.image.width, height: decoded.image.height))
        images.setObject(image, forKey: key as NSString, cost: decoded.image.bytesPerRow * decoded.image.height)
        return image
    }
}
