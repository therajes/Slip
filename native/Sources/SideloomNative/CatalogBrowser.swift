import AppKit
import SwiftUI

struct CatalogBrowser: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var sources: [CatalogSource] = []
    @State private var address = ""
    @State private var github = false
    @State private var approved = false
    @State private var search = ""
    @State private var selected: CatalogApp?
    @State private var error: String?
    @State private var busy = false
    @State private var showArtwork = false
    @State private var request: Task<Void, Never>?
    private var apps: [CatalogApp] {
        sources.flatMap(\.apps).filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.publisher.localizedCaseInsensitiveContains(search) || ($0.bundleID ?? "").localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Browse Apps").font(.title2.bold()); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("Only sources you add appear here. Publisher identity and compatibility are source claims, not an endorsement. Every IPA is inspected and reviewed before signing.").font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField(github ? "GitHub owner/repository" : "HTTPS AltStore source URL", text: $address).textFieldStyle(.roundedBorder)
                Toggle("GitHub", isOn: $github)
                Button("Add Source") { add() }.disabled(busy || !approved || address.isEmpty)
            }
            Toggle("I approve subscribing to this source and understand its publisher is unverified", isOn: $approved).font(.caption)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if busy { HStack { ProgressView().controlSize(.small); Text("Checking source…"); Button("Cancel") { request?.cancel(); model.cancelDownload(); busy = false } } }
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading) {
                    TextField("Search names, publishers or identifiers", text: $search).textFieldStyle(.roundedBorder)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if sources.isEmpty { Text("No subscribed sources. Add a developer's HTTPS source or an explicit GitHub repository above.").foregroundStyle(.secondary) }
                            ForEach(sources) { source in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(source.name).font(.headline)
                                    Text(source.address).font(.caption).textSelection(.enabled)
                                    Text(source.isStale ? "Stale / offline cache · refresh before choosing code" : "Fetched \(source.fetchedAt?.formatted() ?? "Never")").font(.caption).foregroundStyle(source.isStale ? Color.orange : Color.secondary)
                                    HStack {
                                        Button("Refresh") { refresh(source.id) }.disabled(busy)
                                        if CatalogRepository.nextGitHubPageURL(source) != nil {
                                            Button("Load More Releases") { loadMore(source.id) }.disabled(busy)
                                        }
                                        Button("Remove Source") { request = Task { do { try await CatalogRepository.shared.remove(source.id); await reload() } catch { self.error = error.localizedDescription } } }.disabled(busy)
                                    }
                                }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                            }
                            ForEach(apps) { app in
                                Button { selected = app; showArtwork = false } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(app.name).font(.headline)
                                        Text(app.publisher).font(.caption)
                                        Text(app.bundleID ?? "Bundle identity requires IPA inspection").font(.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }.frame(minWidth: 260, idealWidth: 320, maxWidth: 380)
                ScrollView { if let selected { detail(selected) } else { Text("Choose an app to review its publisher, domains and every available release asset.").foregroundStyle(.secondary).padding() } }
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(24).frame(minWidth: 800, minHeight: 600)
        .task { await reload() }
        .onDisappear { request?.cancel() }
    }
    private func detail(_ app: CatalogApp) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(app.name).font(.title2.bold())
            Text("Publisher claim: \(app.publisher)")
            Text("Source: \(sources.first(where: { $0.id == app.sourceID })?.address ?? "Unavailable")").font(.caption).textSelection(.enabled)
            Text("Download domains: \(app.domains.joined(separator: ", "))").font(.caption).textSelection(.enabled)
            Text("Publisher identity is not independently verified. Review every download host before continuing.").font(.caption).foregroundStyle(.orange)
            Text(app.summary).textSelection(.enabled)
            if app.iconURL != nil || !app.screenshots.isEmpty {
                Text("Artwork domains: \(Set(([app.iconURL].compactMap { $0 } + app.screenshots).compactMap(\.host)).sorted().joined(separator: ", "))").font(.caption).textSelection(.enabled)
                Toggle("Load source artwork previews", isOn: $showArtwork).font(.caption)
                if showArtwork {
                    if let icon = app.iconURL { CatalogArtwork(url: icon).frame(width: 80, height: 80).clipShape(RoundedRectangle(cornerRadius: 16)) }
                    ScrollView(.horizontal) {
                        LazyHStack {
                            ForEach(app.screenshots, id: \.self) { url in
                                CatalogArtwork(url: url).frame(width: 220, height: 280).clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                }
            }
            ForEach(app.releases) { release in
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(release.version) · \(release.assetName)").font(.headline)
                        Text(release.date ?? "Release date not provided").font(.caption)
                        Text(release.compatibility(with: model.selectedDevice?.version)).font(.caption)
                        Text(release.downloadURL.absoluteString).font(.caption).textSelection(.enabled)
                        Text(release.notes).font(.callout).textSelection(.enabled)
                        Button("Download This Asset & Inspect…") {
                            request = Task {
                                busy = true
                                defer { busy = false }
                                if await model.prepareCatalogRelease(release, expectedBundleID: app.bundleID) { dismiss() }
                                else { error = model.errorMessage ?? "Download cancelled or could not be inspected." }
                            }
                        }.disabled(busy || model.workspaceIsBusy)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func reload() async {
        do {
            sources = try await CatalogRepository.shared.load()
            if let id = selected?.id { selected = sources.flatMap(\.apps).first(where: { $0.id == id }) }
        } catch { self.error = error.localizedDescription }
    }
    private func add() {
        request = Task {
            busy = true; error = nil
            defer { busy = false }
            do { _ = try await CatalogRepository.shared.add(address: address, github: github, approved: approved); address = ""; approved = false; await reload() }
            catch is CancellationError { error = "Source request cancelled." }
            catch { self.error = error.localizedDescription }
        }
    }
    private func loadMore(_ id: UUID) {
        request = Task {
            busy = true; error = nil
            defer { busy = false }
            do { try await CatalogRepository.shared.loadMore(id); await reload() }
            catch is CancellationError { error = "Release request cancelled." }
            catch { self.error = error.localizedDescription }
        }
    }
    private func refresh(_ id: UUID) {
        request = Task {
            busy = true; error = nil
            defer { busy = false }
            do { try await CatalogRepository.shared.refresh(id); await reload() }
            catch is CancellationError { error = "Refresh cancelled." }
            catch { self.error = error.localizedDescription }
        }
    }
}
