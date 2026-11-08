import AppKit
import CryptoKit
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

private final class CatalogArtworkRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var redirects = 0
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        lock.lock(); redirects += 1; let allowed = redirects <= 5; lock.unlock()
        guard allowed, let url = request.url, SourceFeedParser.secureURL(url.absoluteString) != nil,
              let host = url.host else { completionHandler(nil); return }
        Task { completionHandler(await NetworkEndpointPolicy.resolvesPublicly(host) ? request : nil) }
    }
}

actor CatalogArtworkRepository {
    static let shared = CatalogArtworkRepository(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "app.sideloom.native/CatalogArtwork-v1"))
    let directory: URL
    init(directory: URL) { self.directory = directory }
    static let maxInputBytes = 8 * 1024 * 1024
    static let maxPixels = 40_000_000
    static let maxDiskBytes = 64 * 1024 * 1024
    static func thumbnail(_ data: Data) throws -> Data {
        guard data.count <= maxInputBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.int64Value > 0, height.int64Value > 0,
              width.int64Value <= Int64(maxPixels), height.int64Value <= Int64(maxPixels),
              width.int64Value * height.int64Value <= Int64(maxPixels),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw SideloomError.message("Artwork is invalid or exceeds the 8 MB / 40 megapixel safety limit.") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw SideloomError.message("Artwork preview could not be created.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= maxInputBytes else { throw SideloomError.message("Artwork preview exceeded its safety budget.") }
        return output as Data
    }
    func imageData(_ url: URL) async throws -> Data {
        guard SourceFeedParser.secureURL(url.absoluteString) != nil, let host = url.host else { throw SideloomError.message("Artwork requires a public HTTPS URL.") }
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent(key + ".png")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
           attributes[.type] as? FileAttributeType == .typeRegular,
           let size = attributes[.size] as? NSNumber, size.intValue <= Self.maxInputBytes {
            return try Data(contentsOf: file)
        }
        guard await NetworkEndpointPolicy.resolvesPublicly(host) else { throw SideloomError.message("Artwork host is not a public internet endpoint.") }
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: CatalogArtworkRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.expectedContentLength <= Int64(Self.maxInputBytes) else { throw SideloomError.message("Artwork download failed or is too large.") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < Self.maxInputBytes else { throw SideloomError.message("Artwork exceeds the 8 MB download limit.") }
            data.append(byte)
        }
        let thumbnail = try Self.thumbnail(data)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try trim(reserving: thumbnail.count)
        try thumbnail.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return thumbnail
    }
    private func trim(reserving bytes: Int) throws {
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        let files = entries.compactMap { url -> (URL, Int, Date)? in
            guard url.pathExtension == "png", let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]), values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var size = files.reduce(bytes) { $0 + $1.1 }
        for file in files where size > Self.maxDiskBytes {
            try FileManager.default.removeItem(at: file.0); size -= file.1
        }
    }
}

struct CatalogArtwork: View {
    let url: URL
    @State private var data: Data?
    @State private var error: String?
    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit() }
            else if let error { Label(error, systemImage: "photo.badge.exclamationmark").font(.caption).foregroundStyle(.secondary) }
            else { ProgressView().controlSize(.small) }
        }
        .accessibilityLabel("Source-provided artwork preview")
        .task(id: url) {
            data = nil; error = nil
            do { let value = try await CatalogArtworkRepository.shared.imageData(url); try Task.checkCancellation(); data = value }
            catch is CancellationError { }
            catch { self.error = "Preview unavailable" }
        }
    }
}
