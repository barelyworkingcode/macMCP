import Foundation

enum UtilitiesService {
    private static func playSound(_ ctx: MCPCallContext) -> MCPCallResult {
        let args = ctx.arguments
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

    // Not open world: `afplay` plays a local file. Measured rather than
    // assumed, because the parameter is called `path` and CoreAudio's
    // `AudioFileOpenURL` takes a URL -- `afplay http://127.0.0.1:<port>/x.mp3`
    // against a listener made no connection at all and failed with the same
    // `AudioFileOpen failed ('wht?')` as a nonexistent local path. There is no
    // way to spell a network fetch through this tool.

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
                ),
                annotations: MCPAnnotations(readOnlyHint: false, openWorldHint: false)
            ),
            category: "Utilities",
            handler: playSound
        )
    }
}
