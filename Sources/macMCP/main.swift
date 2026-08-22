import AppKit
import Foundation

// NSApplication is required for macOS to honour TCC grants (Location Services, etc.)
// .accessory = no Dock icon, but can receive events and display system dialogs (TCC
// prompts). .prohibited would suppress TCC prompts entirely when spawned as a subprocess.
NSApplication.shared.setActivationPolicy(.accessory)

// --check-permissions: read and print the current TCC authorization status
// for every service macMCP touches, then exit.
//
// This is the status-reporting half of Relay's Reset Permissions flow. The
// actual prompt-and-grant happens in Relay (which carries the required
// com.apple.security.personal-information.* entitlements); macmcp inherits
// those grants via TCC's responsible-parent attribution at runtime, so it
// has no reason to call any request* API itself.
if CommandLine.arguments.contains("--check-permissions") {
    print(PermissionsService.checkAll())
    exit(0)
}

let registry = ToolRegistry()

// Register all services
PermissionsService.register(registry)
CalendarService.register(registry)
ContactsService.register(registry)
RemindersService.register(registry)
LocationService.register(registry)
MapsService.register(registry)
CaptureService.register(registry)
MailService.register(registry)
MessagesService.register(registry)
ShortcutsService.register(registry)
UtilitiesService.register(registry)
WeatherService.register(registry)
WebService.register(registry)

// JSON-RPC 2.0 stdio server
let decoder = JSONDecoder()
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]

func respond(_ response: JSONRPCResponse) {
    guard var data = try? encoder.encode(response) else { return }
    data.append(0x0A) // newline
    FileHandle.standardOutput.write(data)
}

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty else { continue }
    guard let data = line.data(using: .utf8) else { continue }

    guard let req = try? decoder.decode(JSONRPCRequest.self, from: data) else {
        respond(JSONRPCResponse(id: nil, error: JSONRPCError(code: -32700, message: "parse error")))
        continue
    }

    switch req.method {
    case "initialize":
        respond(JSONRPCResponse(
            id: req.id,
            result: .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object([
                    "name": .string("macmcp"),
                    "version": .string("1.1.0"),
                    "contextSchemaVersion": .int(2),
                    "contextSchema": .object(mailContextSchema)
                ])
            ])
        ))

    case "notifications/initialized":
        // Notification, no response
        break

    case "tools/list":
        let tools = registry.allTools()
        let toolValues: [JSONValue] = tools.map { tool in
            var obj: [String: JSONValue] = [
                "name": .string(tool.name),
                "description": .string(tool.description),
                "inputSchema": tool.inputSchema
            ]
            if let ann = tool.annotations, let ro = ann.readOnlyHint {
                obj["annotations"] = .object(["readOnlyHint": .bool(ro)])
            }
            if let cat = tool.category {
                obj["category"] = .string(cat)
            }
            return .object(obj)
        }
        respond(JSONRPCResponse(id: req.id, result: .object(["tools": .array(toolValues)])))

    case "tools/call":
        let name = req.params?["name"]?.stringValue ?? ""
        var arguments: JSONObject? = nil
        if let args = req.params?["arguments"]?.objectValue {
            arguments = args
        }
        // MCP convention: `_meta` rides as a sibling of `name`/`arguments`
        // inside `params`. Relay injects `_meta.project_id` and, once a
        // caller's access profile declares one, resource-scope fields
        // (mail_accounts, mail_mailboxes, write_dirs -- see contextSchema
        // below and MailScope). Absent stays absent rather than becoming an
        // empty object, because MailScope's whole contract depends on being
        // able to tell "no _meta at all" apart from "_meta present but a
        // scope field empty" (ADR-011 decision 4).
        let meta = req.params?["_meta"]?.objectValue
        let result = registry.call(name: name, arguments: arguments, meta: meta)

        let contentValues: [JSONValue] = result.content.map { c in
            .object(["type": .string(c.type), "text": .string(c.text)])
        }
        var resultObj: [String: JSONValue] = ["content": .array(contentValues)]
        if result.isError == true {
            resultObj["isError"] = .bool(true)
        }
        // `_meta` on the result, a sibling of `content` and `isError`, which is
        // where MCP puts it. Today the only key is `scope_violation: true`
        // (ADR-011 decision 7) -- omitted entirely when nothing set one, so a
        // client or a relay that does not read it sees exactly the response it
        // saw before this existed.
        if let meta = result.meta, !meta.isEmpty {
            resultObj["_meta"] = .object(meta)
        }
        respond(JSONRPCResponse(id: req.id, result: .object(resultObj)))

    // ADR-011 decision 6: a separate JSON-RPC method, not a tool. It backs a
    // picker in relay's operator-facing Settings UI, never a tool call, so it
    // must stay off `tools/list` (nothing above registers it with `registry`)
    // and is dispatched here directly. Unlike `tools/call` it reads no
    // `_meta` and applies no scope: an operator configuring a profile is
    // allowed to see everything on the host, which is the disclosure ADR-011
    // names as deliberate. An MCP that does not implement this method still
    // falls through to the `default` case below and returns the ordinary
    // -32601, which is how relay detects the absence and degrades to a
    // free-text box (decision 6's "raw JSON editor is the fallback").
    case "context/enumerate":
        guard let field = req.params?["field"]?.stringValue else {
            respond(JSONRPCResponse(
                id: req.id,
                error: JSONRPCError(code: -32602, message: "context/enumerate requires a \"field\" string parameter")
            ))
            break
        }
        guard let fragment = mailContextSchema[field]?.objectValue else {
            respond(JSONRPCResponse(
                id: req.id,
                error: JSONRPCError(code: -32602, message: "unknown contextSchema field: \(field)")
            ))
            break
        }
        guard fragment["enumerable"]?.boolValue == true else {
            respond(JSONRPCResponse(
                id: req.id,
                error: JSONRPCError(code: -32602, message: "contextSchema field \(field) is not enumerable")
            ))
            break
        }
        let values = req.params?["values"]?.objectValue
        let (entries, error) = MailService.enumerateContext(field: field, values: values)
        if let error {
            respond(JSONRPCResponse(id: req.id, error: JSONRPCError(code: -32000, message: error)))
            break
        }
        let valueValues: [JSONValue] = entries.map {
            .object(["value": .string($0.value), "label": .string($0.label)])
        }
        respond(JSONRPCResponse(
            id: req.id,
            result: .object(["field": .string(field), "values": .array(valueValues)])
        ))

    default:
        respond(JSONRPCResponse(
            id: req.id,
            error: JSONRPCError(code: -32601, message: "method not found: \(req.method)")
        ))
    }
}
