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
    private var terminalEvents: [CoreEvent] = []
    private var cancelled = false
    private var order = CoreEventOrder()

    func record(_ event: CoreEvent) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard order.accept(event) else { return false }
        guard event.type == "error" || event.type == "completed" || event.type == "verificationPending" else { return true }
        terminalEvents.append(event)
        return false
    }

    var result: [CoreEvent] {
        lock.lock()
        defer { lock.unlock() }
        return terminalEvents
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

final class CoreClient: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var inputPipe: Pipe?
    private var input: FileHandle?
    private var streamState: InstallStreamState?
    private let executableOverride: URL?

    init(executableURL: URL? = nil) {
        executableOverride = executableURL
    }

    private var coreURL: URL {
        if let executableOverride { return executableOverride }
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
            process.environment = ProcessInfo.processInfo.environment.merging(["SLIP_REQUEST_ID": UUID().uuidString]) { _, new in new }
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let outputTask = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
            let errorTask = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }
            process.waitUntilExit()
            let data = await outputTask.value
            let errorData = await errorTask.value
            guard process.terminationStatus == 0 else {
                let outputText = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let errorText = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = outputText?.isEmpty == false ? outputText! : (errorText?.isEmpty == false ? errorText! : "Slip core failed")
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
        let requestID = UUID().uuidString
        let encoded = try Self.encodeRequest(input, requestID: requestID)
        return try await Task.detached(priority: .userInitiated) { [coreURL] in
            let process = Process()
            let output = Pipe()
            let errors = Pipe()
            let stdin = Pipe()
            process.executableURL = coreURL
            process.arguments = arguments
            process.environment = ProcessInfo.processInfo.environment.merging(["SLIP_REQUEST_ID": requestID]) { _, new in new }
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = stdin
            try process.run()
            try stdin.fileHandleForWriting.write(contentsOf: encoded)
            try stdin.fileHandleForWriting.close()
            let outputTask = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
            let errorTask = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }
            process.waitUntilExit()
            let data = await outputTask.value
            let errorData = await errorTask.value
            guard process.terminationStatus == 0 else {
                let outputText = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let errorText = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = outputText?.isEmpty == false ? outputText! : (errorText?.isEmpty == false ? errorText! : "Slip core failed")
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

    static func encodeRequest<T: Encodable>(_ request: T, requestID: String) throws -> Data {
        let encoded = try JSONEncoder().encode(request)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw SideloomError.message("The signing request must be a structured object.")
        }
        object["protocolVersion"] = 3
        object["requestId"] = requestID
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data([0x0A])
    }

    func installStream(request: InstallRequest) throws -> AsyncThrowingStream<CoreEvent, Error> {
        try authenticatedStream(command: "install", request: request)
    }

    func loginStream(request: LoginAccountRequest) throws -> AsyncThrowingStream<CoreEvent, Error> {
        try authenticatedStream(command: "login", request: request)
    }

    func authenticatedStream<T: Encodable>(command: String, request: T) throws -> AsyncThrowingStream<CoreEvent, Error> {
        let requestID = UUID().uuidString
        let encoded = try Self.encodeRequest(request, requestID: requestID)
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.executableURL = coreURL
        process.arguments = [command]
        process.environment = ProcessInfo.processInfo.environment.merging(["SLIP_REQUEST_ID": requestID]) { _, new in new }
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        let state = InstallStreamState()
        lock.lock()
        guard self.process == nil else {
            lock.unlock()
            throw SideloomError.message("Another Apple Account operation is running. Wait for it to finish or cancel it first.")
        }
        self.process = process
        self.inputPipe = stdin
        self.input = stdin.fileHandleForWriting
        self.streamState = state
        lock.unlock()

        return AsyncThrowingStream { continuation in
            let buffer = LineBuffer()
            let readers = DispatchGroup()
            let emitLines: @Sendable ([Data]) -> Void = { lines in
                for line in lines {
                    if let event = try? JSONDecoder().decode(CoreEvent.self, from: line) {
                        if state.record(event) { continuation.yield(event) }
                    }
                }
            }
            continuation.onTermination = { [weak self] reason in
                if case .cancelled = reason { self?.cancel(process) }
            }
            readers.enter()
            readers.enter()
            process.terminationHandler = { [weak self] process in
                readers.notify(queue: .global(qos: .userInitiated)) {
                    // Release the pipe before delivering a terminal event so an
                    // immediate retry cannot target the previous operation.
                    self?.release(process)
                    let result = state.result
                    if state.isCancelled {
                        continuation.finish(throwing: CancellationError())
                    } else if result.contains(where: { $0.type == "error" }) {
                        for event in result where event.type == "error" { continuation.yield(event) }
                        continuation.finish()
                    } else if process.terminationStatus == 0 && result.contains(where: { $0.type == "completed" || $0.type == "verificationPending" }) {
                        for event in result { continuation.yield(event) }
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: SideloomError.message(
                            "Slip’s signing engine stopped before confirming the operation (exit \(process.terminationStatus)). Try again; see Activity for the last completed step."
                        ))
                    }
                }
            }
            do {
                try process.run()
                // One reader owns stdout until EOF. This avoids racing a readability
                // callback against process termination and losing the last response.
                DispatchQueue.global(qos: .userInitiated).async {
                    while true {
                        let chunk = stdout.fileHandleForReading.availableData
                        if chunk.isEmpty { break }
                        emitLines(buffer.append(chunk))
                    }
                    if let finalLine = buffer.finish() { emitLines([finalLine]) }
                    readers.leave()
                }
                DispatchQueue.global(qos: .utility).async {
                    // Drain stderr without retaining raw third-party responses,
                    // which can contain authentication material.
                    while !stderr.fileHandleForReading.availableData.isEmpty {}
                    readers.leave()
                }
                try stdin.fileHandleForWriting.write(contentsOf: encoded)
            } catch {
                self.cancel(process)
                if !process.isRunning { self.release(process) }
                continuation.finish(throwing: error)
            }
        }
    }

    private func release(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        guard self.process === process else { return }
        try? input?.close()
        self.process = nil
        inputPipe = nil
        input = nil
        streamState = nil
    }

    private func cancel(_ process: Process) {
        lock.lock()
        let handle = self.process === process ? input : nil
        if self.process === process { streamState?.cancel() }
        lock.unlock()
        try? handle?.close()
        if process.isRunning { process.terminate() }
    }

    func send<T: Encodable>(_ response: T) throws {
        let data = try JSONEncoder().encode(response) + Data([0x0A])
        lock.lock()
        let handle = input
        lock.unlock()
        guard let handle else {
            throw SideloomError.message("No Apple Account operation is running")
        }
        try handle.write(contentsOf: data)
    }

    func cancel() {
        lock.lock()
        let process = self.process
        let input = self.input
        streamState?.cancel()
        lock.unlock()
        try? input?.close()
        if process?.isRunning == true { process?.terminate() }
    }
}

