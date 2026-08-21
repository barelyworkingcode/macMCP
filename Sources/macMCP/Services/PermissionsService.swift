import Contacts
import CoreLocation
import CoreServices
import EventKit
import Foundation

/// Whether this process may drive another app with Apple Events.
///
/// Distinct from the framework permissions below because it is the only TCC
/// service macMCP can be *blocked on* rather than merely refused: an
/// unanswered consent prompt leaves `osascript` sitting there until something
/// gives up, which is indistinguishable from the target app being slow unless
/// you go and ask.
enum AutomationStatus: Equatable {
    /// Allowed. Apple Events reach the target.
    case granted
    /// Not yet decided. macOS will put a consent prompt on screen -- and block
    /// until it is answered -- the next time an event is sent.
    case pendingConsent
    /// Refused, either by the user or by policy. Events fail immediately.
    case denied
    /// The target app is not running, so macOS will not say. Nothing can be
    /// concluded about the grant from this.
    case targetNotRunning
    /// The check did not answer within its deadline. Measured cause: TCC blocks
    /// this call while a consent prompt is waiting to be answered -- 12s in one
    /// run, 73s in another -- so a blocked check is itself evidence that a
    /// decision is outstanding.
    case checkBlocked
    case unknown(OSStatus)
}

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
                description: "Report current macOS permission status for the TCC-protected services macMCP uses (Location, Calendars, Contacts, Reminders, and Automation of Mail, which every mail_* tool needs). Read-only; does not trigger system prompts. Use Relay > Settings > MCP > Reset Permissions to grant or re-grant.",
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

    // MARK: - Apple Events

    /// Current Apple Events (Automation) grant for one target app.
    ///
    /// `askUserIfNeeded: false` means no prompt is ever raised by asking, and
    /// with nothing else going on the answer comes back in about 10ms.
    ///
    /// It is **not** always that fast, which is why there is a deadline. While
    /// a consent prompt is on screen the call blocks until the prompt is
    /// answered -- measured at 12s here, and still blocked 20s after the script
    /// that raised the prompt had been killed. A caller that asks at the wrong
    /// moment therefore has to be able to give up, and `timeout` is that
    /// escape hatch rather than a nicety.
    ///
    /// The question is asked about *this* process, which is the same subject
    /// TCC attributes the `osascript` children to via responsible-process
    /// attribution, so the answer describes the calls macMCP actually makes.
    static func automationStatus(bundleID: String, timeout: TimeInterval = 2) -> AutomationStatus {
        // A semaphore is safe here, unlike elsewhere in this codebase: the work
        // is one synchronous C call, not a framework callback that would be
        // delivered on the main RunLoop this thread is blocking.
        final class Box: @unchecked Sendable { var value: AutomationStatus = .unknown(0) }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = probeAutomation(bundleID: bundleID)
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            return .checkBlocked
        }
        return box.value
    }

    private static func probeAutomation(bundleID: String) -> AutomationStatus {
        var target = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        let created = AECreateDesc(typeApplicationBundleID, bytes, bytes.count, &target)
        guard created == noErr else { return .unknown(OSStatus(created)) }
        defer { AEDisposeDesc(&target) }

        switch AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false) {
        case noErr: return .granted
        case OSStatus(errAEEventWouldRequireUserConsent): return .pendingConsent
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .targetNotRunning
        case let other: return .unknown(other)
        }
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
            // Every mail_* tool goes through Apple Events to Mail. Without this
            // grant they do not fail, they *hang* on a consent prompt until the
            // deadline fires, so it is worth being able to see it before that.
            PermResult(
                service: "automation (Mail)",
                status: statusName(ae: automationStatus(bundleID: "com.apple.mail"))
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

    private static func statusName(ae status: AutomationStatus) -> String {
        switch status {
        case .granted:          return "authorized"
        case .pendingConsent:   return "not_determined"
        case .denied:           return "denied"
        // Not a refusal: macOS declines to answer while the target is not
        // running, so reporting it as denied would be wrong.
        case .targetNotRunning: return "target_not_running"
        // Reported separately from "unknown": it is a real, repeatable state
        // with a real remedy (answer the prompt), not an absence of information.
        case .checkBlocked:     return "check_blocked_by_pending_prompt"
        case .unknown:          return "unknown"
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
