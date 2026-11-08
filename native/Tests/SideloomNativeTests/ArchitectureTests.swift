import XCTest
@testable import SideloomNative

final class ArchitectureTests: XCTestCase {
    private func event(_ json: String) throws -> CoreEvent { try JSONDecoder().decode(CoreEvent.self, from: Data(json.utf8)) }
    func testLegacyEventsAndUnknownPhasesRemainReadable() throws {
        var order = CoreEventOrder()
        XCTAssertTrue(order.accept(try event(#"{"type":"progress"}"#)))
        XCTAssertEqual(try event(#"{"type":"progress","phase":"future"}"#).phase, .unknown)
    }
    func testRequestMetadataIsAdditiveAndDelimited() throws {
        struct Request: Encodable { let action: String }
        let data = try CoreClient.encodeRequest(Request(action: "inspect"), requestID: "request-a")
        XCTAssertEqual(data.last, 10)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["protocolVersion"] as? Int, 3)
        XCTAssertEqual(object["requestId"] as? String, "request-a")
        XCTAssertEqual(object["action"] as? String, "inspect")
    }
    func testSequenceAndRequestIsolation() throws {
        var order = CoreEventOrder()
        XCTAssertTrue(order.accept(try event(#"{"type":"progress","protocolVersion":3,"requestId":"a","sequence":1}"#)))
        XCTAssertFalse(order.accept(try event(#"{"type":"completed","requestId":"a","sequence":1}"#)))
        XCTAssertFalse(order.accept(try event(#"{"type":"completed","requestId":"b","sequence":2}"#)))
        XCTAssertTrue(order.accept(try event(#"{"type":"completed","requestId":"a","sequence":2}"#)))
    }
}
