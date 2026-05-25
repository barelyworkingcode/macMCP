import Contacts
import CoreLocation
import EventKit
import Foundation

/// PermissionsService reports the current TCC authorization status for the
/// services macMCP touches. It does NOT call requestAccess / requestFullAccess
/// on any framework, because:
///
///   * Under hardened runtime, tccd silently denies request APIs for any
///     bundle missing the matching com.apple.security.personal-information.*
///     entitlement -- no prompt is ever shown to the user. macmcp.app
///     doesn't declare those entitlements (and shouldn't have to).
///   * The actual prompt-and-grant happens in Relay (which DOES carry the
///     entitlements). macmcp inherits Relay's grants via TCC's
///     responsible-parent attribution at runtime, so no API call from
///     macmcp could ever surface a useful prompt regardless.
///
/// The Settings UI's "Reset Permissions" button drives the whole flow from
/// Relay; this service is just the read-side / status surface.
enum PermissionsService {
    static func register(_ registry: ToolRegistry) {
        registry.register(
            MCPTool(
                name: "permissions_check",
                description: "Report current macOS permission status for the TCC-protected services macMCP uses (Location, Calendars, Contacts, Reminders). Read-only; does not trigger system prompts. Use Relay > Settings > MCP > Reset Permissions to grant or re-grant.",
                inputSchema: emptySchema(),
                annotations: MCPAnnotations(readOnlyHint: true)
            ),
            category: "System"
        ) { _ in
            let results = checkPermissions()
            let denied = results.filter { $0.status != "authorized" }
            if denied.isEmpty {
                return jsonResult(["permissions": results.map(\.dict), "ok": true])
            }
            return jsonResult([
                "permissions": results.map(\.dict),
                "ok": false,
                "message": "Some permissions are not granted. Open Relay > Settings > MCP Servers > macMCP > Reset Permissions, or grant manually in System Settings > Privacy & Security.",
            ])
        }
    }

    /// Read current TCC status for every macmcp-relevant service and return
    /// a human-readable summary. Called from `--check-permissions` CLI mode
    /// (which Relay's Reset Permissions flow spawns for status reporting)
    /// and from the permissions_check MCP tool.
    static func checkAll() -> String {
        let results = checkPermissions()
        var lines: [String] = ["macMCP permissions:"]
        for r in results {
            let icon = r.status == "authorized" ? "+" : "-"
            lines.append("  [\(icon)] \(r.service): \(r.status)")
        }
        let denied = results.filter { $0.status != "authorized" }
        if !denied.isEmpty {
            lines.append("")
            lines.append("Grant via Relay > Settings > MCP > Reset Permissions (or System Settings).")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Implementation

    private struct PermResult {
        let service: String
        let status: String
        var dict: [String: Any] { ["service": service, "status": status] }
    }

    private static func checkPermissions() -> [PermResult] {
        return [
            PermResult(
                service: "location",
                status: statusName(loc: CLLocationManager().authorizationStatus)
            ),
            PermResult(
                service: "calendars",
                status: statusName(ek: EKEventStore.authorizationStatus(for: .event))
            ),
            PermResult(
                service: "contacts",
                status: statusName(cn: CNContactStore.authorizationStatus(for: .contacts))
            ),
            PermResult(
                service: "reminders",
                status: statusName(ek: EKEventStore.authorizationStatus(for: .reminder))
            ),
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
