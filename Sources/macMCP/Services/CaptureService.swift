import Foundation

enum CaptureService {
    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

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

    private static func captureScreenshot(_ args: JSONObject?) -> MCPCallResult {
        let defaultPath = NSString(string: "~/Desktop/screenshot-\(timestamp()).png").expandingTildeInPath
        let path = args?["path"]?.stringValue ?? defaultPath
        let type = args?["type"]?.stringValue ?? "fullscreen"

        var flags = ["-x"]
        switch type {
        case "window":
            flags.append("-w")
        case "selection":
            flags.append("-s")
        case "fullscreen":
            break
        default:
            return errorResult("invalid type: \(type) (expected fullscreen, window, or selection)")
        }
        flags.append(path)

        let (status, output) = runProcess("/usr/sbin/screencapture", flags)
        if status != 0 {
            return errorResult("screencapture failed (exit \(status)): \(output)")
        }
        return textResult("screenshot saved to \(path)")
    }

    private static func captureAudio(_ args: JSONObject?) -> MCPCallResult {
        let defaultPath = NSString(string: "~/Desktop/recording-\(timestamp()).m4a").expandingTildeInPath
        let path = args?["path"]?.stringValue ?? defaultPath
        let duration = args?["duration"]?.intValue ?? 10

        let flags = ["-d", "aac", "-f", "m4af", "-c", "1", "-s", "2", "--duration", "\(duration)", path]

        let (status, output) = runProcess("/usr/bin/afrecord", flags)
        if status != 0 {
            return errorResult("afrecord failed (exit \(status)): \(output)")
        }
        return textResult("audio recorded (\(duration)s) to \(path)")
    }

    // MARK: - Registration

    static func register(_ registry: ToolRegistry) {
        let cat = "Capture"

        registry.register(
            MCPTool(
                name: "capture_screenshot",
                description: "Take a screenshot of the screen, a window, or a selection",
                inputSchema: schema(
                    properties: [
                        "path": stringProp("File path to save the screenshot (defaults to ~/Desktop/screenshot-{timestamp}.png)"),
                        "type": enumProp("Capture type", values: ["fullscreen", "window", "selection"])
                    ]
                )
            ),
            category: cat,
            handler: captureScreenshot
        )

        registry.register(
            MCPTool(
                name: "capture_audio",
                description: "Record audio from the default input device",
                inputSchema: schema(
                    properties: [
                        "path": stringProp("File path to save the recording (defaults to ~/Desktop/recording-{timestamp}.m4a)"),
                        "duration": intProp("Recording duration in seconds (defaults to 10)")
                    ]
                )
            ),
            category: cat,
            handler: captureAudio
        )
    }
}
