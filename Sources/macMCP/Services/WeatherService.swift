import Foundation

enum WeatherService {
    static func register(_ registry: ToolRegistry) {
        let cat = "Weather"

        registry.register(
            MCPTool(
                name: "weather_current",
                description: "Get current weather conditions for a location",
                inputSchema: schema(
                    properties: [
                        "latitude": .object(["type": .string("number"), "description": .string("Latitude")]),
                        "longitude": .object(["type": .string("number"), "description": .string("Longitude")]),
                    ],
                    required: ["latitude", "longitude"]
                ),
                annotations: MCPAnnotations(readOnlyHint: true)
            ),
            category: cat,
            handler: currentWeather
        )

        registry.register(
            MCPTool(
                name: "weather_forecast",
                description: "Get daily weather forecast for a location",
                inputSchema: schema(
                    properties: [
                        "latitude": .object(["type": .string("number"), "description": .string("Latitude")]),
                        "longitude": .object(["type": .string("number"), "description": .string("Longitude")]),
                        "days": intProp("Number of forecast days (default 7, max 16)"),
                    ],
                    required: ["latitude", "longitude"]
                ),
                annotations: MCPAnnotations(readOnlyHint: true)
            ),
            category: cat,
            handler: forecast
        )

        registry.register(
            MCPTool(
                name: "weather_hourly",
                description: "Get hourly weather forecast for a location",
                inputSchema: schema(
                    properties: [
                        "latitude": .object(["type": .string("number"), "description": .string("Latitude")]),
                        "longitude": .object(["type": .string("number"), "description": .string("Longitude")]),
                        "hours": intProp("Number of forecast hours (default 24)"),
                    ],
                    required: ["latitude", "longitude"]
                ),
                annotations: MCPAnnotations(readOnlyHint: true)
            ),
            category: cat,
            handler: hourly
        )
    }

    // MARK: - Handlers

    private static func currentWeather(_ args: JSONObject?) -> MCPCallResult {
        guard let lat = extractDouble(args, key: "latitude"),
              let lon = extractDouble(args, key: "longitude") else {
            return errorResult("latitude and longitude are required")
        }

        let urlString = "https://api.open-meteo.com/v1/forecast"
            + "?latitude=\(lat)&longitude=\(lon)"
            + "&current=temperature_2m,relative_humidity_2m,apparent_temperature,wind_speed_10m,wind_direction_10m,weather_code"

        return fetch(urlString)
    }

    private static func forecast(_ args: JSONObject?) -> MCPCallResult {
        guard let lat = extractDouble(args, key: "latitude"),
              let lon = extractDouble(args, key: "longitude") else {
            return errorResult("latitude and longitude are required")
        }

        var days = args?["days"]?.intValue ?? 7
        days = min(max(days, 1), 16)

        let urlString = "https://api.open-meteo.com/v1/forecast"
            + "?latitude=\(lat)&longitude=\(lon)"
            + "&daily=temperature_2m_max,temperature_2m_min,precipitation_sum,weather_code"
            + "&forecast_days=\(days)"

        return fetch(urlString)
    }

    private static func hourly(_ args: JSONObject?) -> MCPCallResult {
        guard let lat = extractDouble(args, key: "latitude"),
              let lon = extractDouble(args, key: "longitude") else {
            return errorResult("latitude and longitude are required")
        }

        let hours = args?["hours"]?.intValue ?? 24

        let urlString = "https://api.open-meteo.com/v1/forecast"
            + "?latitude=\(lat)&longitude=\(lon)"
            + "&hourly=temperature_2m,precipitation_probability,weather_code"
            + "&forecast_hours=\(hours)"

        return fetch(urlString)
    }

    // MARK: - Helpers

    private static func fetch(_ urlString: String) -> MCPCallResult {
        guard let url = URL(string: urlString) else {
            return errorResult("invalid URL")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultError: Error?

        URLSession.shared.dataTask(with: url) { data, _, error in
            resultData = data
            resultError = error
            semaphore.signal()
        }.resume()

        let timeout = semaphore.wait(timeout: .now() + 15)
        if timeout == .timedOut {
            return errorResult("request timed out")
        }

        if let error = resultError {
            return errorResult("request failed: \(error.localizedDescription)")
        }

        guard let data = resultData, let body = String(data: data, encoding: .utf8) else {
            return errorResult("no data received")
        }

        return textResult(body)
    }

    private static func extractDouble(_ args: JSONObject?, key: String) -> Double? {
        guard let val = args?[key] else { return nil }
        switch val {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .string(let s): return Double(s)
        default: return nil
        }
    }
}
