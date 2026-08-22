import CoreLocation
import Foundation

// CLLocationManager delegate that captures a single location update.
// Uses CFRunLoop instead of semaphore because CLLocationManager requires
// an active RunLoop on its thread to deliver delegate callbacks.
private class LocationDelegate: NSObject, CLLocationManagerDelegate {
    var location: CLLocation?
    var error: Error?
    var done = false
    private var runLoop: CFRunLoop?

    func setRunLoop(_ rl: CFRunLoop) { runLoop = rl }

    private func finish() {
        done = true
        if let rl = runLoop { CFRunLoopStop(rl) }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        location = locations.last
        manager.stopUpdatingLocation()
        finish()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        self.error = error
        finish()
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
            finish()
        }
    }
}

enum LocationService {
    /// **All three tools are open world, including the one that only reads a
    /// sensor.** The two geocoders are obvious: `CLGeocoder` is a network
    /// service Apple runs, and the caller's address string is what is sent to
    /// it.
    ///
    /// `location_get_current` is the one worth stating, because "read the
    /// current location" sounds local and is not. A Mac has no GPS; when this
    /// call runs, `locationd` resolves a position by sending the surrounding
    /// Wi-Fi environment to Apple's positioning service and waiting for an
    /// answer. That is an outbound request *caused by this call* -- not a
    /// background sync that would have happened anyway -- and it discloses
    /// where the host physically is. It is exactly why this VM answers
    /// `kCLErrorDomain error 0`: no Wi-Fi positioning source to ask with.
    static func register(_ registry: ToolRegistry) {
        let cat = "Location"

        // location_get_current
        registry.register(
            MCPTool(
                name: "location_get_current",
                description: "Get current location coordinates (latitude, longitude, accuracy, timestamp)",
                inputSchema: emptySchema(),
                annotations: MCPAnnotations(readOnlyHint: true, openWorldHint: true)
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
                annotations: MCPAnnotations(readOnlyHint: true, openWorldHint: true)
            ),
            category: cat
        ) { ctx in
            let args = ctx.arguments
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
                annotations: MCPAnnotations(readOnlyHint: true, openWorldHint: true)
            ),
            category: cat
        ) { ctx in
            let args = ctx.arguments
            guard let lat = extractDouble(args, key: "latitude"),
                  let lon = extractDouble(args, key: "longitude") else {
                return errorResult("latitude and longitude are required")
            }
            return reverseGeocode(latitude: lat, longitude: lon)
        }
    }

    // MARK: - Handlers

    private static func getCurrentLocation() -> MCPCallResult {
        guard CLLocationManager.locationServicesEnabled() else {
            return errorResult("location services are disabled system-wide. Enable in System Settings > Privacy & Security > Location Services")
        }

        // CLLocationManager requires an active RunLoop on the creating thread.
        // Run the main thread's RunLoop in small steps to process callbacks.
        let delegate = LocationDelegate()
        delegate.setRunLoop(CFRunLoopGetMain())

        let manager = CLLocationManager()
        manager.delegate = delegate
        manager.desiredAccuracy = kCLLocationAccuracyBest

        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
            // Wait up to 5 seconds for the system authorization prompt.
            // When spawned as a stdio subprocess (e.g. via an MCP host), macOS
            // often cannot show the TCC dialog, so fail fast with guidance.
            let authDeadline = Date(timeIntervalSinceNow: 5)
            while manager.authorizationStatus == .notDetermined && Date() < authDeadline {
                CFRunLoopRunInMode(.defaultMode, 0.25, true)
            }
            let updated = manager.authorizationStatus
            if updated == .authorized || updated == .authorizedAlways {
                manager.startUpdatingLocation()
            } else if updated == .notDetermined {
                withExtendedLifetime(manager) {}
                return errorResult("location permission not determined — the system prompt may not have appeared. Grant access manually: System Settings > Privacy & Security > Location Services > macmcp")
            } else {
                withExtendedLifetime(manager) {}
                return errorResult("location access denied. Grant access in System Settings > Privacy & Security > Location Services > macmcp")
            }
        } else if status == .authorized || status == .authorizedAlways {
            manager.startUpdatingLocation()
        } else {
            return errorResult("location access denied. Grant access in System Settings > Privacy & Security > Location Services > macmcp")
        }

        // Pump the RunLoop to deliver delegate callbacks.
        let deadline = Date(timeIntervalSinceNow: 15)
        while !delegate.done && Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.25, true)
        }

        // Keep manager alive through the RunLoop so ARC doesn't release it early.
        withExtendedLifetime(manager) {}

        if let error = delegate.error {
            return errorResult("location error: \(error.localizedDescription)")
        }

        guard let loc = delegate.location else {
            return errorResult("timed out waiting for location")
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
        var placemarks: [CLPlacemark]?
        var geocodeError: Error?
        var done = false

        geocoder.geocodeAddressString(address) { results, error in
            placemarks = results
            geocodeError = error
            done = true
        }

        let deadline = Date(timeIntervalSinceNow: 15)
        while !done && Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.25, true)
        }

        if !done {
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
        var placemarks: [CLPlacemark]?
        var geocodeError: Error?
        var done = false

        geocoder.reverseGeocodeLocation(location) { results, error in
            placemarks = results
            geocodeError = error
            done = true
        }

        let deadline = Date(timeIntervalSinceNow: 15)
        while !done && Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.25, true)
        }

        if !done {
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
