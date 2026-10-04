import Foundation
import Security

/// Structured stderr logging (stdout is the MCP protocol and is never written here).
/// Every line carries the nine keys of relay's logging schema.
enum LogLevel: String {
    case error, warn, info, debug

    var rank: Int {
        switch self {
        case .error: return 0
        case .warn: return 1
        case .info: return 2
        case .debug: return 3
        }
    }
}

enum TraceID {
    static func make() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns `raw` when it is 8-64 of [A-Za-z0-9_-], else a fresh ID.
    /// The rejected value is never logged.
    static func accept(_ raw: String?) -> String {
        guard let raw, (8...64).contains(raw.utf8.count),
              raw.utf8.allSatisfy({ c in
                  (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A)
                      || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x2D
              })
        else { return make() }
        return raw
    }
}

final class StructuredLog {
    private static let maxText = 500
    private static let debugWindow: TimeInterval = 30 * 60
    private static let reserved: Set<String> = [
        "ts", "level", "msg", "service", "op", "status", "duration_ms", "error", "trace_id",
    ]

    private let service: String
    private let now: () -> Date
    private let sink: (String) -> Void
    private let lock = NSLock()
    private var level: LogLevel
    private let debugDeadline: Date?

    init(service: String, levelSetting: String?, now: @escaping () -> Date = Date.init,
         sink: @escaping (String) -> Void) {
        self.service = service
        self.now = now
        self.sink = sink
        let parsed = levelSetting.flatMap { LogLevel(rawValue: $0.lowercased()) } ?? .info
        self.level = parsed
        self.debugDeadline = parsed == .debug ? now().addingTimeInterval(Self.debugWindow) : nil
    }

    static let shared: StructuredLog = {
        let env = ProcessInfo.processInfo.environment
        let id = env["RELAY_SERVICE_ID"] ?? ""
        return StructuredLog(
            service: id.isEmpty ? "macmcp" : id,
            levelSetting: env["RELAY_LOG_LEVEL"],
            sink: { line in
                if let data = (line + "\n").data(using: .utf8) {
                    FileHandle.standardError.write(data)
                }
            })
    }()

    func log(_ level: LogLevel, _ msg: String, op: String? = nil, status: String? = nil,
             durationMs: Int? = nil, error: String? = nil, traceId: String? = nil,
             attrs: [String: String] = [:]) {
        lock.lock()
        defer { lock.unlock() }
        if let deadline = debugDeadline, self.level == .debug, now() >= deadline {
            self.level = .info
            emit(.warn, "debug logging ended after 30 minutes; level is now info",
                 op: "log", status: "error", durationMs: 0, error: "debug_window_expired", traceId: "", attrs: [:])
        }
        guard level.rank <= self.level.rank else { return }
        emit(level, msg, op: op ?? "log",
             status: status ?? ((level == .error || level == .warn) ? "error" : "ok"),
             durationMs: durationMs ?? 0, error: error ?? "", traceId: traceId ?? "", attrs: attrs)
    }

    private func emit(_ level: LogLevel, _ msg: String, op: String, status: String,
                      durationMs: Int, error: String, traceId: String, attrs: [String: String]) {
        var obj: [String: Any] = [:]
        for (k, v) in attrs {
            obj[Self.reserved.contains(k) ? "attr_" + k : k] = v
        }
        obj["ts"] = Self.timestamp(now())
        obj["level"] = level.rawValue
        obj["msg"] = Self.truncate(msg)
        obj["service"] = service
        obj["op"] = op
        obj["status"] = status
        obj["duration_ms"] = NSNumber(value: durationMs)
        obj["error"] = Self.truncate(error)
        obj["trace_id"] = traceId
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        sink(line)
    }

    private static func truncate(_ s: String) -> String {
        let scalars = s.unicodeScalars
        guard scalars.count > maxText else { return s }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars.prefix(maxText))
        return String(out)
    }

    private static func timestamp(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
}
