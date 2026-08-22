import XCTest
@testable import macmcp

/// Speaks JSON-RPC to the real `macmcp` binary over stdin/stdout, exactly as
/// relay does.
///
/// Top-level code in a `main.swift` executable is not an invocable symbol,
/// `@testable import` or not, so anything decided in `main.swift`'s own
/// `switch req.method` -- the `context/enumerate` dispatch, and whether a
/// `_meta` was well formed enough to mean anything -- has no in-process seam
/// to call. Running the binary is the only way to exercise it, and it is also
/// the honest one: what is under test is the wire behaviour a client sees.
///
/// **Every case built on this must be decided before Mail is touched**, or the
/// suite stops being hermetic. Both subclasses hold to that: an unknown
/// method, an unknown or non-enumerable `contextSchema` field and a malformed
/// `_meta` are all answered from `main.swift` alone, before `ToolRegistry`
/// dispatches or `MailService` spawns an `osascript`.
class StdioServerTestCase: XCTestCase {
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
    static func macmcpExecutableURL() throws -> URL {
        let testBundleURL = Bundle(for: StdioServerTestCase.self).bundleURL
        let candidate = testBundleURL.deletingLastPathComponent().appendingPathComponent("macmcp")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw XCTSkip("macmcp executable not found at \(candidate.path) -- expected next to the test bundle")
        }
        return candidate
    }

    struct DispatchFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// Sends one JSON-RPC request and returns the decoded response object.
    func send(method: String, params: [String: Any]?) throws -> [String: Any] {
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
    func readLine(timeout: TimeInterval) throws -> String {
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

}
