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
    private func fixture() async throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "SlipDownload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ready = root.appending(path: "port")
        let program = #"""
        import http.server,sys,pathlib,time,threading
        counts={}; lock=threading.Lock()
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self,*args):pass
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
                self.send_response(status)
                self.send_header('Content-Length',str(len(body)))
                if status==503:self.send_header('Retry-After','1')
                self.end_headers()
                try:
                    for start in range(0,len(body),4096):
                        self.wfile.write(body[start:start+4096]);self.wfile.flush()
                        if self.path=='/slow':time.sleep(.05)
                except (BrokenPipeError,ConnectionResetError):pass
        server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
        pathlib.Path(sys.argv[1]).write_text(str(server.server_port))
        server.serve_forever()
        """#
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        child.arguments = ["python3", "-u", "-c", program, ready.path]
        child.standardError = FileHandle.nullDevice
        try child.run()
        addTeardownBlock {
            if child.isRunning { child.terminate(); child.waitUntilExit() }
            try? FileManager.default.removeItem(at: root)
        }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: ready.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let port = try String(contentsOf: ready, encoding: .utf8)
        return (URL(string: "http://127.0.0.1:\(port)")!, root.appending(path: "Imports"))
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
}
