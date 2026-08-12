import Foundation

private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        var lines: [Data] = []
        while let newline = data.firstIndex(of: 0x0A) {
            lines.append(Data(data[..<newline]))
            data.removeSubrange(...newline)
        }
        return lines
    }

    func finish() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !data.isEmpty else { return nil }
        defer { data.removeAll(keepingCapacity: false) }
        return data
    }
}

private final class InstallStreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var receivedError = false

    func record(_ event: CoreEvent) {
        guard event.type == "error" else { return }
        lock.lock()
        receivedError = true
        lock.unlock()
    }

    var hasReceivedError: Bool {
        lock.lock()
        defer { lock.unlock() }
        return receivedError
    }
}

private final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var truncated = false
    private let maximumBytes: Int

    init(maximumBytes: Int = 128 * 1_024 * 1_024) {
        self.maximumBytes = maximumBytes
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        let remaining = max(0, maximumBytes - data.count)
        if remaining > 0 {
            data.append(chunk.prefix(remaining))
        }
        if chunk.count > remaining {
            truncated = true
        }
        lock.unlock()
    }

    var wasTruncated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return truncated
    }

    func finish() -> Data {
        lock.lock()
        defer { lock.unlock() }
        defer { data.removeAll(keepingCapacity: false) }
        return data
    }
}

private func coreFailureMessage(stdout: Data, stderr: Data) -> String {
    for data in [stdout, stderr] {
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { continue }
        if let lastLine = text.split(separator: "\n").last,
           let event = try? JSONDecoder().decode(CoreEvent.self, from: Data(lastLine.utf8)),
           let detail = event.message,
           !detail.isEmpty {
            return detail
        }
        return text
    }
    return "Slip core failed without an error message"
}

