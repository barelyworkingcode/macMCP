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

    /// The one place either capture tool decides where its file goes.
    ///
    /// **Both directions of `file_dirs` in one seam**, because both tools open
    /// the same kind of hole in the same way and the only thing that differs
    /// is the extension. See `HostFileScope` for why these tools are governed
    /// at all and why an absent `path` resolves to the scope rather than
    /// refusing.
    private static func destination(
        _ ctx: MCPCallContext, filename: String, what: String
    ) -> (path: String?, refusal: MCPCallResult?) {
        let scope = ResourceScope.parse(ctx.meta)
        // Ordered before anything else for the reason every scoped handler
        // orders it there: it is a question about this call's authority, which
        // does not depend on whether the machine would have answered.
        if let refusal = scope.presenceRefusal(tool: ctx.toolName) {
            return (nil, scopeViolationResult(refusal))
        }
        let outcome: HostFileScope.Outcome
        if let requested = ctx.arguments?["path"]?.stringValue {
            outcome = HostFileScope.resolve(requested, scope: scope, use: .write, what: what)
        } else {
            outcome = HostFileScope.resolveDefault(
                directory: "~/Desktop", filename: filename, scope: scope, what: what)
        }
        switch outcome {
        case .use(let path): return (path, nil)
        case .refuse(let message): return (nil, scopeViolationResult(message))
        case .error(let message): return (nil, errorResult(message))
        }
    }

    private static func captureScreenshot(_ ctx: MCPCallContext) -> MCPCallResult {
        let args = ctx.arguments
        let resolved = destination(
            ctx, filename: "screenshot-\(timestamp()).png", what: "screenshot")
        if let refusal = resolved.refusal { return refusal }
        guard let path = resolved.path else { return errorResult("no destination for the screenshot") }
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

    private static func captureAudio(_ ctx: MCPCallContext) -> MCPCallResult {
        let args = ctx.arguments
        let resolved = destination(
            ctx, filename: "recording-\(timestamp()).m4a", what: "recording")
        if let refusal = resolved.refusal { return refusal }
        guard let path = resolved.path else { return errorResult("no destination for the recording") }
        let duration = args?["duration"]?.intValue ?? 10

        let flags = ["-d", "aac", "-f", "m4af", "-c", "1", "-s", "2", "--duration", "\(duration)", path]

        let (status, output) = runProcess("/usr/bin/afrecord", flags)
        if status != 0 {
            return errorResult("afrecord failed (exit \(status)): \(output)")
        }
        return textResult("audio recorded (\(duration)s) to \(path)")
    }

    // MARK: - Registration

    // **Not open world, and the scary-sounding one is the clearest case.**
    // `capture_screenshot` drives `/usr/sbin/screencapture` and
    // `capture_audio` drives `/usr/bin/afrecord`; both read a local device and
    // write a local file, and neither opens a socket or names anything off
    // this Mac. They are heavily privileged (Screen Recording, Microphone) and
    // that privilege is a different question from this one -- what keeps them
    // away from a mail profile is `allowed_tools`, not this hint. Annotating
    // them open world because they *feel* dangerous would make the hint mean
    // "risky" instead of "reaches outside", and then it would answer neither.

    static func register(_ registry: ToolRegistry) {
        let cat = "Capture"

        registry.register(
            MCPTool(
                name: "capture_screenshot",
                description: "Take a screenshot of the screen, a window, or a selection",
                inputSchema: schema(
                    properties: [
                        "path": stringProp("Absolute POSIX path to save the screenshot to (defaults to ~/Desktop/screenshot-{timestamp}.png). Confined to the file_dirs of the calling client's resource scope. A client whose scope carries no file_dirs cannot take a screenshot at all — every call writes a file — and one whose scope names directories writes only inside them: the default location is used when it is one of them, the single allowed directory is used when there is only one, and otherwise you are asked to pass a path naming one of them"),
                        "type": enumProp("Capture type", values: ["fullscreen", "window", "selection"])
                    ]
                ),
                annotations: MCPAnnotations(readOnlyHint: false, openWorldHint: false)
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
                        "path": stringProp("Absolute POSIX path to save the recording to (defaults to ~/Desktop/recording-{timestamp}.m4a). Confined to the file_dirs of the calling client's resource scope, exactly as capture_screenshot's path is: no file_dirs means no recording, and otherwise the file is written inside one of the named directories"),
                        "duration": intProp("Recording duration in seconds (defaults to 10)")
                    ]
                ),
                annotations: MCPAnnotations(readOnlyHint: false, openWorldHint: false)
            ),
            category: cat,
            handler: captureAudio
        )
    }
}
