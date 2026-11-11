import Foundation
import XCTest
@testable import SideloomNative

private final class DownloadProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [IPADownloadProgress] = []
    func append(_ entry: IPADownloadProgress) { lock.lock(); entries.append(entry); lock.unlock() }
    var snapshots: [IPADownloadProgress] { lock.lock(); defer { lock.unlock() }; return entries }
}

final class IPADownloadTests: XCTestCase, @unchecked Sendable {
    func testProgressRateExcludesServerWaitAndThrottlesBurstCallbacks() {
        var clock = IPADownloadProgressClock()
        // A long DNS/redirect/header wait does not become part of transfer throughput.
        XCTAssertEqual(clock.report(total: 1000, expected: 10000, now: 50), 0)
        for offset in 1..<100 {
            XCTAssertNil(clock.report(total: Int64(1000 + offset), expected: 10000, now: 50 + Double(offset) / 1000))
        }
        XCTAssertEqual(clock.report(total: 3000, expected: 10000, now: 50.2) ?? -1, 10000, accuracy: 0.01)
        XCTAssertNotNil(clock.report(total: 10000, expected: 10000, now: 50.21), "Completion must not wait for the UI interval.")
        XCTAssertNil(clock.report(total: 10000, expected: 10000, now: 50.22), "Completion is published once.")
    }

    func testUnknownLengthStillPublishesBoundedProgress() {
        var clock = IPADownloadProgressClock()
        XCTAssertNotNil(clock.report(total: 1024, expected: -1, now: 1))
        XCTAssertNil(clock.report(total: 2048, expected: -1, now: 1.01))
        XCTAssertNotNil(clock.report(total: 4096, expected: -1, now: 1.2))
    }

