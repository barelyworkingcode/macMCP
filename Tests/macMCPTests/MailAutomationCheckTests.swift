import XCTest
@testable import macmcp

/// Cover for the half of #7's fix that is behaviour rather than wording: the
/// automation grant is taken **before** the script runs, and the check that
/// takes it is **bounded**.
///
/// `MailTimeoutMessageTests` asserts what the timeout message says. It would
/// stay green if the grant were read on the error path afterwards, which is the
/// arrangement PR #15 removed: that check blocks while a consent prompt is on
/// screen — measured at 12s, at 73s, and still blocked 20s after the script that
/// raised the prompt had been killed — so asking after a 120s deadline adds an
/// unbounded wait to an already-expired request. Verification had to establish
/// that empirically (75.8s raw against 32.1s through macMCP) for want of a test.
///
/// Hermetic: the scripts here are plain JavaScript that never calls
/// `Application(...)`, so no Apple Event leaves the process and no TCC prompt
/// can appear — osascript is a JavaScript engine, the same terms `JXAHarness`
/// runs on. The grant itself is supplied by an injected probe.
final class MailAutomationCheckTests: XCTestCase {
    private var marker: URL!

    override func setUpWithError() throws {
        marker = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macmcp-probe-order-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: marker)
    }

    /// A script that records having started, by writing the marker file, and
    /// then does whatever `then` says.
    ///
    /// The marker is what makes the ordering observable: a probe that finds it
    /// already there was called after the script began, which is the arrangement
    /// PR #15 removed.
    private func markerScript(then: String) -> String {
        """
        ObjC.import('Foundation');
        $.NSString.alloc.initWithUTF8String('ran')
            .writeToFileAtomicallyEncodingError('\(marker.path)', true, $.NSUTF8StringEncoding, $());
        \(then)
        """
    }

    // MARK: - Ordering

    func testTheAutomationGrantIsTakenBeforeTheScriptRuns() {
        // The probe looks for evidence that the script has already run. If the
        // grant were read afterwards -- on the error path, as it used to be --
        // the marker would be there by the time it looked.
        var probeCalls = 0
        var scriptHadAlreadyRun: Bool?
        let (output, error) = MailService.runJXAData(markerScript(then: "'ok';"), retries: 0) {
            probeCalls += 1
            scriptHadAlreadyRun = FileManager.default.fileExists(atPath: self.marker.path)
            return .granted
        }

        XCTAssertNil(error)
        XCTAssertEqual(String(data: output, encoding: .utf8)?.trimmingCharacters(in: .newlines), "ok")
        XCTAssertEqual(probeCalls, 1, "the grant is read once per run, not once per attempt")
        XCTAssertEqual(scriptHadAlreadyRun, false, "the automation grant was read after the script ran")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker.path),
            "the script never ran, so the ordering assertion above proved nothing"
        )
    }

    func testTheStatusReportedOnATimeoutIsTheOneTakenBeforeTheRun() {
        // A script that outlives its deadline, with a probe that answers
        // "pending consent". The message can only say so if the answer was
        // taken before the run: asking now, on the error path, is the thing
        // that blocks, and this machine's real answer is not pendingConsent
        // anyway.
        var scriptHadAlreadyRun: Bool?
        let started = Date()
        let (_, error) = MailService.runJXAData(
            markerScript(then: "delay(5); 'never';"),
            retries: 0,
            timeout: 0.5
        ) {
            scriptHadAlreadyRun = FileManager.default.fileExists(atPath: self.marker.path)
            return .pendingConsent
        }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(scriptHadAlreadyRun, false, "the grant was read on the timeout path, which is where it blocks")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "the script never started")

        let message = try? XCTUnwrap(error)
        XCTAssertTrue(message?.contains("Mail was never asked") == true, message ?? "no error")
        XCTAssertFalse(message?.contains("Narrow the scope") == true, message ?? "")
        // The deadline, plus the 2s SIGKILL backstop, plus slack. Nothing here
        // may wait on a TCC check that would not answer.
        XCTAssertLessThan(elapsed, 5, "the timeout path waited on something it should not have")
    }

    func testAScriptThatFailsAlsoReportsTheStatusTakenBeforehand() {
        // Same ordering requirement on the non-zero-exit path: a script that
        // throws while the grant is pending must not send the caller off to
        // read a status that would block.
        var probeCalls = 0
        var scriptHadAlreadyRun: Bool?
        let (_, error) = MailService.runJXAData(
            markerScript(then: "throw new Error('boom');"),
            retries: 0
        ) {
            probeCalls += 1
            scriptHadAlreadyRun = FileManager.default.fileExists(atPath: self.marker.path)
            return .denied
        }
        XCTAssertEqual(probeCalls, 1)
        XCTAssertEqual(scriptHadAlreadyRun, false, "the grant was read on the error path")
        XCTAssertEqual(error, "boom")
    }

    // MARK: - The bound

    func testTheAutomationCheckIsBoundedSoABlockedProbeCannotHang() {
        // The real probe blocks only while a consent prompt is on screen, which
        // a test cannot arrange -- so the deadline is exercised with a probe
        // that simply does not come back.
        let started = Date()
        let status = PermissionsService.boundedStatus(timeout: 0.2) {
            Thread.sleep(forTimeInterval: 5)
            return .granted
        }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(status, .checkBlocked, "a probe that will not answer must not be waited on")
        XCTAssertLessThan(elapsed, 2, "the deadline did not fire; elapsed \(elapsed)s")
    }

    func testAProbeThatAnswersInTimeIsReportedAsItAnswered() {
        XCTAssertEqual(PermissionsService.boundedStatus(timeout: 2) { .denied }, .denied)
        XCTAssertEqual(PermissionsService.boundedStatus(timeout: 2) { .targetNotRunning }, .targetNotRunning)
    }

    // `testTheDefaultBoundIsTwoSeconds` used to sit here, asserting
    // `automationCheckTimeout == 2`. It restated the constant it read: the only
    // change that could break it was a change to that same line, so it caught no
    // regression and made the number harder to tune (#42). The two tests around
    // it cover the behaviour — a probe that will not answer is not waited on,
    // and the real check comes back inside its own bound — which is what the
    // number is for.

    func testTheRealCheckReturnsWithinItsBound() {
        // No Apple Event is sent (`askUserIfNeeded: false`), so this asks TCC
        // about Mail without touching Mail. Only the timing is asserted -- the
        // answer depends on the machine, and a blocked answer is a legitimate
        // result of running this while a prompt is up.
        let started = Date()
        _ = PermissionsService.automationStatus(bundleID: MailService.mailBundleID)
        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            PermissionsService.automationCheckTimeout + 1
        )
    }
}
