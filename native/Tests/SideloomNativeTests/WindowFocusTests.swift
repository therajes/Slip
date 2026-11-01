import AppKit
import SwiftUI
import XCTest
@testable import SideloomNative

final class WindowFocusTests: XCTestCase {
    @MainActor
    func testDroppyWindowHostSupportsNativeControlsAndKeyboardFocus() {
        _ = NSApplication.shared
        let window = SlipWindowHost.make(size: NSSize(width: 400, height: 300)) { Color.clear }
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertNotNil(window.standardWindowButton(type), "Use the actual window's controls.")
        }
        XCTAssertTrue(window.contentView?.subviews.first is FrameHostingView)
        XCTAssertFalse(window.contentView?.isOpaque ?? true,
                       "The AppKit container must leave the backdrop visible.")
        XCTAssertTrue(window.canBecomeKey, "Credential fields require a keyboard-capable window.")
        XCTAssertTrue(window.canBecomeMain, "Menus and keyboard shortcuts must route to the workspace.")
    }

    @MainActor
    func testCredentialFieldsCanAcquireAFieldEditor() {
        _ = NSApplication.shared
        let window = SlipWindowHost.make(size: NSSize(width: 400, height: 300)) { Color.clear }
        let content = window.contentView!
        let email = NSTextField(frame: NSRect(x: 20, y: 180, width: 300, height: 24))
        let password = NSSecureTextField(frame: NSRect(x: 20, y: 140, width: 300, height: 24))
        content.addSubview(email)
        content.addSubview(password)
        XCTAssertTrue(window.makeFirstResponder(email))
        XCTAssertNotNil(email.currentEditor(), "Apple Account text must receive an AppKit field editor.")
        XCTAssertTrue(window.makeFirstResponder(password))
        XCTAssertNotNil(password.currentEditor(), "The secure password field must receive a field editor.")
        window.makeFirstResponder(nil)
    }

    @MainActor
    func testHostingContainerFollowsWindowResize() {
        _ = NSApplication.shared
        let window = SlipWindowHost.make(size: NSSize(width: 400, height: 300)) { Color.clear }
        window.setContentSize(NSSize(width: 600, height: 450))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.contentView?.subviews.first?.frame.size, window.contentView?.bounds.size)
    }
}