private struct TwoFactorResponse: Encodable {
    let code: String?
    let cancel: Bool
    let resend: Bool

    init(code: String? = nil, cancel: Bool = false, resend: Bool = false) {
        self.code = code
        self.cancel = cancel
        self.resend = resend
    }
}

private struct CertificateResponse: Encodable {
    let serials: [String]?
    let cancel: Bool
}

extension CoreClient {
    func submitTwoFactor(_ code: String?) throws {
        try send(TwoFactorResponse(code: code, cancel: code == nil, resend: false))
    }

    func resendTwoFactor() throws {
        try send(TwoFactorResponse(code: nil, cancel: false, resend: true))
    }

    func submitCertificates(_ serials: [String]?) throws {
        try send(CertificateResponse(serials: serials, cancel: serials == nil))
    }
}

private struct TwoFactorMethodResponse: Encodable {
    let numberId: UInt32?
    let sendToDevices: Bool
}

extension CoreClient {
    func selectTwoFactorMethod(numberID: UInt32?) throws {
        try send(TwoFactorMethodResponse(numberId: numberID, sendToDevices: numberID == nil))
    }
}

private struct CapabilityAcknowledgement: Encodable {
    let acknowledge_capabilities: Bool
}
extension CoreClient {
    func submitCapabilityAcknowledgement(_ accepted: Bool) throws {
        try send(CapabilityAcknowledgement(acknowledge_capabilities: accepted))
    }
}
