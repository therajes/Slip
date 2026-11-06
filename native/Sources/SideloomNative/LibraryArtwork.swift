import AppKit
import SwiftUI

struct LibraryArtwork: View {
    let workspace: SavedAppWorkspace
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Text(String(workspace.name.prefix(1)).uppercased()).font(.title3.weight(.medium)).frame(maxWidth: .infinity, maxHeight: .infinity).background(Chrome.overlay(0.05)) }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("\(workspace.name) artwork")
        .task(id: workspace.ipa) {
            image = nil
            do {
                let location = try await IPAPreviewCache.shared.location(for: workspace.ipa, sourceStamp: workspace.sourceStamp)
                if !location.exists {
                    let temporary = location.url.deletingLastPathComponent().appending(path: "temporary-\(UUID()).png")
                    let core = CoreClient()
                    do {
                        _ = try await core.run(["icon", workspace.ipa.path, temporary.path])
                        try await IPAPreviewCache.shared.store(temporary, at: location.url)
                    } catch { await IPAPreviewCache.shared.discard(temporary); throw error }
                }
                guard !Task.isCancelled else { return }
                let loaded = await ThumbnailCache.shared.image(file: location.url)
                guard !Task.isCancelled else { return }
                image = loaded
            } catch { image = nil }
        }
    }
}
