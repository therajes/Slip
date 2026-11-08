import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SideloomNative

final class CatalogArtworkTests: XCTestCase {
    func testMalformedAndOversizedArtworkFailsBeforeDecode() {
        XCTAssertThrowsError(try CatalogArtworkRepository.thumbnail(Data("not an image".utf8)))
        XCTAssertThrowsError(try CatalogArtworkRepository.thumbnail(Data(repeating: 0, count: CatalogArtworkRepository.maxInputBytes + 1)))
    }
    func testArtworkThumbnailHasFinitePixelDimensions() throws {
        let width = 2048, height = 32
        let bytes = Data(repeating: 127, count: width * height * 4)
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let result = try CatalogArtworkRepository.thumbnail(data as Data)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(result as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertLessThanOrEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? Int.max, 1024)
        XCTAssertLessThanOrEqual(result.count, CatalogArtworkRepository.maxInputBytes)
    }
    func testGitHubPaginationPreservesEndpointAndStopsAtTenPages() {
        var source = CatalogSource(address: "https://api.github.com/repos/owner/app/releases?per_page=20", github: true, name: "App", publisher: "Owner")
        XCTAssertTrue(CatalogRepository.nextGitHubPageURL(source)?.absoluteString.contains("page=2") == true)
        source.githubPage = 9
        XCTAssertTrue(CatalogRepository.nextGitHubPageURL(source)?.absoluteString.contains("page=10") == true)
        source.githubPage = 10
        XCTAssertNil(CatalogRepository.nextGitHubPageURL(source))
        source.githubPage = 1; source.githubHasMore = false
        XCTAssertNil(CatalogRepository.nextGitHubPageURL(source))
    }
}
