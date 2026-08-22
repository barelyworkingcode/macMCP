import Foundation

typealias ToolHandler = (JSONObject?) -> MCPCallResult

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

    func call(name: String, arguments: JSONObject?) -> MCPCallResult {
        guard let reg = registrations[name] else {
            return errorResult("unknown tool: \(name)")
        }
        return reg.handler(arguments)
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
