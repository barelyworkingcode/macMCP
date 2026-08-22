import Foundation

/// What a handler receives for one `tools/call`: the ordinary arguments, plus
/// whatever the caller put in `_meta`.
///
/// MCP places `_meta` as a sibling of `name`/`arguments` inside `params`. Until
/// now macMCP read `arguments` and dropped `_meta` on the floor entirely (ADR-011
/// finding 3) -- there was no side channel to a handler at all, `ToolHandler`
/// being a bare `(JSONObject?) -> MCPCallResult`. Relay has been injecting
/// `_meta.project_id` into every macMCP call since ADR-007 and macMCP has never
/// read it.
///
/// This is a struct rather than a second positional `JSONObject?` on
/// `ToolHandler` on purpose: a bare second optional at the ~47 registration
/// call sites is easy to pass in the wrong order (or transpose with a third
/// one later), where a named field cannot be.
///
/// `meta` is `nil` exactly when `_meta` was absent from the request -- which is
/// every request today, since nothing yet injects one -- and that has to stay
/// distinguishable from `_meta` being present but empty (see `MailScope`,
/// which is the first thing built on top of this). Most handlers ignore `meta`
/// entirely; `let args = ctx.arguments` at the top of a handler is the whole of
/// what most of them needed to change.
struct MCPCallContext {
    let arguments: JSONObject?
    let meta: JSONObject?

    /// The name this call was dispatched under.
    ///
    /// A handler obviously knows which tool it is. What it cannot otherwise
    /// know is the *string* relay and `mailContextSchema` both use to talk
    /// about it, and that string is what a `scope: "restrict"` field's
    /// `applies_to` globs are matched against (`restrictFieldsGoverning`). So
    /// the presence check ADR-011 decision 4 requires can be driven by the
    /// declaration rather than by a list re-typed at every handler -- which is
    /// how four tools ended up checking a field they were declared to be
    /// governed by and did not consult.
    ///
    /// Defaulted so every existing construction, in `main.swift` and in the
    /// tests alike, keeps compiling; the registry always supplies it.
    let toolName: String

    init(arguments: JSONObject? = nil, meta: JSONObject? = nil, toolName: String = "") {
        self.arguments = arguments
        self.meta = meta
        self.toolName = toolName
    }
}

typealias ToolHandler = (MCPCallContext) -> MCPCallResult

struct ToolRegistration {
    let tool: MCPTool
    let handler: ToolHandler
}

class ToolRegistry {
    private var registrations: [String: ToolRegistration] = [:]

    func register(_ tool: MCPTool, category: String, handler: @escaping ToolHandler) {
        var t = tool
        t.category = category
        registrations[t.name] = ToolRegistration(tool: t, handler: handler)
    }

    func allTools() -> [MCPTool] {
        registrations.values.map(\.tool).sorted { $0.name < $1.name }
    }

    /// `meta` defaults to `nil` so every existing caller -- `main.swift` before
    /// this change, and every test -- keeps compiling and behaving exactly as
    /// it did when `_meta` did not exist as a concept here.
    func call(name: String, arguments: JSONObject?, meta: JSONObject? = nil) -> MCPCallResult {
        guard let reg = registrations[name] else {
            return errorResult("unknown tool: \(name)")
        }
        return reg.handler(MCPCallContext(arguments: arguments, meta: meta, toolName: name))
    }
}

// Schema helpers
func emptySchema() -> JSONValue {
    .object(["type": .string("object"), "properties": .object([:]), "required": .array([])])
}

func schema(properties: [String: JSONValue], required: [String] = []) -> JSONValue {
    .object([
        "type": .string("object"),
        "properties": .object(properties),
        "required": .array(required.map { .string($0) })
    ])
}

func stringProp(_ description: String) -> JSONValue {
    .object(["type": .string("string"), "description": .string(description)])
}

/// An identifier that a model may write as a bare number. The schema accepts
/// both renderings, and `coercedStringValue` reads either as a string. Declaring
/// it `string` alone made a client sending `63926` fail schema validation
/// before the call was ever made.
func stringOrIntProp(_ description: String) -> JSONValue {
    .object([
        "type": .array([.string("string"), .string("integer")]),
        "description": .string(description)
    ])
}

func intProp(_ description: String) -> JSONValue {
    .object(["type": .string("integer"), "description": .string(description)])
}

func boolProp(_ description: String) -> JSONValue {
    .object(["type": .string("boolean"), "description": .string(description)])
}

func stringArrayProp(_ description: String) -> JSONValue {
    .object([
        "type": .string("array"),
        "items": .object(["type": .string("string")]),
        "description": .string(description)
    ])
}

/// A field that accepts either one string or an array of them. Used for
/// recipient lists, where a single address is the common case but multiple
/// addresses must be unambiguous.
func stringOrStringArrayProp(_ description: String) -> JSONValue {
    .object([
        "type": .array([.string("string"), .string("array")]),
        "items": .object(["type": .string("string")]),
        "description": .string(description)
    ])
}

/// A number that need not be whole -- hours, coordinates, durations. `intProp`
/// is the right choice for a count; this is for a quantity.
func numberProp(_ description: String) -> JSONValue {
    .object(["type": .string("number"), "description": .string(description)])
}

func enumProp(_ description: String, values: [String]) -> JSONValue {
    .object([
        "type": .string("string"),
        "description": .string(description),
        "enum": .array(values.map { .string($0) })
    ])
}
