import Contacts
import CoreLocation
import EventKit
import Foundation

enum PermissionsService {
    static func register(_ registry: ToolRegistry) {
        registry.register(
            MCPTool(
                name: "permissions_check",
                description: "Check and request macOS permissions for all TCC-protected services (Location, Calendars, Contacts, Reminders). Call after initialization to trigger system permission prompts if needed.",
                inputSchema: emptySchema(),
                annotations: MCPAnnotations(readOnlyHint: true)
            ),
            category: "System"
        ) { _ in
            let results = requestPermissions()
            let denied = results.filter { $0.status != "authorized" }
            if denied.isEmpty {
                return jsonResult(["permissions": results.map(\.dict), "ok": true])
            }
            return jsonResult([
                "permissions": results.map(\.dict),
                "ok": false,
                "message": "Some permissions are not granted. Open System Settings > Privacy & Security to grant access to macmcp.",
            ])
        }
    }

    /// Request all TCC permissions and return a human-readable summary.
    /// Called from --request-permissions CLI mode and from the permissions_check tool.
    static func requestAll() -> String {
        let results = requestPermissions()
        var lines: [String] = ["macMCP permissions:"]
        for r in results {
            let icon = r.status == "authorized" ? "+" : "-"
            lines.append("  [\(icon)] \(r.service): \(r.status)")
        }
        let denied = results.filter { $0.status != "authorized" }
        if !denied.isEmpty {
            lines.append("")
            lines.append("Grant access in System Settings > Privacy & Security for each denied service.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Implementation

    private struct PermResult {
        let service: String
        let status: String
        var dict: [String: Any] { ["service": service, "status": status] }
    }

    private static func requestPermissions() -> [PermResult] {
        var pendingManagers: [CLLocationManager] = [] // prevent ARC release

        // -- Location --
        let locManager = CLLocationManager()
        let locBefore = locManager.authorizationStatus
        if locBefore == .notDetermined {
            locManager.requestWhenInUseAuthorization()
            pendingManagers.append(locManager)
        }

        // -- Calendars --
        let calStore = EKEventStore()
        let calBefore = EKEventStore.authorizationStatus(for: .event)
        if calBefore == .notDetermined {
            if #available(macOS 14.0, *) {
                calStore.requestFullAccessToEvents { _, _ in }
            } else {
                calStore.requestAccess(to: .event) { _, _ in }
            }
        }

        // -- Contacts --
        let contactStore = CNContactStore()
        let contactsBefore = CNContactStore.authorizationStatus(for: .contacts)
        if contactsBefore == .notDetermined {
            contactStore.requestAccess(for: .contacts) { _, _ in }
        }

        // -- Reminders --
        let remStore = EKEventStore()
        let remBefore = EKEventStore.authorizationStatus(for: .reminder)
        if remBefore == .notDetermined {
            if #available(macOS 14.0, *) {
                remStore.requestFullAccessToReminders { _, _ in }
            } else {
                remStore.requestAccess(to: .reminder) { _, _ in }
            }
        }

        // Pump the RunLoop to allow TCC prompts to appear and be responded to.
        // 30s is enough for a user to respond to all prompts sequentially.
        let deadline = Date(timeIntervalSinceNow: 30)
        while Date() < deadline {
            let locResolved = locBefore != .notDetermined || locManager.authorizationStatus != .notDetermined
            let calResolved = calBefore != .notDetermined || EKEventStore.authorizationStatus(for: .event) != .notDetermined
            let conResolved = contactsBefore != .notDetermined || CNContactStore.authorizationStatus(for: .contacts) != .notDetermined
            let remResolved = remBefore != .notDetermined || EKEventStore.authorizationStatus(for: .reminder) != .notDetermined

            if locResolved && calResolved && conResolved && remResolved { break }
            CFRunLoopRunInMode(.defaultMode, 0.25, true)
        }

        // Keep managers alive through the RunLoop.
        withExtendedLifetime(pendingManagers) {}
        withExtendedLifetime(calStore) {}
        withExtendedLifetime(contactStore) {}
        withExtendedLifetime(remStore) {}

        // Read final statuses.
        return [
            PermResult(service: "location", status: statusName(loc: locManager.authorizationStatus)),
            PermResult(service: "calendars", status: statusName(ek: EKEventStore.authorizationStatus(for: .event))),
            PermResult(service: "contacts", status: statusName(cn: CNContactStore.authorizationStatus(for: .contacts))),
            PermResult(service: "reminders", status: statusName(ek: EKEventStore.authorizationStatus(for: .reminder))),
        ]
    }

    // MARK: - Helpers

    private static func statusName(loc status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:                    return "not_determined"
        case .restricted:                       return "restricted"
        case .denied:                           return "denied"
        case .authorized, .authorizedAlways:    return "authorized"
        @unknown default:                       return "unknown"
        }
    }

    private static func statusName(ek status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:                    return "not_determined"
        case .restricted:                       return "restricted"
        case .denied:                           return "denied"
        case .fullAccess, .authorized:          return "authorized"
        case .writeOnly:                        return "write_only"
        @unknown default:                       return "unknown"
        }
    }

    private static func statusName(cn status: CNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:    return "not_determined"
        case .restricted:       return "restricted"
        case .denied:           return "denied"
        case .authorized:       return "authorized"
        @unknown default:       return "unknown"
        }
    }
}
