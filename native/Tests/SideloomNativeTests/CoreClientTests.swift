import Foundation
import XCTest
@testable import SideloomNative

final class CoreClientTests: XCTestCase, @unchecked Sendable {
    private func fixture(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SlipCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("core-fixture")
        try Data(("#!/bin/sh\nIFS= read -r request\n" + body).utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return script
    }

    func testCapabilityAcknowledgementUsesRustCamelCaseBoolean() async throws {
        let executable = try fixture("""
        printf '%s\n' '{"type":"provisioningReviewRequired"}'
        IFS= read -r response
        case "$response" in
          *'"acknowledgeCapabilities":true'*) printf '%s\n' '{"type":"completed","message":"accepted"}' ;;
          *'"acknowledgeCapabilities":false'*) printf '%s\n' '{"type":"completed","message":"declined"}' ;;
          *) printf '%s\n' '{"type":"error","message":"Invalid capability acknowledgement key or type"}'; exit 1 ;;
        esac
        """)
        for accepted in [true, false] {
            let core = CoreClient(executableURL: executable)
            let stream = try core.authenticatedStream(command: "install", request: ["fixture": true])
            var message: String?
            for try await event in stream {
                if event.type == "provisioningReviewRequired" { try core.submitCapabilityAcknowledgement(accepted) }
                if event.type == "completed" { message = event.message }
            }
            XCTAssertEqual(message, accepted ? "accepted" : "declined")
        }
    }

    func testFragmentedFinalResponseAndImmediateRetry() async throws {
        let executable = try fixture("""
        printf '%s' '{"type":'
        printf '%s\n' '"progress","stage":"developerSession"}'
        printf '%s' '{"type":"completed"}'
        """)
        let core = CoreClient(executableURL: executable)
        for _ in 0..<8 {
            var types: [String] = []
            let stream = try core.authenticatedStream(command: "login", request: ["fixture": true])
            for try await event in stream {
                types.append(event.type)
                // A user can retry as soon as the terminal response reaches the UI.
                if event.type == "completed" { break }
            }
            XCTAssertEqual(types, ["progress", "completed"])
        }
    }

    func testVerificationResponseUsesTheActivePipe() async throws {
        let executable = try fixture("""
        printf '%s\n' '{"type":"twoFactorRequired","details":{"unknown":false,"sms":false}}'
        IFS= read -r response
        case "$response" in
          *'"code":"123456"'*) printf '%s\n' '{"type":"completed"}' ;;
          *) printf '%s\n' '{"type":"error","message":"Fixture response did not reach the active operation"}'; exit 1 ;;
        esac
        """)
        let core = CoreClient(executableURL: executable)
        let stream = try core.authenticatedStream(command: "login", request: ["fixture": true])
        var types: [String] = []
        for try await event in stream {
            types.append(event.type)
            if event.type == "twoFactorRequired" { try core.submitTwoFactor("123456") }
        }
        XCTAssertEqual(types, ["twoFactorRequired", "completed"])
    }

    func testLargeStderrDoesNotBlockOrReplaceStructuredError() async throws {
        let executable = try fixture("""
        /usr/bin/head -c 131072 /dev/zero >&2
        printf '%s' '{"type":"error","message":"Apple is temporarily unavailable","stage":"developerSession"}'
        exit 1
        """)
        let core = CoreClient(executableURL: executable)
        for _ in 0..<2 {
            let stream = try core.authenticatedStream(command: "login", request: ["fixture": true])
            var messages: [String] = []
            for try await event in stream { messages.append(event.message ?? "") }
            XCTAssertEqual(messages, ["Apple is temporarily unavailable"])
        }
    }

    func testIncompleteExitIsAnErrorAndReleasesTheOperation() async throws {
        let executable = try fixture("""
        printf '%s\n' '{"type":"progress","stage":"developerSession"}'
        """)
        let core = CoreClient(executableURL: executable)
        for _ in 0..<2 {
            let stream = try core.authenticatedStream(command: "login", request: ["fixture": true])
            do {
                for try await _ in stream {}
                XCTFail("EOF without a terminal response cannot mean successful sign-in.")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("before confirming"))
            }
        }
    }

    func testCancelWhileWaitingForCodeAndReuse() async throws {
        let executable = try fixture("""
        if [ "$1" = "cancel" ]; then
          printf '%s\n' '{"type":"twoFactorRequired"}'
          IFS= read -r response
          exit 0
        fi
        printf '%s\n' '{"type":"completed"}'
        """)
        let core = CoreClient(executableURL: executable)
        let stream = try core.authenticatedStream(command: "cancel", request: ["fixture": true])
        do {
            for try await event in stream {
                if event.type == "twoFactorRequired" { core.cancel() }
            }
            XCTFail("Canceled sign-in cannot report completion.")
        } catch {}
        let retry = try core.authenticatedStream(command: "login", request: ["fixture": true])
        var completed = false
        for try await event in retry { completed = event.type == "completed" }
        XCTAssertTrue(completed)
    }

    func testFailedExitCannotDeliverSuccess() async throws {
        let executable = try fixture("""
        printf '%s\\n' '{"type":"completed"}'
        exit 1
        """)
        let core = CoreClient(executableURL: executable)
        let stream = try core.authenticatedStream(command: "login", request: ["fixture": true])
        do {
            for try await event in stream {
                XCTAssertNotEqual(event.type, "completed", "A failing child cannot save the account as verified.")
            }
            XCTFail("A nonzero exit must fail the operation.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("exit 1"))
        }
    }
}
