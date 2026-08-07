import AppKit
import SwiftUI

@main
struct SlipApp: App {
    @StateObject private var model: AppModel
    private let workerMode: Bool

    init() {
        let workerMode = CommandLine.arguments.contains("--refresh-due")
        self.workerMode = workerMode
        _model = StateObject(wrappedValue: AppModel(startupTasks: !workerMode))
        if workerMode {
            NSApplication.shared.setActivationPolicy(.prohibited)
        }
    }

    var body: some Scene {
        WindowGroup {
            if workerMode {
                AutoRefreshWorkerView()
            } else {
                ContentView()
                    .environmentObject(model)
                    .frame(minWidth: 980, minHeight: 680)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open IPA…") {
                    NotificationCenter.default.post(name: .openIPA, object: nil)
                }
                .keyboardShortcut("o")
                Button("Refresh Devices") {
                    Task { await model.refreshDevices() }
                }
                .keyboardShortcut("r")
            }
        }
    }
}

private struct AutoRefreshWorkerView: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                NSApplication.shared.windows.forEach { $0.orderOut(nil) }
            }
            .task {
                _ = await AutoRefreshWorker.runDue()
                NSApplication.shared.terminate(nil)
            }
    }
}

extension Notification.Name {
    static let openIPA = Notification.Name("SideloomOpenIPA")
}
