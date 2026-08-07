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

final class CoreClient: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var inputPipe: Pipe?
    private var input: FileHandle?

    private var coreURL: URL {
        if let bundled = Bundle.main.url(forResource: "sideloom-core", withExtension: nil) {
            return bundled
        }
        return URL(fileURLWithPath: "../src-tauri/target/release/sideloom-core")
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
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                let message = String(data: data, encoding: .utf8)
                    ?? String(data: errorData, encoding: .utf8)
                    ?? "Slip core failed"
                if let event = try? JSONDecoder().decode(CoreEvent.self, from: Data(message.utf8)),
                   let detail = event.message {
                    throw SideloomError.message(detail)
                }
                throw SideloomError.message(message.trimmingCharacters(in: .whitespacesAndNewlines))
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
            try process.run()
            try stdin.fileHandleForWriting.write(contentsOf: encoded)
            try stdin.fileHandleForWriting.close()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                let message = String(data: data, encoding: .utf8)
                    ?? String(data: errorData, encoding: .utf8)
                    ?? "Slip core failed"
                if let event = try? JSONDecoder().decode(CoreEvent.self, from: Data(message.utf8)),
                   let detail = event.message {
                    throw SideloomError.message(detail)
                }
                throw SideloomError.message(message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            guard let line = String(data: data, encoding: .utf8)?
                .split(separator: "\n").last else {
                throw SideloomError.message("Slip core returned no response")
            }
            return try JSONDecoder().decode(CoreEvent.self, from: Data(line.utf8))
        }.value
    }

    func installStream(request: InstallRequest) throws -> AsyncThrowingStream<CoreEvent, Error> {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.executableURL = coreURL
        process.arguments = ["install"]
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
            process.terminationHandler = { [weak self] process in
                stdout.fileHandleForReading.readabilityHandler = nil
                emitLines(buffer.append(stdout.fileHandleForReading.readDataToEndOfFile()))
                if let finalLine = buffer.finish() {
                    emitLines([finalLine])
                }
                let errorText = String(
                    data: stderr.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                )?.trimmingCharacters(in: .whitespacesAndNewlines)
                self?.lock.lock()
                self?.process = nil
                self?.inputPipe = nil
                self?.input = nil
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
                self?.cancel()
            }
            do {
                try process.run()
                try self.send(request)
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func send<T: Encodable>(_ response: T) throws {
        let data = try JSONEncoder().encode(response) + Data([0x0A])
        lock.lock()
        let handle = input
        lock.unlock()
        guard let handle else {
            throw SideloomError.message("No installation is running")
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
