import CoreLocation
import Foundation

#if canImport(AppKit)
import AppKit
#endif

enum MapsService {
    // MARK: - Registration

    static func register(_ registry: ToolRegistry) {
        let cat = "Maps"

        registry.register(
            MCPTool(
                name: "maps_search",
                description: "Search for places or addresses using geocoding. Returns matching results with name, coordinates, and address components.",
                inputSchema: schema(
                    properties: ["query": stringProp("Place name or address to search for")],
                    required: ["query"]
                ),
                annotations: MCPAnnotations(readOnlyHint: true)
            ),
            category: cat,
            handler: search
        )

        registry.register(
            MCPTool(
                name: "maps_open",
                description: "Open a location in Apple Maps",
                inputSchema: schema(
                    properties: ["query": stringProp("Address or place name to open in Apple Maps")],
                    required: ["query"]
                )
            ),
            category: cat,
            handler: openInMaps
        )

        registry.register(
            MCPTool(
                name: "maps_get_directions",
                description: "Construct an Apple Maps directions URL for the given origin and destination",
                inputSchema: schema(
                    properties: [
                        "from": stringProp("Origin address or place name (uses current location if omitted)"),
                        "to": stringProp("Destination address or place name"),
                        "mode": enumProp("Travel mode", values: ["driving", "walking", "transit"]),
                    ],
                    required: ["to"]
                ),
                annotations: MCPAnnotations(readOnlyHint: true)
            ),
            category: cat,
            handler: getDirections
        )
    }

    // MARK: - Handlers

    private static func search(_ args: JSONObject?) -> MCPCallResult {
        guard let query = args?["query"]?.stringValue, !query.isEmpty else {
            return errorResult("query is required")
        }

        let geocoder = CLGeocoder()
        let semaphore = DispatchSemaphore(value: 0)
        var placemarks: [CLPlacemark]?
        var geocodeError: Error?

        geocoder.geocodeAddressString(query) { results, error in
            placemarks = results
            geocodeError = error
            semaphore.signal()
        }

        let timeout = semaphore.wait(timeout: .now() + 15)
        if timeout == .timedOut {
            geocoder.cancelGeocode()
            return errorResult("search timed out")
        }

        if let error = geocodeError {
            return errorResult("search error: \(error.localizedDescription)")
        }

        guard let marks = placemarks, !marks.isEmpty else {
            return errorResult("no results for query")
        }

        let results: [[String: Any]] = marks.compactMap { pm in
            guard let loc = pm.location else { return nil }
            var entry: [String: Any] = [
                "latitude": loc.coordinate.latitude,
                "longitude": loc.coordinate.longitude,
            ]
            if let name = pm.name { entry["name"] = name }
            if let thoroughfare = pm.thoroughfare { entry["street"] = thoroughfare }
            if let subThoroughfare = pm.subThoroughfare { entry["street_number"] = subThoroughfare }
            if let locality = pm.locality { entry["city"] = locality }
            if let admin = pm.administrativeArea { entry["state"] = admin }
            if let country = pm.country { entry["country"] = country }
            if let postal = pm.postalCode { entry["postal_code"] = postal }
            return entry
        }

        return jsonResult(results)
    }

    private static func openInMaps(_ args: JSONObject?) -> MCPCallResult {
        guard let query = args?["query"]?.stringValue, !query.isEmpty else {
            return errorResult("query is required")
        }

        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "maps://?q=\(encoded)") else {
            return errorResult("failed to construct maps URL")
        }

        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        return textResult("opened Apple Maps for: \(query)")
        #else
        return errorResult("Apple Maps is not available on this platform")
        #endif
    }

    private static func getDirections(_ args: JSONObject?) -> MCPCallResult {
        guard let to = args?["to"]?.stringValue, !to.isEmpty else {
            return errorResult("to is required")
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.path = "/"

        var queryItems: [URLQueryItem] = []

        if let from = args?["from"]?.stringValue, !from.isEmpty {
            queryItems.append(URLQueryItem(name: "saddr", value: from))
        }
        queryItems.append(URLQueryItem(name: "daddr", value: to))

        if let mode = args?["mode"]?.stringValue {
            let dirflg: String
            switch mode {
            case "walking": dirflg = "w"
            case "transit": dirflg = "r"
            default: dirflg = "d"
            }
            queryItems.append(URLQueryItem(name: "dirflg", value: dirflg))
        }

        components.queryItems = queryItems

        guard let urlString = components.url?.absoluteString else {
            return errorResult("failed to construct directions URL")
        }

        var result: [String: Any] = ["url": urlString, "destination": to]
        if let from = args?["from"]?.stringValue, !from.isEmpty {
            result["origin"] = from
        }
        if let mode = args?["mode"]?.stringValue {
            result["mode"] = mode
        }

        return jsonResult(result)
    }
}
