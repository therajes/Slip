import AppKit
import UniformTypeIdentifiers

@MainActor
enum WorkspaceFilePicker {
    static func ipas(multiple: Bool = true) async -> [URL] {
        let panel = NSOpenPanel()
        // IPA is an executable document, not a public.archive on every macOS
        // release. Filter its extension explicitly instead of an archive fallback.
        panel.allowedContentTypes = [.data]
        let filter = IPAFileFilter()
        panel.delegate = filter
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = multiple
        panel.title = multiple ? "Choose Apps" : "Locate IPA"
        let result = await present(panel)
        withExtendedLifetime(filter) {}
        return result
    }

    static func image() async -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose App Icon"
        return await present(panel).first
    }

    private static func present(_ panel: NSOpenPanel) async -> [URL] {
        await withCheckedContinuation { continuation in
            let completion: (NSApplication.ModalResponse) -> Void = { response in
                continuation.resume(returning: response == .OK ? panel.urls : [])
            }
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                panel.beginSheetModal(for: window, completionHandler: completion)
            } else { panel.begin(completionHandler: completion) }
        }
    }
}

@MainActor
private final class IPAFileFilter: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        url.hasDirectoryPath || url.pathExtension.lowercased() == "ipa"
    }
}
