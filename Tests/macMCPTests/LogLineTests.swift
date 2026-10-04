import XCTest
import Foundation
@testable import macmcp

// MARK: - Test-local JSON Schema checker (exactly the keywords the schema uses)

private enum MiniSchema {
    static let ignored: Set<String> = ["$schema", "$id", "title", "description"]
    static let supported: Set<String> = [
        "type", "required", "enum", "pattern", "maxLength", "minLength",
        "minimum", "additionalProperties", "properties",
    ]

    static func load() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Fixtures/logging-schema.json")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(obj as? [String: Any])
    }

    private static func isBool(_ v: Any) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    static func validate(_ value: Any, _ schema: [String: Any], at path: String = "$") -> [String] {
        var errs: [String] = []
        for key in schema.keys where !ignored.contains(key) && !supported.contains(key) {
            errs.append("\(path): unsupported schema keyword \(key)")
        }
        if let t = schema["type"] as? String {
            switch t {
            case "object": if !(value is [String: Any]) { errs.append("\(path): not object") }
            case "string": if !(value is String) { errs.append("\(path): not string") }
            case "integer":
                if isBool(value) || !(value is NSNumber) || (value as! NSNumber).doubleValue.rounded() != (value as! NSNumber).doubleValue {
                    errs.append("\(path): not integer")
                }
            default: errs.append("\(path): unsupported type \(t)")
            }
        }
        if let e = schema["enum"] as? [String] {
            if let s = value as? String { if !e.contains(s) { errs.append("\(path): \(s) not in enum") } }
            else { errs.append("\(path): enum on non-string") }
        }
        if let s = value as? String {
            if let p = schema["pattern"] as? String {
                let re = try? NSRegularExpression(pattern: p)
                if re?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) == nil {
                    errs.append("\(path): \(s) fails pattern \(p)")
                }
            }
            if let m = schema["maxLength"] as? Int, s.count > m { errs.append("\(path): too long") }
            if let m = schema["minLength"] as? Int, s.count < m { errs.append("\(path): too short") }
        }
        if let m = schema["minimum"] as? Double, let n = value as? NSNumber, n.doubleValue < m {
            errs.append("\(path): below minimum")
        }
        if let obj = value as? [String: Any] {
            for r in schema["required"] as? [String] ?? [] where obj[r] == nil {
                errs.append("\(path): missing \(r)")
            }
            let props = schema["properties"] as? [String: Any] ?? [:]
            for (k, sub) in props {
                if let v = obj[k], let subSchema = sub as? [String: Any] {
                    errs += validate(v, subSchema, at: "\(path).\(k)")
                }
            }
            if let ap = schema["additionalProperties"] as? Bool, !ap {
                for k in obj.keys where props[k] == nil { errs.append("\(path): extra \(k)") }
            }
        }
        return errs
    }
}

// MARK: - Helpers

private let nineKeys = ["ts", "level", "msg", "service", "op", "status", "duration_ms", "error", "trace_id"]

private final class Capture {
    var lines: [String] = []
    var sink: (String) -> Void { { [self] in lines.append($0.trimmingCharacters(in: .whitespacesAndNewlines)) } }
    func objects() throws -> [[String: Any]] {
        try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    }
}

private func makeLog(_ cap: Capture, level: String? = nil, now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) }) -> StructuredLog {
    StructuredLog(service: "macmcp-test", levelSetting: level, now: now, sink: cap.sink)
}

final class LogLineTests: XCTestCase {

    // MARK: Unit

    func testEveryLevelWithEntityAttrsValidatesAgainstSchema() throws {
        let schema = try MiniSchema.load()
        let cap = Capture()
        let log = makeLog(cap, level: "debug")
        for lvl in [LogLevel.error, .warn, .info, .debug] {
            log.log(lvl, "plain \(lvl.rawValue)")
            log.log(lvl, "full", op: "tool.call", status: "ok", durationMs: 12, error: "", traceId: "abcdef1234567890",
                    attrs: ["session_id": "s1", "job_id": "j1", "run_id": "r1", "tool": "acme_tool"])
        }
        let objs = try cap.objects()
        XCTAssertEqual(objs.count, 8)
        for o in objs {
            XCTAssertEqual(MiniSchema.validate(o, schema), [], "\(o)")
            for k in nineKeys { XCTAssertNotNil(o[k], "missing \(k)") }
        }
    }

