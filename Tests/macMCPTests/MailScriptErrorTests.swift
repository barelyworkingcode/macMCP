import XCTest
@testable import macmcp

/// Regression cover for a thrown script error reaching the caller as osascript's
/// wrapper instead of as the sentence the script threw (issue #19):
///
///     execution error: Error: Error: account "Alice" has no mailbox named "BobOnly" (-2700)
///
/// which is the shape #10 was filed about, reintroduced by the fix for #4 in the
/// path next to the one #18 normalised.
///
/// The inputs here are not hand-written strings pretending to be osascript.
/// Where the wrapper's exact form is the thing under test, the wrapper comes
/// from a real `osascript` run — it is plain JavaScript that never calls
/// `Application(...)`, so nothing leaves the process, the same terms `JXAHarness`
/// runs on.
final class MailScriptErrorTests: XCTestCase {
    /// Runs a script that is expected to fail and returns what osascript wrote
    /// to stderr.
    private func stderrOf(_ script: String) throws -> String {
        do {
            let output = try JXA.run(script)
            XCTFail("script was supposed to fail, printed: \(output)")
            return ""
        } catch let failure as JXA.Failure {
            return failure.stderr
        }
    }

    // MARK: - The reported defect, end to end

    func testAThrownErrorReachesTheCallerAsItsOwnSentence() throws {
        let stderr = try stderrOf(#"throw new Error('account "Alice" has no mailbox named "BobOnly"');"#)
        // What the caller used to get, so the test fails if this stops being
        // the shape being unwrapped.
        XCTAssertTrue(stderr.contains("execution error: Error: Error:"), stderr)
        XCTAssertTrue(stderr.contains("(-2700)"), stderr)

        XCTAssertEqual(
            MailService.scriptErrorMessage(stderr),
            #"account "Alice" has no mailbox named "BobOnly""#
        )
    }

    func testNothingOfOsascriptsWrapperSurvives() throws {
        let stderr = try stderrOf("throw new Error('plain message');")
        let reported = try XCTUnwrap(MailService.scriptErrorMessage(stderr))
        for leak in ["execution error", "Error:", "-2700", "(-"] {
            XCTAssertFalse(reported.contains(leak), "\(leak) leaked: \(reported)")
        }
    }

    func testAThrownStringIsUnwrappedToo() throws {
        // Only osascript's own `Error: ` comes off in this case: there is no
        // JavaScript Error class naming itself, and dropping two prefixes
        // unconditionally would eat the start of the message.
        let stderr = try stderrOf("throw 'bare string, not an Error';")
        XCTAssertEqual(MailService.scriptErrorMessage(stderr), "bare string, not an Error")
    }

    func testAMultiLineMessageIsKeptWhole() throws {
        let stderr = try stderrOf("throw new Error('line one\\nline two');")
        XCTAssertEqual(MailService.scriptErrorMessage(stderr), "line one\nline two")
    }

    // MARK: - What must NOT be unwrapped

    func testATypeErrorKeepsItsClassName() throws {
        // A thrown TypeError is a bug in the generated script rather than a
        // message for the caller, and the class name is the useful part.
        let stderr = try stderrOf("var x = null; x.foo();")
        let reported = try XCTUnwrap(MailService.scriptErrorMessage(stderr))
        XCTAssertTrue(reported.hasPrefix("TypeError: "), reported)
        XCTAssertFalse(reported.contains("execution error"), reported)
    }

    func testASyntaxErrorIsLeftExactlyAsOsascriptWroteIt() throws {
        // Not an `execution error:` at all -- it is reported with a source
        // position, which is what whoever has to fix the generator needs.
        let stderr = try stderrOf("var = ;")
        XCTAssertNil(MailService.scriptErrorMessage(stderr))
    }

    func testMailsOwnErrorCodesAreNotUnwrapped() {
        // -1712 (Apple Event timeout inside Mail) and -1728 (unresolvable
        // reference) are Mail's, not the script's: there is no sentence of ours
        // in there, and the number is the evidence.
        XCTAssertNil(MailService.scriptErrorMessage(
            "execution error: Mail got an error: AppleEvent timed out. (-1712)"
        ))
        XCTAssertNil(MailService.scriptErrorMessage(
            "execution error: Error: Mail got an error: Can't get mailbox. (-1728)"
        ))
    }

    func testStderrThatIsNotAnErrorAtAllIsLeftAlone() {
        XCTAssertNil(MailService.scriptErrorMessage(""))
        XCTAssertNil(MailService.scriptErrorMessage("some warning on stderr"))
        // The wrapper without a message inside it says nothing worth saying, so
        // the raw text is kept rather than replaced with an empty string.
        XCTAssertNil(MailService.scriptErrorMessage("execution error: Error:  (-2700)"))
    }
}
