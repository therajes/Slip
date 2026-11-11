import Security
import LocalAuthentication
import XCTest
@testable import SideloomNative

final class ProductionPolicyTests: XCTestCase {
    func testBackgroundKeychainCannotPromptAndPreservesService() {
        let query = KeychainStore.backgroundPasswordQuery(for: "fixture")
        XCTAssertEqual((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed, true)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "app.sideloom.native.apple-accounts")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "fixture")
    }
    func testCriticalDiagnosticEnglishFallback() {
        let diagnostic = SlipDiagnostic(code:.smsRequired,phase:nil,severity:.warning,retryable:false,recovery:.openAccounts)
        XCTAssertEqual(diagnostic.title,"SMS verification required")
    }
}