    func testCheckerRejectsUnknownKeywordAndBadLine() throws {
        XCTAssertFalse(MiniSchema.validate(["a": 1], ["type": "object", "oneOf": []]).isEmpty)
        XCTAssertFalse(MiniSchema.validate(["ts": "x"], try MiniSchema.load()).isEmpty)
    }

    func testDefaults() throws {
        let cap = Capture()
        let log = makeLog(cap, level: "info")
        log.log(.error, "e"); log.log(.warn, "w"); log.log(.info, "i")
        let o = try cap.objects()
        XCTAssertEqual(o.map { $0["status"] as? String }, ["error", "error", "ok"])
        for x in o {
            XCTAssertEqual(x["op"] as? String, "log")
            XCTAssertEqual(x["duration_ms"] as? Int, 0)
            XCTAssertEqual(x["error"] as? String, "")
            XCTAssertEqual(x["trace_id"] as? String, "")
            XCTAssertEqual(x["service"] as? String, "macmcp-test")
        }
        XCTAssertEqual(o[0]["level"] as? String, "error")
    }

    func testMsgAndErrorTruncateAt500() throws {
        let cap = Capture()
        makeLog(cap).log(.info, String(repeating: "m", count: 900), error: String(repeating: "e", count: 900))
        let o = try XCTUnwrap(cap.objects().first)
        XCTAssertEqual((o["msg"] as? String)?.count, 500)
        XCTAssertEqual((o["error"] as? String)?.count, 500)
    }

    func testTruncationCountsUnicodeScalarsNotGraphemes() throws {
        // 1 base + 600 combining marks compose a single grapheme but 601 scalars.
        let s = "e" + String(repeating: "\u{0301}", count: 600)
        let cap = Capture()
        makeLog(cap).log(.info, s, error: s)
        let o = try XCTUnwrap(cap.objects().first)
        XCTAssertEqual((o["msg"] as? String)?.unicodeScalars.count, 500)
        XCTAssertEqual((o["error"] as? String)?.unicodeScalars.count, 500)
    }

    func testReservedAttrsAreRenamed() throws {
        let cap = Capture()
        makeLog(cap).log(.info, "real", traceId: "abcdef1234567890",
                         attrs: ["ts": "A", "level": "B", "msg": "C", "service": "D", "trace_id": "E", "tool": "T"])
        let o = try XCTUnwrap(cap.objects().first)
        XCTAssertEqual(o["msg"] as? String, "real")
        XCTAssertEqual(o["service"] as? String, "macmcp-test")
        XCTAssertEqual(o["level"] as? String, "info")
        XCTAssertEqual(o["trace_id"] as? String, "abcdef1234567890")
        XCTAssertNotEqual(o["ts"] as? String, "A")
        for (k, v) in ["ts": "A", "level": "B", "msg": "C", "service": "D", "trace_id": "E"] {
            XCTAssertEqual(o["attr_\(k)"] as? String, v)
        }
        XCTAssertEqual(o["tool"] as? String, "T")
    }

    func testLevelSettingFiltering() {
        for setting in [nil, "", "verbose", "DEBUGGY"] as [String?] {
            let cap = Capture()
            let log = makeLog(cap, level: setting)
            log.log(.debug, "d"); log.log(.info, "i")
            XCTAssertEqual(cap.lines.count, 1, "setting \(String(describing: setting))")
        }
        let cap = Capture()
        let log = makeLog(cap, level: "error")
        log.log(.warn, "w"); log.log(.info, "i"); log.log(.error, "e")
        XCTAssertEqual(cap.lines.count, 1)
    }