    private func fixture() async throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "SlipDownload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ready = root.appending(path: "port")
        let program = #"""
        import http.server,sys,pathlib,time,threading
        counts={}; lock=threading.Lock()
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self,*args):pass
            def do_HEAD(self):
                self.send_response(200)
                self.send_header('ETag', '"changed"' if pathlib.Path(sys.argv[1]+'.changed').exists() else '"fixture"')
                self.send_header('Content-Length','262148')
                self.send_header('Accept-Ranges','bytes')
                self.end_headers()
            def do_GET(self):
                with lock:
                    counts[self.path]=counts.get(self.path,0)+1
                    count=counts[self.path]
                if self.path=='/count':
                    body=str(counts.get('/missing',0)).encode();status=200
                elif self.path=='/missing':body=b'not found';status=404
                elif self.path=='/html':body=b'<html>not an IPA</html>';status=200
                elif self.path=='/retry' and count==1:body=b'retry';status=503
                elif self.path=='/redirect':
                    self.send_response(302);self.send_header('Location','/ok');self.end_headers();return
                else:body=b'PK\x03\x04'+b'x'*262144;status=200
                total=len(body)
                offset=int(self.headers.get('Range','bytes=0-').split('=')[1].split('-')[0]) if self.path=='/resumable' else 0
                if offset: body=body[offset:];status=206
                self.send_response(status)
                if self.path=='/resumable':
                    self.send_header('ETag','"fixture"')
                    self.send_header('Accept-Ranges','bytes')
                    if offset:self.send_header('Content-Range',f'bytes {offset}-{total-1}/{total}')
                self.send_header('Content-Length',str(len(body)))
                if status==503:self.send_header('Retry-After','1')
                self.end_headers()
                try:
                    for start in range(0,len(body),4096):
                        self.wfile.write(body[start:start+4096]);self.wfile.flush()
                        if self.path in ('/slow','/resumable'):time.sleep(.05)
                except (BrokenPipeError,ConnectionResetError):pass
        # Binding a numeric loopback address needs no reverse DNS lookup.
        class LocalHTTPServer(http.server.ThreadingHTTPServer):
            def server_bind(self):
                self.socket.bind(self.server_address)
                self.server_address = self.socket.getsockname()
                self.server_name = self.server_address[0]
                self.server_port = self.server_address[1]
        server=LocalHTTPServer(('127.0.0.1',0),Handler)
        pathlib.Path(sys.argv[1]).write_text(str(server.server_port))
        server.serve_forever()
        """#
        let child = Process()
        if let python3 = ProcessInfo.processInfo.environment["SLIP_PYTHON3"], !python3.isEmpty {
            child.executableURL = URL(fileURLWithPath: python3)
            child.arguments = ["-I", "-u", "-c", program, ready.path]
        } else {
            child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            child.arguments = ["python3", "-I", "-u", "-c", program, ready.path]
        }
        let diagnostics = root.appending(path: "server.stderr")
        _ = FileManager.default.createFile(atPath: diagnostics.path, contents: nil)
        let errorOutput = try FileHandle(forWritingTo: diagnostics)
        child.standardOutput = FileHandle.nullDevice
        child.standardError = errorOutput
        addTeardownBlock {
            if child.isRunning { child.terminate(); child.waitUntilExit() }
            try? errorOutput.close()
            try? FileManager.default.removeItem(at: root)
        }
        try child.run()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while clock.now < deadline {
            if let value = try? String(contentsOf: ready, encoding: .utf8),
               let port = UInt16(value.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 {
                return (URL(string: "http://127.0.0.1:\(port)")!, root.appending(path: "Imports"))
            }
            if !child.isRunning {
                let detail = (try? String(contentsOf: diagnostics, encoding: .utf8)) ?? "No stderr output."
                throw NSError(domain: "SlipDownloadFixture", code: Int(child.terminationStatus), userInfo: [
                    NSLocalizedDescriptionKey: "Python download fixture exited before becoming ready: \(detail)"
                ])
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let detail = (try? String(contentsOf: diagnostics, encoding: .utf8)) ?? "No stderr output."
        throw NSError(domain: "SlipDownloadFixture", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Python download fixture did not become ready within 30 seconds: \(detail)"
        ])
    }

    func testDownloadReportsBytesAndKeepsAFileOnDisk() async throws {
        let (base, destination) = try await fixture()
        let recorder = DownloadProgressRecorder()
        let file = try await IPAURLDownloadService().download(base.appending(path: "ok"), to: destination, progress: recorder.append)
        XCTAssertEqual(try Data(contentsOf: file).prefix(4), Data([0x50, 0x4b, 3, 4]))
        XCTAssertEqual(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, 262148)
        XCTAssertTrue(recorder.snapshots.contains { $0.received > 0 && $0.expected == 262148 })
        XCTAssertEqual(file.pathExtension, "ipa")
    }

    func testHTMLIsRejectedWithoutKeepingAnImport() async throws {
        let (base, destination) = try await fixture()
        do {
            _ = try await IPAURLDownloadService().download(base.appending(path: "html"), to: destination) { _ in }
            XCTFail("A website is not an IPA archive.")
        } catch IPADownloadError.invalidArchive { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testPermanentHTTPFailureIsNotRetried() async throws {
        let (base, destination) = try await fixture()
        do {
            _ = try await IPAURLDownloadService().download(base.appending(path: "missing"), to: destination) { _ in }
            XCTFail("HTTP 404 must fail.")
        } catch IPADownloadError.http(404, _) { }
        let (count, _) = try await URLSession.shared.data(from: base.appending(path: "count"))
        XCTAssertEqual(String(data: count, encoding: .utf8), "1")
    }

    func testTransientFailureHonorsRetryAndThenSucceeds() async throws {
        let (base, destination) = try await fixture()
        let recorder = DownloadProgressRecorder()
        let file = try await IPAURLDownloadService().download(base.appending(path: "retry"), to: destination, progress: recorder.append)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(recorder.snapshots.contains { $0.retryDelay == 1 && $0.attempt == 2 })
    }

    func testCancellationStopsTransferAndLeavesNoImportedFile() async throws {
        let (base, destination) = try await fixture()
        let recorder = DownloadProgressRecorder()
        let task = Task { try await IPAURLDownloadService().download(base.appending(path: "slow"), to: destination, progress: recorder.append) }
        for _ in 0..<100 {
            if recorder.snapshots.contains(where: { $0.received > 0 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation cannot complete as a successful import.") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty) ?? true)
    }

    func testLegitimateRedirectsAndInputPolicy() async throws {
        let (base, destination) = try await fixture()
        let file = try await IPAURLDownloadService().download(base.appending(path: "redirect"), to: destination) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(IPADownloadPolicy.url("https://user:password@example.com/file.ipa"))
        XCTAssertNil(IPADownloadPolicy.url("file:///tmp/source.ipa"))
        XCTAssertNotNil(IPADownloadPolicy.url("https://example.com/release?signature=fixture"))
        XCTAssertNil(IPADownloadPolicy.retryDelay(IPADownloadError.http(403, nil), attempt: 1))
        XCTAssertNil(IPADownloadPolicy.retryDelay(URLError(.cancelled), attempt: 1))
        XCTAssertNil(IPADownloadPolicy.retryDelay(URLError(.timedOut), attempt: 3))
    }
    private func pausedTransfer() async throws -> (URL, URL, PausedIPADownload) {
        let (base, destination) = try await fixture()
        let control = IPADownloadControl(), recorder = DownloadProgressRecorder()
        let url = base.appending(path: "resumable")
        let task = Task { try await IPAURLDownloadService().download(url, to: destination, control: control, progress: recorder.append) }
        for _ in 0..<300 {
            if recorder.snapshots.contains(where: { $0.canPause && $0.received > 0 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        control.pause()
        do { _ = try await task.value; throw SideloomError.message("Transfer did not pause") }
        catch let paused as PausedIPADownload { return (url, destination, paused) }
    }

    func testPauseAndResumePreservesExactArchiveBytes() async throws {
        let (url, destination, paused) = try await pausedTransfer()
        let file = try await IPAURLDownloadService().download(url, to: destination, resume: paused) { _ in }
        XCTAssertEqual(try Data(contentsOf: file), Data([0x50, 0x4b, 3, 4]) + Data(repeating: 120, count: 262144))
    }

    func testResumeRejectsChangedRemoteFile() async throws {
        let (url, destination, paused) = try await pausedTransfer()
        let changed = destination.deletingLastPathComponent().appending(path: "port.changed")
        try Data().write(to: changed)
        do {
            _ = try await IPAURLDownloadService().download(url, to: destination, resume: paused) { _ in }
            XCTFail("Changed ETag must reject resume")
        } catch { XCTAssertTrue(error.localizedDescription.contains("remote file changed")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

}
