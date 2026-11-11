import Foundation

struct IPADownloadProgress: Sendable {
    var received: Int64 = 0
    var expected: Int64? = nil
    var bytesPerSecond: Double = 0
    var canPause = false
    var attempt: Int = 1
    var retryDelay: Int? = nil
    var fraction: Double? { expected.flatMap { $0 > 0 ? min(1, Double(received) / Double($0)) : nil } }
    var detail: String {
        if let retryDelay { return "Retrying in \(retryDelay) s · attempt \(attempt) of 3" }
        let bytes = received.formatted(.byteCount(style: .file))
        let total = expected.map { " of \($0.formatted(.byteCount(style: .file)))" } ?? ""
        let speed = bytesPerSecond > 0 ? " · \(Int64(bytesPerSecond).formatted(.byteCount(style: .file)))/s" : ""
        return bytes + total + speed
    }
}

/// Monotonic, bounded progress publication; URLSession may report every network chunk.
struct IPADownloadProgressClock {
    private var reportedAt: TimeInterval?
    private var reportedBytes: Int64 = 0
    private var completed = false

    mutating func report(total: Int64, expected: Int64, now: TimeInterval) -> Double? {
        guard !completed else { return nil }
        let finished = expected > 0 && total >= expected
        if let reportedAt, now - reportedAt < 0.15 && !finished { return nil }
        let rate = reportedAt.map { Double(max(0, total - reportedBytes)) / max(now - $0, 0.001) } ?? 0
        reportedAt = now
        reportedBytes = total
        completed = finished
        return rate
    }
}

enum IPADownloadError: LocalizedError {
    case invalidURL, invalidArchive, http(Int, Int?)
    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a complete HTTP or HTTPS download link without a username or password."
        case .invalidArchive: "The link returned a webpage or another file instead of an IPA archive. Use the direct download link."
        case .http(401, _), .http(403, _): "The download link requires access or has expired. Get a fresh direct download link."
        case .http(404, _): "The IPA was not found. Check the download link (HTTP 404)."
        case .http(let code, _): "The download service returned HTTP \(code). Try again later."
        }
    }
}

enum IPADownloadPolicy {
    static func url(_ input: String) -> URL? {
        guard let parts = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              parts.host?.isEmpty == false, parts.user == nil, parts.password == nil else { return nil }
        if parts.scheme?.lowercased() == "https", !NetworkEndpointPolicy.publicHost(parts.host ?? "") { return nil }
        return parts.url
    }
    static func retryDelay(_ error: Error, attempt: Int) -> Int? {
        guard attempt < 3 else { return nil }
        if case let IPADownloadError.http(code, delay) = error, [429, 500, 502, 503, 504].contains(code) {
            return min(30, max(1, delay ?? attempt * 2))
        }
        if let error = error as? URLError,
           [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(error.code) {
            return attempt * 2
        }
        return nil
    }
    static func message(_ error: Error) -> String {
        if let error = error as? IPADownloadError { return error.localizedDescription }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet: return "You’re offline. Reconnect, then try the download again."
            case .timedOut: return "The download server timed out. Try again or use another direct link."
            case .serverCertificateUntrusted, .secureConnectionFailed: return "The download server’s secure connection could not be verified."
            default: return "The download connection was interrupted. Try again."
            }
        }
        return "The IPA could not be saved. Check available storage and try again."
    }
}

struct PausedIPADownload: Error, @unchecked Sendable {
    let data: Data
    let url: URL
    let validator: String
    let length: String
}

final class IPADownloadControl: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() -> Void)?
    func register(_ action: (() -> Void)?) { lock.lock(); self.action = action; lock.unlock() }
    func pause() { lock.lock(); let action = action; lock.unlock(); action?() }
}

