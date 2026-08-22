import XCTest
@testable import macmcp

/// Cover for what a TCC probe that overruns its deadline leaves behind.
///
/// `boundedStatus` gives up waiting; it cannot give up on the *work*. The probe
/// is sitting inside `AEDeterminePermissionToAutomateTarget`, which returns
/// only once the consent prompt on screen is answered — measured at 12s in one
/// run, 73s in another, and still blocked 20s after the script that raised the
/// prompt had been killed. So whatever thread it is on is spoken for until
/// then.
///
/// It used to be a `DispatchQueue.global` thread. That pool is bounded at 64
/// and it is not this file's to spend: `WebService`, `WeatherService`,
/// `LocationService` and the EventKit services all have their completions
/// delivered through libdispatch while `CFRunLoopRunInMode` pumps the main
/// RunLoop, so enough abandoned probes hang tools that have nothing to do with
/// Mail.
///
/// Hermetic: nothing here touches TCC. The real probe cannot be made to block
/// on demand — that needs an unanswered consent prompt — so it is replaced by
/// one that waits on a semaphore this test controls.
final class AutomationProbePoolTests: XCTestCase {
    /// Released in teardown so every probe this test stranded can finish and
    /// its thread exit, rather than being left blocked for the rest of the run.
    private var release: DispatchSemaphore!

    override func setUpWithError() throws {
        release = DispatchSemaphore(value: 0)
    }

    override func tearDownWithError() throws {
        for _ in 0..<200 { release.signal() }
        release = nil
        // Give the stranded probes a moment to notice and decrement the count,
        // so a later test in the same process starts from a clean slate.
        let deadline = Date().addingTimeInterval(5)
        while PermissionsService.probesInFlight > 0 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    func testAbandonedProbesDoNotStarveTheDispatchPoolEveryOtherServiceUses() {
        let semaphore = release!
        for _ in 0..<200 {
            let status = PermissionsService.boundedStatus(timeout: 0.05) {
                semaphore.wait()
                return .granted
            }
            XCTAssertEqual(status, .checkBlocked)
        }

        // The property under test, stated the way another service would meet
        // it: a completion delivered through libdispatch still arrives.
        let delivered = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async { delivered.signal() }
        XCTAssertEqual(
            delivered.wait(timeout: .now() + 5), .success,
            "200 abandoned TCC probes took libdispatch's global pool with them, "
            + "so a service with nothing to do with Mail can no longer be called back"
        )
    }

    func testOnlyAHandfulOfProbesAreEverLeftBlockedAtOnce() {
        // Past a handful there is nothing left to learn: a probe already
        // blocked *is* the evidence that a decision is outstanding, which is
        // what `.checkBlocked` says. Starting an n-th one adds another stuck
        // thread and no information.
        let semaphore = release!
        for _ in 0..<50 {
            _ = PermissionsService.boundedStatus(timeout: 0.05) {
                semaphore.wait()
                return .granted
            }
        }
        XCTAssertLessThanOrEqual(
            PermissionsService.probesInFlight,
            PermissionsService.maxConcurrentProbes,
            "50 calls left \(PermissionsService.probesInFlight) probes blocked"
        )
    }

    func testTheCapAnswersRatherThanRefusing() {
        // Being at the cap is not an error: it is `.checkBlocked`, which is a
        // real state with a real remedy, and it is what the blocked probes
        // already established.
        let semaphore = release!
        for _ in 0..<(PermissionsService.maxConcurrentProbes + 3) {
            XCTAssertEqual(
                PermissionsService.boundedStatus(timeout: 0.05) {
                    semaphore.wait()
                    return .granted
                },
                .checkBlocked
            )
        }
    }

    func testAProbeThatAnswersIsStillReportedNormally() {
        XCTAssertEqual(PermissionsService.boundedStatus(timeout: 2) { .granted }, .granted)
        XCTAssertEqual(PermissionsService.boundedStatus(timeout: 2) { .pendingConsent }, .pendingConsent)
        XCTAssertEqual(PermissionsService.probesInFlight, 0, "a probe that answered was not accounted for")
    }
}
