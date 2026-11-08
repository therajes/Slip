import XCTest
@testable import SideloomNative

final class NetworkEndpointPolicyTests: XCTestCase {
    func testRejectsPrivateAndAlternateNumericAddresses() {
        for host in ["localhost", "localhost.", "10.1.2.3", "100.64.0.1", "198.19.1.1", "224.0.0.1", "2130706433", "0177.0.0.1", "0x7f000001", "::ffff:127.0.0.1", "::1", "fe80::1", "fd00::1", "metadata.internal"] {
            XCTAssertFalse(NetworkEndpointPolicy.publicHost(host), host)
        }
    }
    func testAcceptsPublicEndpoints() {
        for host in ["github.com", "8.8.8.8", "2606:4700:4700::1111"] { XCTAssertTrue(NetworkEndpointPolicy.publicHost(host), host) }
    }
}