    func testDebugExpiresAfterThirtyMinutesWithOneWarn() throws {
        var t = Date(timeIntervalSince1970: 1_700_000_000)
        let cap = Capture()
        let log = makeLog(cap, level: "debug", now: { t })
        log.log(.debug, "early")
        t += 29 * 60
        log.log(.debug, "still on")
        XCTAssertEqual(cap.lines.count, 2)
        t += 2 * 60
        log.log(.info, "after")
        log.log(.debug, "dropped")
        log.log(.info, "again")
        let o = try cap.objects()
        XCTAssertEqual(o.map { $0["msg"] as? String }.count, 5)
        XCTAssertEqual(o[2]["level"] as? String, "warn")
        XCTAssertEqual(o[2]["error"] as? String, "debug_window_expired")
        XCTAssertEqual(o[3]["msg"] as? String, "after")
        XCTAssertEqual(o[4]["msg"] as? String, "again")
        XCTAssertEqual(o.filter { $0["level"] as? String == "warn" }.count, 1)
        XCTAssertEqual(MiniSchema.validate(o[2], try MiniSchema.load()), [])
    }

    func testTraceIDs() {
        let id = TraceID.make()
        XCTAssertNotNil(id.range(of: "^[0-9a-f]{32}$", options: .regularExpression))
        XCTAssertNotEqual(id, TraceID.make())
        XCTAssertEqual(TraceID.accept("abcdef1234567890"), "abcdef1234567890")
        XCTAssertEqual(TraceID.accept("a_b-c_d-1"), "a_b-c_d-1")
        let max = String(repeating: "a", count: 64)
        XCTAssertEqual(TraceID.accept(max), max)
        for bad in [nil, "", "short", "bad id!", String(repeating: "a", count: 65), "abcdef12\n"] as [String?] {
            let out = TraceID.accept(bad)
            XCTAssertNotEqual(out, bad)
            XCTAssertNotNil(out.range(of: "^[0-9a-f]{32}$", options: .regularExpression))
        }
    }

    // MARK: Process level

    private func executableURL() throws -> URL {
        let bundle = Bundle.allBundles.first { $0.bundleURL.pathExtension == "xctest" }
        let dir = try XCTUnwrap(bundle?.bundleURL.deletingLastPathComponent())
        let exe = dir.appendingPathComponent("macmcp")
        guard FileManager.default.isExecutableFile(atPath: exe.path) else {
            throw XCTSkip("macmcp executable not found next to the xctest bundle at \(exe.path); run `swift build` first")
        }
        return exe
    }

    private func run(meta: String?, tool: String = "no_such_tool", env extra: [String: String] = [:]) throws -> (out: String, err: String) {
        let exe = try executableURL()
        let metaPart = meta.map { ",\"_meta\":\($0)" } ?? ""
        let req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"\(tool)\",\"arguments\":{\"secret\":\"CANARY-TOKEN-7731\"}\(metaPart)}}\n"
        let p = Process()
        p.executableURL = exe
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "RELAY_LOG_LEVEL")
        env.removeValue(forKey: "RELAY_SERVICE_ID")
        for (k, v) in extra { env[k] = v }
        p.environment = env
        let inP = Pipe(), outP = Pipe(), errP = Pipe()
        p.standardInput = inP; p.standardOutput = outP; p.standardError = errP
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        for (pipe, isOut) in [(outP, true), (errP, false)] {
            group.enter()
            DispatchQueue.global().async {
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                if isOut { outData = d } else { errData = d }
                group.leave()
            }
        }
        try p.run()
        inP.fileHandleForWriting.write(Data(req.utf8))
        try inP.fileHandleForWriting.close()
        if group.wait(timeout: .now() + 30) == .timedOut { p.terminate(); XCTFail("macmcp did not exit") }
        p.waitUntilExit()
        return (String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }

    private func jsonLines(_ s: String) -> [[String: Any]] {
        s.split(separator: "\n").filter { $0.hasPrefix("{") }.compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    private func toolCallLine(_ err: String) throws -> [String: Any] {
        let schema = try MiniSchema.load()
        let lines = jsonLines(err)
        XCTAssertEqual(lines.count, err.split(separator: "\n").filter { $0.hasPrefix("{") }.count, "unparseable JSON line on stderr")
        for l in lines { XCTAssertEqual(MiniSchema.validate(l, schema), [], "\(l)") }
        return try XCTUnwrap(lines.first { $0["op"] as? String == "tool.call" }, "no tool.call line in: \(err)")
    }

    func testStdoutCarriesOnlyTheResponseAndStderrCarriesTheSchemaLine() throws {
        let (out, err) = try run(meta: nil)
        let outLines = out.split(separator: "\n")
        XCTAssertEqual(outLines.count, 1)
        for l in outLines {
            let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any])
            XCTAssertNotNil(o["jsonrpc"])
            XCTAssertNil(o["ts"]); XCTAssertNil(o["service"])
            XCTAssertNil(o["_meta"])
            XCTAssertNil((o["result"] as? [String: Any])?["_meta"])
        }
        let line = try toolCallLine(err)
        XCTAssertEqual(line["status"] as? String, "error")
        XCTAssertFalse(err.contains("CANARY-TOKEN-7731"), "arguments leaked into the log")
        // absent _meta: an ID is created
        XCTAssertNotNil((line["trace_id"] as? String)?.range(of: "^[0-9a-f]{32}$", options: .regularExpression))
    }

    func testInboundTraceIDIsKeptWhenValid() throws {
        let (out, err) = try run(meta: "{\"trace_id\":\"abcdef1234567890\"}")
        XCTAssertEqual(try toolCallLine(err)["trace_id"] as? String, "abcdef1234567890")
        XCTAssertFalse(out.contains("trace_id"), "macMCP must add nothing to the response")
    }

    func testInvalidInboundTraceIDIsReplacedAndNeverLogged() throws {
        let (out, err) = try run(meta: "{\"trace_id\":\"bad id!\"}")
        let id = try XCTUnwrap(try toolCallLine(err)["trace_id"] as? String)
        XCTAssertNotNil(id.range(of: "^[0-9a-f]{32}$", options: .regularExpression))
        XCTAssertFalse(err.contains("bad id!"))
        XCTAssertFalse(out.contains("trace_id"))
    }

    func testUnknownToolResponseBytesAndWarnLine() throws {
        let (out, err) = try run(meta: nil)
        XCTAssertEqual(out, "{\"id\":1,\"jsonrpc\":\"2.0\",\"result\":{\"content\":[{\"text\":\"unknown tool: no_such_tool\",\"type\":\"text\"}],\"isError\":true}}\n")
        let calls = jsonLines(err).filter { $0["op"] as? String == "tool.call" }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0]["level"] as? String, "warn")
        XCTAssertEqual(calls[0]["status"] as? String, "error")
        XCTAssertEqual(calls[0]["tool"] as? String, "no_such_tool")
    }

    func testEnvLevelAndServiceIdReachTheLog() throws {
        let (_, quiet) = try run(meta: nil, env: ["RELAY_LOG_LEVEL": "error", "RELAY_SERVICE_ID": "testsvc"])
        XCTAssertTrue(jsonLines(quiet).filter { $0["op"] as? String == "tool.call" }.isEmpty)
        let (_, loud) = try run(meta: nil, env: ["RELAY_LOG_LEVEL": "warn", "RELAY_SERVICE_ID": "testsvc"])
        XCTAssertEqual(try toolCallLine(loud)["service"] as? String, "testsvc")
    }

    func testScopeDeniedCallLogsWarnDenied() throws {
        let (_, err) = try run(meta: "{\"project_id\":\"p\",\"trace_id\":\"abcdef1234567890\"}", tool: "mail_list_accounts")
        let line = try toolCallLine(err)
        XCTAssertEqual(line["level"] as? String, "warn")
        XCTAssertEqual(line["status"] as? String, "denied")
        XCTAssertEqual(line["trace_id"] as? String, "abcdef1234567890")
    }
}
