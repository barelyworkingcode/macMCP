import XCTest
@testable import macmcp

/// Cover for the deadline layer: one budget per `tools/call`, spent by every
/// script beneath it.
///
/// There used to be no bound above the individual `osascript` spawn, and spawns
/// compose. `mail_get_emails` runs one per account, `mail_search` runs two of
/// those passes and then a body pass, and each was handed the full 120s on its
/// own — 406s at two accounts, 1398s at ten, and about 1408s for a
/// `mail_search` with `search_body`. `main.swift` reads stdin one line at a
/// time, so for the whole of that nothing else is served.
///
/// Hermetic. The scripts here are plain JavaScript — `delay` and the
/// Foundation bridge are available to osascript without any application being
/// scripted — so no Apple Event leaves the process and no TCC prompt can
/// appear. The automation grant is supplied by an injected probe.
final class MailCallBudgetTests: XCTestCase {
    private var markers: [URL] = []

    override func tearDownWithError() throws {
        for url in markers { try? FileManager.default.removeItem(at: url) }
        markers = []
    }

    /// A fresh marker path, removed at teardown.
    private func newMarker() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macmcp-budget-\(UUID().uuidString)")
        markers.append(url)
        return url
    }

    private func ran(_ marker: URL) -> Bool {
        FileManager.default.fileExists(atPath: marker.path)
    }

    /// A script that records having started and then does `then`.
    private func markerScript(_ marker: URL, then: String) -> String {
        """
        ObjC.import('Foundation');
        $.NSString.alloc.initWithUTF8String('ran')
            .writeToFileAtomicallyEncodingError('\(marker.path)', true, $.NSUTF8StringEncoding, $());
        \(then)
        """
    }

    // MARK: - The arithmetic, without spawning anything

    func testAScriptGetsItsOwnCeilingWhenThereIsNoCallAroundIt() {
        XCTAssertEqual(
            MailService.spawnAllowance(scriptCeiling: 120, callRemaining: nil, automationInDoubt: false),
            120
        )
    }

    func testTheCallsRemainingBudgetWinsWhenItIsTheSmaller() {
        XCTAssertEqual(
            MailService.spawnAllowance(scriptCeiling: 120, callRemaining: 7, automationInDoubt: false),
            7,
            "a script may not outlive the call it belongs to"
        )
    }

    func testTheScriptsOwnCeilingStillWinsWhenTheBudgetIsLarger() {
        XCTAssertEqual(
            MailService.spawnAllowance(scriptCeiling: 30, callRemaining: 300, automationInDoubt: false),
            30,
            "a budget is a ceiling, not an allocation: it does not hand a cheap script more time"
        )
    }

    func testADoubtfulAutomationGrantCutsTheFirstSpawnToTheWindow() {
        XCTAssertEqual(
            MailService.spawnAllowance(scriptCeiling: 120, callRemaining: 300, automationInDoubt: true),
            MailCall.automationDoubtWindow
        )
        XCTAssertLessThan(
            MailCall.automationDoubtWindow, MailService.defaultTimeout,
            "the window exists to be shorter than the ordinary deadline"
        )
    }

    func testTheWindowDoesNotLengthenASpawnThatWasAlreadyShorter() {
        XCTAssertEqual(
            MailService.spawnAllowance(scriptCeiling: 3, callRemaining: nil, automationInDoubt: true),
            3
        )
    }

    func testWhichStatusesCountAsDoubt() {
        // A refused, pending or unanswerable grant all mean the next Apple
        // Event is unlikely to get through, and are worth settling quickly.
        XCTAssertTrue(MailService.automationIsInDoubt(.denied))
        XCTAssertTrue(MailService.automationIsInDoubt(.pendingConsent))
        XCTAssertTrue(MailService.automationIsInDoubt(.checkBlocked))
        // Mail not running is not a permission problem: sending the event is
        // what launches it, and a cold launch can outlast the window.
        XCTAssertFalse(MailService.automationIsInDoubt(.targetNotRunning))
        XCTAssertFalse(MailService.automationIsInDoubt(.granted))
        XCTAssertFalse(MailService.automationIsInDoubt(.unknown(0)))
    }

    // MARK: - What a caller may ask for

    func testTheDefaultIsUsedWhenTheCallerSaysNothing() {
        XCTAssertEqual(MailCall.forArguments(nil, default: 90).budget, 90)
    }

    func testACallerSuppliedBudgetIsHonouredAndClamped() {
        func budget(_ seconds: Int) -> TimeInterval {
            MailCall.forArguments(["timeout_seconds": .int(seconds)], default: 120).budget
        }
        XCTAssertEqual(budget(45), 45)
        XCTAssertEqual(budget(0), MailCall.minCallerBudget, "a budget no step can complete in is not accepted")
        XCTAssertEqual(budget(-10), MailCall.minCallerBudget)
        XCTAssertEqual(budget(100_000), MailCall.maxCallerBudget, "the ceiling is the point of the type")
    }

    // MARK: - Exhaustion

    func testABudgetThatHasRunOutIsExhaustedAndSaysWhy() {
        let call = MailCall(budget: 0) { .granted }
        XCTAssertTrue(call.isExhausted)
        let reason = call.skipReason(scopable: true)
        XCTAssertTrue(reason.contains("time budget ran out"), reason)
        XCTAssertTrue(reason.contains("timeout_seconds"), "the caller is told what to change: \(reason)")
        XCTAssertTrue(reason.contains("Narrow the scope"), reason)
    }

    func testATooSmallRemainderIsTreatedAsExhausted() {
        // A spawn costs ~150ms before the script runs at all, and the cheapest
        // real Mail script measured ~0.3s — which the 8.1x contention swing
        // takes to ~2.4s. Starting one with less than this left buys a killed
        // process rather than an answer.
        let call = MailCall(budget: MailCall.minimumSlice / 2) { .granted }
        XCTAssertTrue(call.isExhausted)
        XCTAssertGreaterThan(call.remaining, 0, "there is time left; it is just not enough to be worth a spawn")
    }

    func testAToolWithNothingToNarrowIsNotToldToNarrowIt() {
        // mail_list_accounts takes no account, no mailbox and no limit.
        let reason = MailCall(budget: 0) { .granted }.skipReason(scopable: false)
        XCTAssertFalse(reason.contains("Narrow the scope"), reason)
        XCTAssertTrue(reason.contains("timeout_seconds"), reason)
    }

    // MARK: - The budget spent across spawns

    func testTwoScriptsUnderOneCallShareItsBudget() {
        // The defect this pins: each spawn used to be given the full deadline
        // independently, so two of them cost twice the wait and n of them cost
        // n times it. A budget is not a per-spawn ceiling.
        let first = newMarker()
        let second = newMarker()
        let call = MailCall(budget: 5) { .granted }

        let started = Date()
        let (_, firstError) = MailService.runJXAData(
            markerScript(first, then: "delay(60); 'never';"),
            retries: 0,
            timeout: MailService.defaultTimeout,
            call: call
        )
        let (_, secondError) = MailService.runJXAData(
            markerScript(second, then: "'quick';"),
            retries: 0,
            timeout: MailService.defaultTimeout,
            call: call
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(ran(first), "the first script never ran, so nothing below proves anything")
        XCTAssertNotNil(firstError, "a script that outlives the budget is not a success")
        XCTAssertFalse(
            ran(second),
            "the budget was gone, so the second script should not have been spawned at all"
        )
        XCTAssertEqual(secondError, call.skipReason(scopable: true))
        // 5s budget, plus the 2s SIGKILL backstop, plus slack. Twice the
        // deadline is what this is here to rule out.
        XCTAssertLessThan(elapsed, 8, "two spawns under one 5s budget took \(elapsed)s")
    }

    func testWorkAlreadyDoneIsNotDiscardedWhenTheBudgetRunsOut() {
        // Running out is reported, not raised: `skipReason` is a sentence a
        // scan puts in `failed_accounts`, which is what makes `scan_complete`
        // false. The rows already read still come back.
        let call = MailCall(budget: 60) { .granted }
        let (output, error) = MailService.runJXAData("'rows';", retries: 0, call: call)
        XCTAssertNil(error)
        XCTAssertEqual(String(data: output, encoding: .utf8)?.trimmingCharacters(in: .newlines), "rows")
        XCTAssertFalse(call.isExhausted)
    }

    // MARK: - The automation grant is a per-call fact

    func testTheAutomationGrantIsReadOnceForTheWholeCall() {
        // It used to be read once per spawn. It describes this process, not
        // this script, and reading it is not free: the check blocks while a
        // consent prompt is on screen, so it is bounded at 2s — and a
        // full-scope search paid that bound once per account per pass.
        var probeCalls = 0
        let call = MailCall(budget: 60) { probeCalls += 1; return .granted }
        for script in ["'a';", "'b';", "'c';"] {
            _ = MailService.runJXAData(script, retries: 0, call: call)
        }
        XCTAssertEqual(probeCalls, 1, "the grant was taken once per spawn rather than once per call")
    }
}
