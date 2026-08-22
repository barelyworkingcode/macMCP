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
    /// How long the check is given to answer.
    ///
    /// Named rather than inlined because it is the bound that keeps a
    /// consent-blocked TCC probe from adding its own wait -- measured at 12s and
    /// at 73s -- on top of a mail script's 120s deadline. Two seconds is far
    /// more than the ~10ms the answer takes when nothing is pending, and far
    /// less than any of the blocked measurements.
    static let automationCheckTimeout: TimeInterval = 2

    static func automationStatus(bundleID: String, timeout: TimeInterval = automationCheckTimeout) -> AutomationStatus {
        boundedStatus(timeout: timeout) { probeAutomation(bundleID: bundleID) }
    }

    /// How many probes may be blocked at once before the answer is taken as
    /// read.
    ///
    /// A probe that overruns its deadline does not stop: it is sitting inside
    /// `AEDeterminePermissionToAutomateTarget`, which returns only once the
    /// consent prompt is answered -- 12s in one measurement, 73s in another,
    /// and still blocked 20s after the script that raised the prompt had been
    /// killed. So the thread it is on is spoken for until then, and a caller
    /// that keeps asking keeps starting more.
    ///
    /// Past a handful there is nothing left to learn. A probe already blocked
    /// **is** the evidence that a decision is outstanding, which is what
    /// `.checkBlocked` says; starting an n-th one cannot say anything the first
    /// did not, and the only thing it adds is another stuck thread. Four is
    /// small enough to bound the damage and more than enough to survive an
    /// unlucky overlap of two calls with a prompt that answers in between.
    static let maxConcurrentProbes = 4

    /// Guards `blockedProbes`. Probes run on their own threads, so the count is
    /// genuinely shared.
    private static let probeLock = NSLock()
    /// Probes started and not yet returned.
    private static var blockedProbes = 0

    /// Probes currently stuck inside the TCC check. Exposed for the test that
    /// asserts the cap, which otherwise has no way to see it.
    static var probesInFlight: Int {
        probeLock.lock()
        defer { probeLock.unlock() }
        return blockedProbes
    }

    /// Runs `probe` with a deadline, reporting `.checkBlocked` if it overruns.
    ///
    /// Split out, and not private, so the bound can be tested with a probe that
    /// deliberately does not return. The real probe cannot be made to block on
    /// demand -- it needs an unanswered consent prompt on screen -- and a
    /// property that only reproduces under a condition a test cannot create is
    /// exactly the sort that quietly stops holding.
    ///
    /// **The probe gets a thread of its own, not a `DispatchQueue.global`
    /// one.** The deadline firing does not cancel the work; it only stops
    /// *waiting* for it, and what is left behind is a block sitting inside a
    /// synchronous C call for as long as a consent prompt stays on screen.
    /// libdispatch's global pool is bounded -- 64 threads -- and it is not
    /// macMCP's to spend: `WebService`, `WeatherService`, `LocationService` and
    /// the EventKit services all have their completions delivered through it
    /// while the main RunLoop is being pumped, so enough abandoned probes would
    /// hang tools that have nothing to do with Mail. A dedicated `Thread` is
    /// leaked instead of a pooled worker, and `maxConcurrentProbes` bounds how
    /// many of those there can be.
    ///
    /// The result is handed over under a lock rather than through a bare
    /// `var`. On the deadline path the writer is still running when the reader
    /// has moved on, so an unsynchronised field is a data race whether or not
    /// anything reads it afterwards.
    static func boundedStatus(
        timeout: TimeInterval,
        probe: @escaping @Sendable () -> AutomationStatus
    ) -> AutomationStatus {
        probeLock.lock()
        let alreadyBlocked = blockedProbes
        probeLock.unlock()
        // Every probe this process has started is still waiting on the same
        // prompt, so a new one would wait on it too. Answer with what they
        // already established.
        if alreadyBlocked >= maxConcurrentProbes { return .checkBlocked }

        // A semaphore is safe here, unlike elsewhere in this codebase: the work
        // is one synchronous C call, not a framework callback that would be
        // delivered on the main RunLoop this thread is blocking.
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var value: AutomationStatus?
            func set(_ status: AutomationStatus) {
                lock.lock(); value = status; lock.unlock()
            }
            func get() -> AutomationStatus? {
                lock.lock(); defer { lock.unlock() }; return value
            }
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)

        probeLock.lock(); blockedProbes += 1; probeLock.unlock()
        let worker = Thread {
            let status = probe()
            box.set(status)
            probeLock.lock(); blockedProbes -= 1; probeLock.unlock()
            done.signal()
        }
        worker.stackSize = 512 * 1024
        worker.name = "macmcp.tcc-probe"
        worker.start()

        guard done.wait(timeout: .now() + timeout) == .success else {
            return .checkBlocked
        }
        // The semaphore was signalled after the write, so the value is there.
        return box.get() ?? .unknown(0)
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
