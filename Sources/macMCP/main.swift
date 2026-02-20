import Foundation

let registry = ToolRegistry()

// Register all services
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
                    "version": .string("1.0.0")
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
        let result = registry.call(name: name, arguments: arguments)

        let contentValues: [JSONValue] = result.content.map { c in
            .object(["type": .string(c.type), "text": .string(c.text)])
        }
        var resultObj: [String: JSONValue] = ["content": .array(contentValues)]
        if result.isError == true {
            resultObj["isError"] = .bool(true)
        }
        respond(JSONRPCResponse(id: req.id, result: .object(resultObj)))

    default:
        respond(JSONRPCResponse(
            id: req.id,
            error: JSONRPCError(code: -32601, message: "method not found: \(req.method)")
        ))
    }
}
