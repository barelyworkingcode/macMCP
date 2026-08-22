import Foundation

enum WebService {
    // Cap the body we return so a large download can't blow up the JSON-RPC response.
    private static let maxBytes = 1_000_000
    private static let defaultTimeout = 30.0
    private static let maxTimeout = 120.0

    static func register(_ registry: ToolRegistry) {
        let cat = "Web"

        registry.register(
            MCPTool(
                name: "web_fetch",
                description: "Fetch the contents of an http/https URL and return the response body as text",
                inputSchema: schema(
                    properties: [
                        "url": stringProp("The http or https URL to fetch"),
                        "timeout": intProp("Request timeout in seconds (default 30, max 120)"),
                    ],
                    required: ["url"]
                ),
                annotations: MCPAnnotations(readOnlyHint: true)
            ),
            category: cat,
            handler: fetch
        )
    }

    // MARK: - Handlers

    private static func fetch(_ ctx: MCPCallContext) -> MCPCallResult {
        let args = ctx.arguments
        guard let urlString = args?["url"]?.stringValue, !urlString.isEmpty else {
            return errorResult("url is required")
        }

        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return errorResult("url must be a valid http or https URL")
        }

        var timeout = Double(args?["timeout"]?.intValue ?? Int(defaultTimeout))
        timeout = min(max(timeout, 1), maxTimeout)

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("macmcp/1.0", forHTTPHeaderField: "User-Agent")

        var resultData: Data?
        var resultResponse: URLResponse?
        var resultError: Error?
        var done = false

        URLSession.shared.dataTask(with: request) { data, response, error in
            resultData = data
            resultResponse = response
            resultError = error
            done = true
        }.resume()

        let deadline = Date(timeIntervalSinceNow: timeout)
        while !done && Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.25, true)
        }

        if !done {
            return errorResult("request timed out after \(Int(timeout))s")
        }

        if let error = resultError {
            return errorResult("request failed: \(error.localizedDescription)")
        }

        guard let data = resultData else {
            return errorResult("no data received")
        }

        var header = ""
        if let http = resultResponse as? HTTPURLResponse {
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
            header = "HTTP \(http.statusCode) — \(contentType) — \(data.count) bytes\n\n"
        }

        let truncated = data.count > maxBytes
        let bodyData = truncated ? data.prefix(maxBytes) : data
        guard let body = String(data: bodyData, encoding: .utf8)
            ?? String(data: bodyData, encoding: .isoLatin1) else {
            return errorResult("response body is not decodable as text (\(data.count) bytes)")
        }

        let suffix = truncated ? "\n\n…[truncated to \(maxBytes) bytes]" : ""
        return textResult(header + body + suffix)
    }
}