final class CoreClient: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var inputPipe: Pipe?
    private var input: FileHandle?

    private var coreURL: URL {
        if let bundled = Bundle.main.url(forResource: "sideloom-core", withExtension: nil) {
            return bundled
        }
        #if DEBUG
        let source = URL(fileURLWithPath: #filePath)
        return source
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "src-tauri/target/release/sideloom-core")
        #else
        return Bundle.main.bundleURL
            .appending(path: "Contents/Resources/sideloom-core")
        #endif
    }

    func run(_ arguments: [String]) async throws -> CoreEvent {
        try await Task.detached(priority: .userInitiated) { [coreURL] in
            let process = Process()
            let output = Pipe()
            let errors = Pipe()
            process.executableURL = coreURL
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = errors
            let outputBuffer = ProcessOutputBuffer()
            let errorBuffer = ProcessOutputBuffer(maximumBytes: 2 * 1_024 * 1_024)
            output.fileHandleForReading.readabilityHandler = { handle in
                outputBuffer.append(handle.availableData)
            }
            errors.fileHandleForReading.readabilityHandler = { handle in
                errorBuffer.append(handle.availableData)
            }
            try process.run()
            process.waitUntilExit()
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            outputBuffer.append(output.fileHandleForReading.readDataToEndOfFile())
            errorBuffer.append(errors.fileHandleForReading.readDataToEndOfFile())
            let outputWasTruncated = outputBuffer.wasTruncated
            let data = outputBuffer.finish()
            let errorData = errorBuffer.finish()
            guard process.terminationStatus == 0 else {
                throw SideloomError.message(coreFailureMessage(stdout: data, stderr: errorData))
            }
            guard !outputWasTruncated else {
                throw SideloomError.message("Slip received more app data than it could safely display")
            }
            guard let line = String(data: data, encoding: .utf8)?
                .split(separator: "\n").last else {
                throw SideloomError.message("Slip core returned no response")
            }
            return try JSONDecoder().decode(CoreEvent.self, from: Data(line.utf8))
        }.value
    }

    func run<T: Encodable>(_ arguments: [String], input: T) async throws -> CoreEvent {
        let encoded = try JSONEncoder().encode(input) + Data([0x0A])
        return try await Task.detached(priority: .userInitiated) { [coreURL] in
            let process = Process()
            let output = Pipe()
            let errors = Pipe()
            let stdin = Pipe()
            process.executableURL = coreURL
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = stdin
            let outputBuffer = ProcessOutputBuffer()
            let errorBuffer = ProcessOutputBuffer(maximumBytes: 2 * 1_024 * 1_024)
            output.fileHandleForReading.readabilityHandler = { handle in
                outputBuffer.append(handle.availableData)
            }
            errors.fileHandleForReading.readabilityHandler = { handle in
                errorBuffer.append(handle.availableData)
            }
            try process.run()
            try stdin.fileHandleForWriting.write(contentsOf: encoded)
            try stdin.fileHandleForWriting.close()
            process.waitUntilExit()
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            outputBuffer.append(output.fileHandleForReading.readDataToEndOfFile())
            errorBuffer.append(errors.fileHandleForReading.readDataToEndOfFile())
            let outputWasTruncated = outputBuffer.wasTruncated
            let data = outputBuffer.finish()
            let errorData = errorBuffer.finish()
            guard process.terminationStatus == 0 else {
                throw SideloomError.message(coreFailureMessage(stdout: data, stderr: errorData))
            }
            guard !outputWasTruncated else {
                throw SideloomError.message("Slip received more app data than it could safely display")
            }
            guard let line = String(data: data, encoding: .utf8)?
                .split(separator: "\n").last else {
                throw SideloomError.message("Slip core returned no response")
            }
            return try JSONDecoder().decode(CoreEvent.self, from: Data(line.utf8))
        }.value
    }

    private func interactiveStream<Request: Encodable>(
        arguments: [String],
        request: Request
    ) throws -> AsyncThrowingStream<CoreEvent, Error> {
        var encodedRequest = try JSONEncoder().encode(request) + Data([0x0A])
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.executableURL = coreURL
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        lock.lock()
        self.process = process
        self.inputPipe = stdin
        self.input = stdin.fileHandleForWriting
        lock.unlock()

        return AsyncThrowingStream { continuation in
            let buffer = LineBuffer()
            let state = InstallStreamState()
            let errorBuffer = ProcessOutputBuffer(maximumBytes: 2 * 1_024 * 1_024)
            let emitLines: @Sendable ([Data]) -> Void = { lines in
                for line in lines {
                    if let event = try? JSONDecoder().decode(CoreEvent.self, from: line) {
                        state.record(event)
                        continuation.yield(event)
                    }
                }
            }
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                emitLines(buffer.append(chunk))
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                errorBuffer.append(handle.availableData)
            }
            process.terminationHandler = { [weak self] process in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                emitLines(buffer.append(stdout.fileHandleForReading.readDataToEndOfFile()))
                if let finalLine = buffer.finish() {
                    emitLines([finalLine])
                }
                errorBuffer.append(stderr.fileHandleForReading.readDataToEndOfFile())
                let errorText = String(data: errorBuffer.finish(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                self?.lock.lock()
                if self?.process === process {
                    self?.process = nil
                    self?.inputPipe = nil
                    self?.input = nil
                }
                self?.lock.unlock()
                if process.terminationStatus == 0 {
                    continuation.finish()
                } else if state.hasReceivedError {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: SideloomError.message(
                        errorText?.isEmpty == false ? errorText! : "Installation failed"
                    ))
                }
            }
            continuation.onTermination = { [weak self] _ in
                self?.cancel(process: process)
            }
            do {
                try process.run()
                try self.sendEncoded(encodedRequest)
                encodedRequest.resetBytes(in: 0..<encodedRequest.count)
                encodedRequest.removeAll(keepingCapacity: false)
            } catch {
                encodedRequest.resetBytes(in: 0..<encodedRequest.count)
                encodedRequest.removeAll(keepingCapacity: false)
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                try? stdin.fileHandleForWriting.close()
                if process.isRunning { process.terminate() }
                self.lock.lock()
                if self.process === process {
                    self.process = nil
                    self.inputPipe = nil
                    self.input = nil
                }
                self.lock.unlock()
                continuation.finish(throwing: error)
            }
        }
    }

    func installStream(request: InstallRequest) throws -> AsyncThrowingStream<CoreEvent, Error> {
        try interactiveStream(arguments: ["install"], request: request)
    }

    func appIDsStream(request: AppleAccountRequest) throws -> AsyncThrowingStream<CoreEvent, Error> {
        try interactiveStream(arguments: ["app-ids"], request: request)
    }

    func send<T: Encodable>(_ response: T) throws {
        let data = try JSONEncoder().encode(response) + Data([0x0A])
        try sendEncoded(data)
    }

    private func sendEncoded(_ data: Data) throws {
        lock.lock()
        let handle = input
        lock.unlock()
        guard let handle else {
            throw SideloomError.message("No interactive Apple request is running")
        }
        try handle.write(contentsOf: data)
    }

    func cancel() {
        lock.lock()
        let process = self.process
        let input = self.input
        lock.unlock()
        try? input?.close()
        if process?.isRunning == true { process?.terminate() }
    }

    private func cancel(process expectedProcess: Process) {
        lock.lock()
        guard process === expectedProcess else {
            lock.unlock()
            return
        }
        let input = self.input
        lock.unlock()
        try? input?.close()
        if expectedProcess.isRunning { expectedProcess.terminate() }
    }
}

private struct TwoFactorResponse: Encodable {
    let code: String?
    let cancel: Bool
}

private struct CertificateResponse: Encodable {
    let serials: [String]?
    let cancel: Bool
}

extension CoreClient {
    func submitTwoFactor(_ code: String?) throws {
        try send(TwoFactorResponse(code: code, cancel: code == nil))
    }

    func submitCertificates(_ serials: [String]?) throws {
        try send(CertificateResponse(serials: serials, cancel: serials == nil))
    }
}