struct IPAURLDownloadService: Sendable {
    func download(_ url: URL, to directory: URL, control: IPADownloadControl? = nil, resume: PausedIPADownload? = nil,
                  progress: @escaping @Sendable (IPADownloadProgress) -> Void) async throws -> URL {
        guard IPADownloadPolicy.url(url.absoluteString) != nil else { throw IPADownloadError.invalidURL }
        if url.scheme?.lowercased() == "https" {
            guard let host = url.host, await NetworkEndpointPolicy.resolvesPublicly(host) else { throw IPADownloadError.invalidURL }
        }
        if let resume {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            let session = URLSession(configuration: config, delegate: DownloadValidationRedirectPolicy(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.url == resume.url,
                  http.value(forHTTPHeaderField: "ETag") == resume.validator,
                  http.value(forHTTPHeaderField: "Content-Length") == resume.length else {
                throw SideloomError.message("The remote file changed or could not be verified. Cancel this paused download and start a fresh transfer.")
            }
        }
        for attempt in 1...3 {
            try Task.checkCancellation()
            do {
                return try await IPAFileDownload(url: url, directory: directory, attempt: attempt, control: control, resume: resume, progress: progress).run()
            } catch {
                try Task.checkCancellation()
                guard let delay = IPADownloadPolicy.retryDelay(error, attempt: attempt) else { throw error }
                progress(IPADownloadProgress(attempt: attempt + 1, retryDelay: delay))
                try await Task.sleep(for: .seconds(delay))
            }
        }
        throw URLError(.cannotLoadFromNetwork)
    }
}

/// URLSession writes large IPAs to disk. The delegate moves the temporary file
/// before URLSession removes it, and cancellation finishes its continuation once.
private final class IPAFileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let control: IPADownloadControl?
    private let resume: PausedIPADownload?
    private var pausing = false
    private let url: URL
    private let directory: URL
    private let attempt: Int
    private let progress: @Sendable (IPADownloadProgress) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var finished = false
    private var progressClock = IPADownloadProgressClock()
    private var pauseRegistered = false

    init(url: URL, directory: URL, attempt: Int, control: IPADownloadControl?, resume: PausedIPADownload?, progress: @escaping @Sendable (IPADownloadProgress) -> Void) {
        self.control = control; self.resume = resume
        self.url = url; self.directory = directory; self.attempt = attempt; self.progress = progress
    }

    func run() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let config = URLSessionConfiguration.default
                config.requestCachePolicy = .reloadIgnoringLocalCacheData
                config.urlCache = nil
                config.httpShouldSetCookies = false
                config.httpCookieStorage = nil
                config.urlCredentialStorage = nil
                config.timeoutIntervalForRequest = 60
                config.timeoutIntervalForResource = 3600
                config.networkServiceType = .responsiveData
                config.httpMaximumConnectionsPerHost = 16
                config.allowsCellularAccess = true
                config.allowsExpensiveNetworkAccess = true
                config.allowsConstrainedNetworkAccess = true
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session
                var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
                req.setValue("application/octet-stream, application/zip, */*", forHTTPHeaderField: "Accept")
                // IPA archives are already compressed; avoid redundant transfer decoding.
                req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
                let task = resume.map { session.downloadTask(withResumeData: $0.data) } ?? session.downloadTask(with: req)
                task.priority = URLSessionTask.highPriority
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.cancel() }
    }

    private func pause() {
        lock.lock()
        guard let task, let response = task.response as? HTTPURLResponse,
              let validator = response.value(forHTTPHeaderField: "ETag"), !validator.hasPrefix("W/"),
              let length = response.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.map(String.init) ?? response.value(forHTTPHeaderField: "Content-Length"),
              response.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes",
              let finalURL = response.url, !finished else { lock.unlock(); return }
        pausing = true
        lock.unlock()
        task.cancel { data in
            if let data {
                self.finish(.failure(PausedIPADownload(data: data, url: finalURL, validator: validator, length: length)))
            } else {
                self.finish(.failure(SideloomError.message("The server could not preserve this transfer. Start a fresh download.")))
            }
        }
    }

    private func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    @discardableResult
    private func finish(_ result: Result<URL, Error>) -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); return false }
        finished = true
        let continuation = continuation
        self.continuation = nil
        let session = session
        self.session = nil
        task = nil
        lock.unlock()
        control?.register(nil)
        continuation?.resume(with: result)
        session?.finishTasksAndInvalidate()
        return true
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock()
        let rate = finished ? nil : progressClock.report(total: totalBytesWritten, expected: totalBytesExpectedToWrite, now: ProcessInfo.processInfo.systemUptime)
        lock.unlock()
        guard let rate else { return }
        let response = downloadTask.response as? HTTPURLResponse
        let canPause = response?.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes"
            && response?.value(forHTTPHeaderField: "ETag").map { !$0.hasPrefix("W/") } == true
            && response?.value(forHTTPHeaderField: "Content-Length") != nil
        if canPause {
            lock.lock()
            if !pauseRegistered && !finished {
                pauseRegistered = true
                control?.register { [weak self] in self?.pause() }
            }
            lock.unlock()
        }
        progress(IPADownloadProgress(received: totalBytesWritten,
                                     expected: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil,
                                     bytesPerSecond: rate, canPause: canPause, attempt: attempt))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let redirected = request.url, IPADownloadPolicy.url(redirected.absoluteString) != nil,
              !(response.url?.scheme?.lowercased() == "https" && redirected.scheme?.lowercased() == "http") else { completionHandler(nil); return }
        var req = request
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        if request.url?.scheme?.lowercased() == "https", let host = request.url?.host {
            Task { completionHandler(await NetworkEndpointPolicy.resolvesPublicly(host) ? req : nil) }
        } else { completionHandler(req) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        var saved: URL?
        do {
            guard let response = downloadTask.response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard (200...299).contains(response.statusCode) else {
                throw IPADownloadError.http(response.statusCode, response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
            }
            let handle = try FileHandle(forReadingFrom: location)
            let signature = try handle.read(upToCount: 4)
            try handle.close()
            guard signature == Data([0x50, 0x4b, 0x03, 0x04]) else { throw IPADownloadError.invalidArchive }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let destination = directory.appending(path: "\(UUID().uuidString).ipa")
            try FileManager.default.moveItem(at: location, to: destination)
            saved = destination
            lock.lock(); let cancelled = cancelled; lock.unlock()
            if cancelled { throw CancellationError() }
            if !finish(.success(destination)) { try? FileManager.default.removeItem(at: destination) }
        } catch {
            if let saved { try? FileManager.default.removeItem(at: saved) }
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let pausing = pausing; lock.unlock()
        if !pausing { finish(.failure(error ?? URLError(.badServerResponse))) }
    }
}


private final class DownloadValidationRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, IPADownloadPolicy.url(url.absoluteString) != nil,
              !(response.url?.scheme == "https" && url.scheme == "http") else { completionHandler(nil); return }
        if request.url?.scheme?.lowercased() == "https", let host = request.url?.host {
            Task { completionHandler(await NetworkEndpointPolicy.resolvesPublicly(host) ? request : nil) }
        } else { completionHandler(request) }
    }
}
