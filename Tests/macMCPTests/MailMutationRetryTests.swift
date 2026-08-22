import XCTest
@testable import macmcp

/// Cover for re-running a script that has already changed something.
///
/// `runJXAData` retries by running the **entire** script again. `mail_move`
/// and `mail_mark_read` were on the default of 2, so a -1728 raised anywhere —
/// including after `found.mailbox = destMbox` had executed — re-ran the move.
/// Same-account that is only wasteful, because the second run finds the
/// message where the first put it. Across accounts it is a wrong answer: the
/// move is a re-upload, the numeric id does not survive it, so the retry's
/// `findMessageJXA` returns null and the caller is told "message not found
/// with id: N" for a move that succeeded.
///
/// These run a script with a side effect on disk, so what is counted is how
/// many times the *whole thing* ran rather than what came back. The failure is
/// synthesised: osascript reports a thrown value with the OSStatus it chose,
/// and `-1728` in that position is what the retry keys on — so a plain
/// JavaScript `throw` carrying it is indistinguishable, to the code under
/// test, from Mail failing to resolve an object. No Apple Event is sent.
final class MailMutationRetryTests: XCTestCase {
    /// A script that records each run and then fails the way Mail's
    /// "object not found" surfaces.
    ///
    /// The failure is written to stderr and the process exits non-zero
    /// directly, rather than throwing: osascript appends **its own** OSStatus
    /// to anything a script throws, so a thrown `(-1728)` reaches the caller
    /// as `... (-1728) (-2700)` and is read -- correctly -- as -2700. What the
    /// retry keys on is the code osascript writes last, so that is what has to
    /// be produced.
    private func countingScript(marker: URL, osaStatus: Int) -> String {
        """
        ObjC.import('Foundation');
        ObjC.import('stdlib');
        var path = '\(marker.path)';
        var existing = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
        var text = (existing.js === undefined ? '' : existing.js) + 'ran\\n';
        $(text).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null);
        var line = 'execution error: Mail got an error: AppleEvent handler failed. (\(osaStatus))\\n';
        $.NSFileHandle.fileHandleWithStandardError.writeData(
            $(line).dataUsingEncoding($.NSUTF8StringEncoding));
        $.exit(1);
        """
    }

    private func runsRecorded(retries: Int, osaStatus: Int = -1728) throws -> Int {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("macmcp-retry-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: marker) }
        let (_, error) = MailService.runJXAData(
            countingScript(marker: marker, osaStatus: osaStatus),
            retries: retries,
            timeout: 20,
            scopable: false,
            // The automation grant is never asked of TCC here: this script
            // talks to nothing, and probing would be the one thing in it that
            // could block.
            automationProbe: { .granted }
        )
        XCTAssertNotNil(error, "the script was supposed to fail")
        let text = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").count
    }

    // MARK: - The defect

    func testAMutatingToolDoesNotRunItsScriptTwice() throws {
        // What `mail_move` and `mail_mark_read` pass. A second run of a move
        // script is a second move.
        XCTAssertEqual(
            try runsRecorded(retries: MailService.mutatingRetries),
            1,
            "a script that changes something was run more than once"
        )
    }

    func testMutatingToolsAgreeOnNotRetrying() {
        XCTAssertEqual(MailService.mutatingRetries, 0)
    }

    // MARK: - Controls, so the count above is measuring something

    func testTheRetryMechanismDoesReRunTheWholeScript() throws {
        // The behaviour the constant exists to keep away from mutations: this
        // is what `mail_move` was doing. If this ever stops being 3 the test
        // above has stopped proving anything.
        XCTAssertEqual(try runsRecorded(retries: 2), 3)
    }

    func testOnlyObjectNotFoundIsRetriedAtAll() throws {
        // -2700 is "the script threw"; the sentence is ours and re-running it
        // would only produce the same sentence.
        XCTAssertEqual(try runsRecorded(retries: 2, osaStatus: -2700), 1)
    }
}
