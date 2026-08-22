import XCTest
@testable import macmcp

/// `context/enumerate` (ADR-011 decision 6) is a JSON-RPC method dispatched
/// directly from `main.swift`'s top-level `switch req.method`, not a tool --
/// so it has no `ToolRegistry` entry to call in-process the way
/// `MCPCallContextTests` drives `tools/call`. Top-level code in a `main.swift`
/// executable is not itself an invocable symbol, `@testable import` or not,
/// so the only way to exercise the dispatch is stdio-level: run the real
/// `macmcp` binary as a subprocess and speak JSON-RPC to it over its stdin
/// and stdout, exactly as relay does.
///
/// This stays inside the suite's hermetic rule ("no test may talk to
/// Mail.app") because every case here is refused before `MailService`
/// touches Mail at all: an unknown method, an unknown `contextSchema` field,
/// and a field that is declared but not `enumerable: true` are all decided
/// against `mailContextSchema` alone, in `main.swift`, before
/// `MailService.enumerateContext` -- the one function that would spawn
/// `osascript` -- is ever called. A positive `mail_accounts` /
/// `mail_mailboxes` enumeration is not exercised here for exactly that
/// reason; it belongs with `MailSourceOnDiskTests`, against the real fixture.
final class ContextEnumerateDispatchTests: XCTestCase {
    private var process: Process!
    private var stdin: FileHandle!
    private var stdout: FileHandle!
    private var stdoutBuffer = Data()
    private var nextID = 0

    override func setUpWithError() throws {
        let executable = try Self.macmcpExecutableURL()
        process = Process()
        process.executableURL = executable
        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = Pipe() // discarded; nothing here should write to it
        stdin = inPipe.fileHandleForWriting
        stdout = outPipe.fileHandleForReading
        try process.run()
    }

    override func tearDownWithError() throws {
        stdin?.closeFile()
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    /// `swift test` builds the test bundle and the `macmcp` executable as
    /// sibling products of the same build directory (both land in
    /// `.build/<triple>/debug/` next to each other), so the sibling of the
    /// running `.xctest` bundle is the binary under test -- no environment
    /// variable or hardcoded path required, and it is always the build this
    /// test run just produced.
    private static func macmcpExecutableURL() throws -> URL {
        let testBundleURL = Bundle(for: ContextEnumerateDispatchTests.self).bundleURL
        let candidate = testBundleURL.deletingLastPathComponent().appendingPathComponent("macmcp")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw XCTSkip("macmcp executable not found at \(candidate.path) -- expected next to the test bundle")
        }
        return candidate
    }

    private struct DispatchFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// Sends one JSON-RPC request and returns the decoded response object.
    private func send(method: String, params: [String: Any]?) throws -> [String: Any] {
        nextID += 1
        var request: [String: Any] = ["jsonrpc": "2.0", "id": nextID, "method": method]
        if let params { request["params"] = params }
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(0x0A)
        stdin.write(data)

        let line = try readLine(timeout: 15)
        guard let lineData = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            throw DispatchFailure(message: "not a JSON object on stdout: \(line)")
        }
        return obj
    }

    /// Blocks (off the test's own thread, under a wall-clock timeout) until a
    /// newline-terminated line has accumulated in `stdoutBuffer`.
    private func readLine(timeout: TimeInterval) throws -> String {
        let semaphore = DispatchSemaphore(value: 0)
        var line: String?
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            while true {
                if let newlineIndex = self.stdoutBuffer.firstIndex(of: 0x0A) {
                    let lineData = self.stdoutBuffer[..<newlineIndex]
                    self.stdoutBuffer.removeSubrange(...newlineIndex)
                    line = String(data: lineData, encoding: .utf8) ?? ""
                    semaphore.signal()
                    return
                }
                let chunk = self.stdout.availableData
                if chunk.isEmpty {
                    semaphore.signal() // EOF: the process exited or closed stdout
                    return
                }
                self.stdoutBuffer.append(chunk)
            }
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success, let line else {
            throw DispatchFailure(message: "timed out waiting for a line of stdout from macmcp")
        }
        return line
    }

    // MARK: - The method still returns -32601 for anything it does not implement

    func testAnUnknownMethodStillReturnsMinus32601() throws {
        let response = try send(method: "totally/unsupported", params: nil)
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32601)
        let message = try XCTUnwrap(error["message"] as? String)
        XCTAssertTrue(message.contains("totally/unsupported"), message)
        XCTAssertNil(response["result"])
    }

    // MARK: - context/enumerate error paths

    func testMissingFieldParameterIsInvalidParams() throws {
        let response = try send(method: "context/enumerate", params: [:])
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
    }

    /// A field `contextSchema` has never heard of.
    func testAnUnknownFieldIsRefusedAsInvalidParams() throws {
        let response = try send(method: "context/enumerate", params: ["field": "no_such_field"])
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        let message = try XCTUnwrap(error["message"] as? String)
        XCTAssertTrue(message.contains("no_such_field"), message)
        XCTAssertNil(response["result"])
    }

    /// `write_dirs` is declared in `contextSchema` but not `enumerable: true`
    /// -- it is `source: "project_path"`, which relay derives and an operator
    /// never picks from a list. This is the one the task names explicitly:
    /// "write_dirs must be refused this way."
    func testANonEnumerableFieldIsRefusedAsInvalidParams() throws {
        let response = try send(method: "context/enumerate", params: ["field": "write_dirs"])
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        let message = try XCTUnwrap(error["message"] as? String)
        XCTAssertTrue(message.contains("write_dirs"), message)
        XCTAssertNil(response["result"])
    }

    // MARK: - initialize still advertises the schema this dispatch reads

    /// Not a `context/enumerate` case, but the fact this dispatch and
    /// `initialize`'s `contextSchema` are reading the *same* declaration is
    /// exactly what keeps `write_dirs`'s refusal above from silently going
    /// stale if the schema changes shape.
    func testInitializeStillDeclaresTheEnumerableFieldsThisDispatchHonours() throws {
        let response = try send(method: "initialize", params: [:])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let serverInfo = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        let schema = try XCTUnwrap(serverInfo["contextSchema"] as? [String: Any])
        let mailAccounts = try XCTUnwrap(schema["mail_accounts"] as? [String: Any])
        XCTAssertEqual(mailAccounts["enumerable"] as? Bool, true)
        let writeDirs = try XCTUnwrap(schema["write_dirs"] as? [String: Any])
        XCTAssertNil(writeDirs["enumerable"], "write_dirs must stay non-enumerable for the refusal test above to mean anything")
    }
}
