import XCTest
@testable import macmcp

/// Regression cover for a pending Apple Events consent prompt being reported as
/// "Mail did not respond … narrow the scope" (issue #7).
///
/// Two separate defects were folded into that one sentence: the diagnosis (Mail
/// was never asked anything — the request never got past TCC), and the remedy
/// (`mail_list_accounts` has an empty input schema, so there is no account, no
/// mailbox and no limit to narrow; a caller following the advice retries
/// forever).
final class MailTimeoutMessageTests: XCTestCase {
    private func message(
        automation: AutomationStatus,
        scopable: Bool = true,
        stderr: String = "",
        timeout: TimeInterval = 30
    ) -> String {
        MailService.jxaTimeoutMessage(
            timeout: timeout,
            automation: automation,
            scopable: scopable,
            stderr: stderr
        )
    }

    // MARK: - The consent case

    func testPendingConsentSaysSoAndDoesNotAdviseNarrowingTheScope() {
        let text = message(automation: .pendingConsent, scopable: true)
        XCTAssertTrue(text.contains("permission"), text)
        XCTAssertTrue(text.contains("Approve"), text)
        XCTAssertTrue(text.contains("Automation"), text)
        XCTAssertFalse(text.contains("Narrow the scope"), "scope advice cannot fix a consent prompt: \(text)")
    }

    func testDeniedNamesTheGrantAndWhereToRestoreIt() {
        let text = message(automation: .denied, scopable: true)
        XCTAssertTrue(text.contains("denied"), text)
        XCTAssertTrue(text.contains("Privacy & Security > Automation"), text)
        XCTAssertFalse(text.contains("Narrow the scope"), text)
    }

    func testABlockedPermissionCheckPointsAtThePromptRatherThanAtScope() {
        // The permission check answers in ~10ms normally, but blocks while a
        // consent prompt is waiting -- 12s in one measurement, 73s in another.
        // A check that will not answer is itself evidence of an outstanding
        // decision, so it must not fall back to "Mail was slow".
        let text = message(automation: .checkBlocked, scopable: true)
        XCTAssertTrue(text.contains("consent prompt"), text)
        XCTAssertTrue(text.contains("Automation"), text)
        XCTAssertFalse(text.contains("Narrow the scope"), text)
    }

    func testTargetNotRunningIsNotReportedAsARefusal() {
        // macOS declines to answer while Mail is not running. That is not a
        // denial, and saying it is would send the caller to the wrong place.
        let text = message(automation: .targetNotRunning)
        XCTAssertTrue(text.contains("not running"), text)
        XCTAssertFalse(text.contains("denied"), text)
        XCTAssertFalse(text.contains("Narrow the scope"), text)
    }

    // MARK: - The genuine timeout

    func testGrantedAndScopableKeepsTheScopeAdvice() {
        // The case the original message was written for, and the only one it
        // was right about.
        let text = message(automation: .granted, scopable: true)
        XCTAssertTrue(text.contains("did not respond within 30s"), text)
        XCTAssertTrue(text.contains("Narrow the scope"), text)
    }

    func testGrantedButUnscopableDoesNotAskForSomethingTheSchemaCannotExpress() {
        // mail_list_accounts: {"properties": {}, "required": []}.
        let text = message(automation: .granted, scopable: false)
        XCTAssertTrue(text.contains("did not respond within 30s"), text)
        XCTAssertFalse(text.contains("Narrow the scope"), text)
        XCTAssertTrue(text.contains("nothing to narrow"), text)
    }

    func testUnknownStatusFallsBackToTheGenuineTimeoutWording() {
        // The probe itself failed. Nothing is known about the grant, so nothing
        // is claimed about it.
        let text = message(automation: .unknown(-1), scopable: true)
        XCTAssertTrue(text.contains("did not respond within 30s"), text)
        XCTAssertFalse(text.contains("permission"), text)
    }

    func testTimeoutIsReportedInSeconds() {
        XCTAssertTrue(message(automation: .granted, timeout: 180).contains("180s"))
    }

    // MARK: - Evidence

    func testStderrIsKeptOnEveryPath() {
        // The timeout message used to be built before errOutput was looked at,
        // so anything osascript had written was thrown away -- and it is the
        // only other evidence available.
        for status: AutomationStatus in [.granted, .pendingConsent, .denied, .targetNotRunning, .checkBlocked, .unknown(-1)] {
            let text = message(automation: status, stderr: "execution error: Mail got an error (-1712)")
            XCTAssertTrue(text.contains("-1712"), "\(status): \(text)")
        }
    }

    func testNoStderrAddsNoNoise() {
        XCTAssertFalse(message(automation: .granted, stderr: "").contains("osascript wrote"))
    }
}
