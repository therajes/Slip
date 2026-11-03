import Combine
import Foundation

/// Byte/phase updates only invalidate the small progress views that read them.
@MainActor
final class OperationProgress: ObservableObject {
    @Published var stage = "Ready"
    @Published var fraction = 0.0
    @Published var download: IPADownloadProgress?
}
