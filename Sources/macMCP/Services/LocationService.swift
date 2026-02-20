import CoreLocation
import Foundation

private func numberProp(_ description: String) -> JSONValue {
    .object(["type": .string("number"), "description": .string(description)])
}

// CLLocationManager delegate that captures a single location update.
private class LocationDelegate: NSObject, CLLocationManagerDelegate {
    let semaphore = DispatchSemaphore(value: 0)
    var location: CLLocation?
    var error: Error?

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        location = locations.last
        manager.stopUpdatingLocation()
        semaphore.signal()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        self.error = error
        semaphore.signal()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if status == .authorized || status == .authorizedAlways {
            manager.startUpdatingLocation()
        } else if status == .denied || status == .restricted {
            error = NSError(
                domain: "LocationService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "location access denied"]
            )
            semaphore.signal()
        }
    }
}

enum LocationService {
    static func register(_ registry: ToolRegistry) {
        let cat = "Location"

        // location_get_current
        registry.register(
            MCPTool(
                name: "location_get_current",
                description: "Get current location coordinates (latitude, longitude, accuracy, timestamp)",
                inputSchema: emptySchema(),
                annotations: MCPAnnotations(readOnlyHint: true)
            ),
            category: cat
        ) { _ in
            getCurrentLocation()
        }

        // location_geocode
        registry.register(
            MCPTool(
                name: "location_geocode",
                description: "Forward geocode an address string to geographic coordinates",
                inputSchema: schema(
                    properties: ["address": stringProp("Address to geocode")],
                    required: ["address"]
                ),
                annotations: MCPAnnotations(readOnlyHint: true)
            ),
            category: cat
        ) { args in
            guard let address = args?["address"]?.stringValue, !address.isEmpty else {
                return errorResult("address is required")
            }
            return geocode(address: address)
        }

        // location_reverse_geocode
        registry.register(
            MCPTool(
                name: "location_reverse_geocode",
                description: "Reverse geocode coordinates to a human-readable address",
                inputSchema: schema(
                    properties: [
                        "latitude": numberProp("Latitude"),
                        "longitude": numberProp("Longitude"),
                    ],
                    required: ["latitude", "longitude"]
                ),
                annotations: MCPAnnotations(readOnlyHint: true)
            ),
            category: cat
        ) { args in
            guard let lat = extractDouble(args, key: "latitude"),
                  let lon = extractDouble(args, key: "longitude") else {
                return errorResult("latitude and longitude are required")
            }
            return reverseGeocode(latitude: lat, longitude: lon)
        }
    }

    // MARK: - Handlers

    private static func getCurrentLocation() -> MCPCallResult {
        let manager = CLLocationManager()
        let delegate = LocationDelegate()
        manager.delegate = delegate
        manager.desiredAccuracy = kCLLocationAccuracyBest

        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
            // Authorization callback will start updating location.
        } else if status == .authorized || status == .authorizedAlways {
            manager.startUpdatingLocation()
        } else {
            return errorResult("location access denied")
        }

        let timeout = delegate.semaphore.wait(timeout: .now() + 15)
        if timeout == .timedOut {
            manager.stopUpdatingLocation()
            return errorResult("timed out waiting for location")
        }

        if let error = delegate.error {
            return errorResult("location error: \(error.localizedDescription)")
        }

        guard let loc = delegate.location else {
            return errorResult("no location available")
        }

        let result: [String: Any] = [
            "latitude": loc.coordinate.latitude,
            "longitude": loc.coordinate.longitude,
            "accuracy_meters": loc.horizontalAccuracy,
            "timestamp": ISO8601DateFormatter().string(from: loc.timestamp),
        ]
        return jsonResult(result)
    }

    private static func geocode(address: String) -> MCPCallResult {
        let geocoder = CLGeocoder()
        let semaphore = DispatchSemaphore(value: 0)
        var placemarks: [CLPlacemark]?
        var geocodeError: Error?

        geocoder.geocodeAddressString(address) { results, error in
            placemarks = results
            geocodeError = error
            semaphore.signal()
        }

        let timeout = semaphore.wait(timeout: .now() + 15)
        if timeout == .timedOut {
            geocoder.cancelGeocode()
            return errorResult("geocode timed out")
        }

        if let error = geocodeError {
            return errorResult("geocode error: \(error.localizedDescription)")
        }

        guard let marks = placemarks, !marks.isEmpty else {
            return errorResult("no results for address")
        }

        let results: [[String: Any]] = marks.compactMap { pm in
            guard let loc = pm.location else { return nil }
            var entry: [String: Any] = [
                "latitude": loc.coordinate.latitude,
                "longitude": loc.coordinate.longitude,
            ]
            if let name = pm.name { entry["name"] = name }
            if let locality = pm.locality { entry["locality"] = locality }
            if let admin = pm.administrativeArea { entry["administrative_area"] = admin }
            if let country = pm.country { entry["country"] = country }
            if let postal = pm.postalCode { entry["postal_code"] = postal }
            return entry
        }

        return jsonResult(results)
    }

    private static func reverseGeocode(latitude: Double, longitude: Double) -> MCPCallResult {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let semaphore = DispatchSemaphore(value: 0)
        var placemarks: [CLPlacemark]?
        var geocodeError: Error?

        geocoder.reverseGeocodeLocation(location) { results, error in
            placemarks = results
            geocodeError = error
            semaphore.signal()
        }

        let timeout = semaphore.wait(timeout: .now() + 15)
        if timeout == .timedOut {
            geocoder.cancelGeocode()
            return errorResult("reverse geocode timed out")
        }

        if let error = geocodeError {
            return errorResult("reverse geocode error: \(error.localizedDescription)")
        }

        guard let marks = placemarks, let pm = marks.first else {
            return errorResult("no results for coordinates")
        }

        var result: [String: Any] = [
            "latitude": latitude,
            "longitude": longitude,
        ]
        if let name = pm.name { result["name"] = name }
        if let thoroughfare = pm.thoroughfare { result["street"] = thoroughfare }
        if let subThoroughfare = pm.subThoroughfare { result["street_number"] = subThoroughfare }
        if let locality = pm.locality { result["city"] = locality }
        if let subLocality = pm.subLocality { result["neighborhood"] = subLocality }
        if let admin = pm.administrativeArea { result["state"] = admin }
        if let country = pm.country { result["country"] = country }
        if let postal = pm.postalCode { result["postal_code"] = postal }

        return jsonResult(result)
    }

    // MARK: - Helpers

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
