import Foundation

enum UtilitiesService {
    private static func playSound(_ args: JSONObject?) -> MCPCallResult {
        guard let path = args?["path"]?.stringValue else {
            return errorResult("path is required")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return errorResult("failed to run afplay: \(error.localizedDescription)")
        }

        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return errorResult("afplay failed (exit \(process.terminationStatus)): \(output)")
        }

        return textResult("played \(path)")
    }

    // MARK: - Registration

    static func register(_ registry: ToolRegistry) {
        registry.register(
            MCPTool(
                name: "utilities_play_sound",
                description: "Play an audio file",
                inputSchema: schema(
                    properties: [
                        "path": stringProp("Path to the audio file to play")
                    ],
                    required: ["path"]
                )
            ),
            category: "Utilities",
            handler: playSound
        )
    }
}
