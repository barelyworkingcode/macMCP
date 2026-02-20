import Foundation

enum ShortcutsService {
    private static func runProcess(_ path: String, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (-1, error.localizedDescription)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    // MARK: - Tool Handlers

    private static func listShortcuts(_ args: JSONObject?) -> MCPCallResult {
        let (status, output) = runProcess("/usr/bin/shortcuts", ["list"])
        if status != 0 {
            return errorResult("shortcuts list failed (exit \(status)): \(output)")
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return textResult("No shortcuts found.")
        }
        return textResult(trimmed)
    }

    private static func runShortcut(_ args: JSONObject?) -> MCPCallResult {
        guard let name = args?["name"]?.stringValue, !name.isEmpty else {
            return errorResult("missing required parameter: name")
        }

        var arguments = ["run", name]

        var tempFile: URL? = nil
        if let input = args?["input"]?.stringValue {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
            do {
                try input.write(to: tmp, atomically: true, encoding: .utf8)
            } catch {
                return errorResult("failed to write temp input file: \(error.localizedDescription)")
            }
            tempFile = tmp
            arguments += ["--input-path", tmp.path]
        }

        defer {
            if let f = tempFile {
                try? FileManager.default.removeItem(at: f)
            }
        }

        let (status, output) = runProcess("/usr/bin/shortcuts", arguments)
        if status != 0 {
            return errorResult("shortcut '\(name)' failed (exit \(status)): \(output)")
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return textResult("Shortcut '\(name)' completed with no output.")
        }
        return textResult(trimmed)
    }

    // MARK: - Registration

    static func register(_ registry: ToolRegistry) {
        let cat = "Shortcuts"

        registry.register(
            MCPTool(
                name: "shortcuts_list",
                description: "List all available macOS shortcuts",
                inputSchema: emptySchema(),
                annotations: MCPAnnotations(readOnlyHint: true)
            ),
            category: cat,
            handler: listShortcuts
        )

        registry.register(
            MCPTool(
                name: "shortcuts_run",
                description: "Run a macOS shortcut by name",
                inputSchema: schema(
                    properties: [
                        "name": stringProp("Name of the shortcut to run"),
                        "input": stringProp("Input text to pass to the shortcut")
                    ],
                    required: ["name"]
                )
            ),
            category: cat,
            handler: runShortcut
        )
    }
}
