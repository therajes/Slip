import AppKit
import SwiftUI

struct ActivityView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var appearance: AppearanceController
    @State private var reportPreview: String?
    @State private var search = ""
    @State private var attentionOnly = false

    private var entries: [String] {
        model.visibleActivity.filter {
            (!attentionOnly || needsAttention($0)) &&
            (search.isEmpty || $0.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        WorkspacePage {
            PageHeader(eyebrow: "ACTIVITY", title: "Activity", subtitle: "Follow your installations, renewals and device connections.")
            if let error = model.errorMessage {
                let diagnosis = RecoveryDiagnosis.explain(error)
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(diagnosis.nextStep)
                        Text(model.hideSensitiveInfo ? SupportReport.redact(error) : error)
                            .font(.caption).foregroundStyle(Chrome.secondaryText).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                } label: { Label(diagnosis.title, systemImage: "exclamationmark.triangle") }
            }
            Button("Preview Support Report", systemImage: "doc.text.magnifyingglass") {
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
                reportPreview = "Slip \(version)\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n\n"
                    + SupportReport.redact(model.activity.joined(separator: "\n"))
            }
            GroupBox {
                HStack(spacing: 12) {
                    Image(systemName: model.hideSensitiveInfo ? "lock.shield" : "eye")
                        .font(.system(size: 22, weight: .light))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.hideSensitiveInfo ? "Private details are hidden" : "Private details are visible")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Your choice also applies when copying the log.")
                            .font(.caption).foregroundStyle(Chrome.secondaryText)
                    }
                    Spacer()
                    Toggle("Hide sensitive information", isOn: $model.hideSensitiveInfo)
                        .labelsHidden().toggleStyle(.switch)
                }
            } label: { Label("Privacy", systemImage: "hand.raised") }
            HStack(spacing: 12) {
                SidebarSearchField(text: $search, prompt: "Search activity")
                Button {
                    attentionOnly.toggle()
                    appearance.selectionFeedback()
                } label: {
                    Label("Needs attention", systemImage: attentionOnly ? "checkmark.circle.fill" : "exclamationmark.circle")
                }
                .buttonStyle(WorkspaceActionButtonStyle(isSelected: attentionOnly))
                .accessibilityValue(attentionOnly ? "On" : "Off")
                .fixedSize()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entries.joined(separator: "\n"), forType: .string)
                    appearance.selectionFeedback()
                } label: { Label("Copy log", systemImage: "doc.on.doc") }
                .disabled(entries.isEmpty)
            }
            if entries.isEmpty {
                WorkspaceEmptyState(symbol: search.isEmpty && !attentionOnly ? "waveform.path.ecg" : "magnifyingglass",
                                    title: search.isEmpty && !attentionOnly ? "Everything starts here" : "Nothing to show",
                                    message: search.isEmpty && !attentionOnly ? "Install an app or connect your iPhone. Its progress will appear here, one step at a time." : "Try another search or show all activity.")
            } else {
                GroupBox {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: symbol(for: entry))
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(needsAttention(entry) ? Color.orange : Chrome.secondaryText)
                                    .frame(width: 22, height: 20)
                                Text(entry)
                                    .font(.system(size: 13))
                                    .lineSpacing(3)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 13)
                            if index != entries.count - 1 { Divider().padding(.leading, 34) }
                        }
                    }
                } label: {
                    HStack {
                        Label("Recent events", systemImage: "clock")
                        Spacer()
                        Text("Latest first").font(.caption).fontWeight(.regular)
                    }
                }
            }
        }
        .sheet(isPresented: Binding(get: { reportPreview != nil }, set: { if !$0 { reportPreview = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Support Report").font(.title2)
                Text("Review before sharing. URLs, account addresses, device identifiers and local paths are removed. Check any remaining app names or messages for private information.").font(.caption)
                ScrollView { Text(reportPreview ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Button("Close") { reportPreview = nil }
                    Spacer()
                    Button("Copy Report") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(reportPreview ?? "", forType: .string)
                    }
                }
            }.padding(24).frame(width: 640, height: 480)
        }
    }

    private func needsAttention(_ entry: String) -> Bool {
        ["error", "failed", "unavailable", "needs attention", "could not", "blocked"]
            .contains { entry.localizedCaseInsensitiveContains($0) }
    }

    private func symbol(for entry: String) -> String {
        if needsAttention(entry) { return "exclamationmark.circle" }
        if entry.localizedCaseInsensitiveContains("completed") || entry.localizedCaseInsensitiveContains("success") { return "checkmark.circle" }
        if entry.localizedCaseInsensitiveContains("refresh") { return "arrow.clockwise" }
        if entry.localizedCaseInsensitiveContains("sign") || entry.localizedCaseInsensitiveContains("account") { return "person.badge.key" }
        if entry.localizedCaseInsensitiveContains("device") || entry.localizedCaseInsensitiveContains("iPhone") { return "iphone" }
        return "circle.dotted"
    }
}
