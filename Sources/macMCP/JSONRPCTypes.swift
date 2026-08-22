import Foundation

// MARK: - JSON-RPC 2.0 Wire Types

struct JSONRPCRequest: Decodable {
    let jsonrpc: String
    let id: JSONValue?
    let method: String
    let params: JSONObject?
}

struct JSONRPCResponse: Encodable {
    let jsonrpc: String = "2.0"
    let id: JSONValue?
    var result: JSONValue?
    var error: JSONRPCError?
}

struct JSONRPCError: Encodable {
    let code: Int
    let message: String
}

// MARK: - Dynamic JSON Value

enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// A string, or the nearest thing to one, for an argument whose value is an
    /// identifier rather than prose.
    ///
    /// A message id looks like a number and models write it like one. The schema
    /// says `string`, and a client that emits `"message_id": 63926` unquoted --
    /// which several do, LM Studio among them -- was answered with
    /// `message_id is required`: a message about a missing argument, for an
    /// argument that was right there. The two renderings identify the same
    /// message, so both are read.
    ///
    /// The second rendering is a client bug rather than a model one: the value
    /// arrives already quoted and is quoted again, so the decoded string is
    /// `"63926"` with the quote characters *in* it. Those are stripped, because
    /// no id here can begin and end with a quote -- an RFC Message-ID is
    /// delimited by angle brackets.
    var coercedStringValue: String? {
        switch self {
        case .string(var s):
            while s.count >= 2 && s.hasPrefix("\"") && s.hasSuffix("\"") {
                s = String(s.dropFirst().dropLast())
            }
            return s
        case .int(let i): return String(i)
        case .double(let d):
            // A whole number that arrived as a double is an id, not a
            // measurement: 63926.0 must not become "63926.0".
            if d.isFinite, d == d.rounded(.towardZero) { return String(Int(d)) }
            return d.isFinite ? String(d) : nil
        default: return nil
        }
    }

    var intValue: Int? {
        if case .int(let i) = self { return i }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// The strings in this value, whether it arrived as one string or an array
    /// of them. Non-string array entries are dropped.
    var stringsValue: [String]? {
        if case .string(let s) = self { return [s] }
        if case .array(let a) = self { return a.compactMap(\.stringValue) }
        return nil
    }
}

typealias JSONObject = [String: JSONValue]

// MARK: - MCP Tool Types

struct MCPTool: Encodable {
    let name: String
    let description: String
    let inputSchema: JSONValue
    var annotations: MCPAnnotations?
    var category: String?
}

struct MCPAnnotations: Encodable {
    var readOnlyHint: Bool?
}

struct MCPContent: Encodable {
    let type: String
    let text: String
}

struct MCPCallResult: Encodable {
    let content: [MCPContent]
    var isError: Bool?
}

func textResult(_ text: String) -> MCPCallResult {
    MCPCallResult(content: [MCPContent(type: "text", text: text)])
}

func errorResult(_ message: String) -> MCPCallResult {
    MCPCallResult(content: [MCPContent(type: "text", text: message)], isError: true)
}

func jsonResult(_ value: Any) -> MCPCallResult {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
       let str = String(data: data, encoding: .utf8) {
        return textResult(str)
    }
    return errorResult("failed to serialize result")
}
