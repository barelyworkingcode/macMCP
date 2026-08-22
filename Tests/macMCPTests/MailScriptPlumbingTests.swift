import XCTest
@testable import macmcp

/// Cover for how a generated script gets to `osascript` and how what comes back
/// is read.
///
/// Hermetic: every script here is plain JavaScript. Nothing calls
/// `Application(...)`, so no Apple Event leaves the process and no TCC prompt
/// can appear — osascript is being used as a JavaScript engine, the same terms
/// `JXAHarness` runs on.
final class MailScriptPlumbingTests: XCTestCase {
    // MARK: - The script's size

    /// A script that is a `-e` argument is under `ARG_MAX`, which on this
    /// platform is 1,048,576 bytes — and `escapeJSString` renders every
    /// non-ASCII UTF-16 unit as six ASCII bytes, so the real ceiling was about
    /// 1 MB of ASCII but only ~175 KB of Hebrew. A `mail_create_draft` with
    /// 300,000 em dashes came back as "failed to run osascript: The operation
    /// couldn't be completed. Argument list too long": an error that names an
    /// implementation detail rather than the body, for a limit no schema
    /// documented.
    ///
    /// A file has no such ceiling.
    func testAScriptLargerThanARGMAXStillRuns() {
        let filler = String(repeating: "x", count: 2_000_000)
        let (output, error) = MailService.runJXAData(
            "var s = '\(filler)'; JSON.stringify({len: s.length});",
            retries: 0,
            timeout: 30
        )
        XCTAssertNil(error, "a 2 MB script must not be an error about argument lists")
        XCTAssertEqual(
            String(data: output, encoding: .utf8)?.trimmingCharacters(in: .newlines),
            "{\"len\":2000000}"
        )
    }

    /// The other half of the same change. Handing osascript a file makes it
    /// prefix its error line with the file's path —
    ///
    ///     /var/.../macmcp-jxa-<uuid>.js: execution error: Error: Error: … (-2700)
    ///
    /// — and `scriptErrorMessage` requires the text to *begin* with `execution
    /// error: `. Leaving the prefix in place would silently stop every thrown
    /// sentence from being unwrapped, which is the whole of #10's fix undone by
    /// a change of argument style. A script too large to have been an argument
    /// at all is what ties the two together.
    func testASentenceThrownByAnOversizedScriptStillComesBackAsThatSentence() {
        let filler = String(repeating: "x", count: 2_000_000)
        let (_, error) = MailService.runJXAData(
            "var s = '\(filler)'; throw new Error('account \"Alice\" has no mailbox named \"Receipts\"');",
            retries: 0,
            timeout: 30
        )
        XCTAssertEqual(error, "account \"Alice\" has no mailbox named \"Receipts\"")
    }

    func testTheScriptsOwnPathIsRemovedFromWhatOsascriptWrote() {
        let path = "/var/folders/zz/T/macmcp-jxa-DEADBEEF.js"
        XCTAssertEqual(
            MailService.stripScriptPath("\(path): execution error: Error: boom (-2700)", scriptPath: path),
            "execution error: Error: boom (-2700)"
        )
        // Nothing else is touched: the path is a fresh UUID under the temp
        // directory, so a caller's own text cannot impersonate it.
        XCTAssertEqual(
            MailService.stripScriptPath("no mailbox named \"/var/x.js: odd\"", scriptPath: path),
            "no mailbox named \"/var/x.js: odd\""
        )
        XCTAssertEqual(MailService.stripScriptPath("plain", scriptPath: ""), "plain")
    }

    // MARK: - Reading stderr

    func testStderrThatIsNotUTF8KeepsItsOSStatusInsteadOfCollapsing() {
        // stderr used to be read with `String(contentsOf:encoding:.utf8)`, so a
        // byte sequence that is not valid UTF-8 collapsed the whole of it to
        // "". That costs more than the text: `osaStatus("")` is nil, so the
        // -1712, -1728 and -2700 branches are all skipped and the caller is
        // handed "osascript exited with status 1" with the OSStatus this file's
        // comments call "the evidence" thrown away.
        //
        // 0xFF 0xFE cannot begin a UTF-8 sequence. It is written straight to
        // fd 2, ahead of whatever osascript writes there itself.
        let (_, error) = MailService.runJXAData(
            """
            ObjC.import('Foundation');
            $.NSFileHandle.fileHandleWithStandardError
                .writeData($.NSData.alloc.initWithBase64EncodedStringOptions($('//4g'), 0));
            throw new Error('a sentence the script chose');
            """,
            retries: 0,
            timeout: 30
        )
        let text = try? XCTUnwrap(error)
        XCTAssertNotEqual(text, "osascript exited with status 1", "the whole error was discarded")
        XCTAssertTrue(text?.contains("(-2700)") == true, "the OSStatus is the evidence: \(text ?? "nil")")
        XCTAssertTrue(text?.contains("a sentence the script chose") == true, text ?? "nil")
    }

    func testStderrDecodeFallsBackToLatin1RatherThanToNothing() {
        let valid = Data("execution error: fine (-1712)".utf8)
        XCTAssertEqual(MailService.decodeStderr(valid), "execution error: fine (-1712)")

        var invalid = Data([0xFF, 0xFE])
        invalid.append(Data(" (-1728)".utf8))
        let decoded = MailService.decodeStderr(invalid)
        XCTAssertEqual(MailService.osaStatus(decoded)?.code, -1728, "decoded as \(decoded)")

        XCTAssertEqual(MailService.decodeStderr(Data()), "")
    }

    // MARK: - A refused Apple Events grant

    /// stderr for a script that exits non-zero having written exactly what a
    /// TCC refusal looks like. `$.exit` leaves osascript nothing of its own to
    /// add, so the OSStatus at the end of the line is -1743.
    private static let deniedScript = """
    ObjC.import('Foundation');
    ObjC.import('stdlib');
    $.NSFileHandle.fileHandleWithStandardError.writeData(
        $.NSString.alloc.initWithUTF8String(
            'execution error: Not authorized to send Apple events to Mail. (-1743)'
        ).dataUsingEncoding($.NSUTF8StringEncoding)
    );
    $.exit(1);
    """

    func testADeniedGrantReadsLikeADenialRatherThanLikeRawOsascriptOutput() {
        // -1743 was not among the recognised codes, so a denial fell through to
        // the raw-stderr return and reached the caller as `execution error: Not
        // authorized to send Apple events to Mail. (-1743)`. The sentence
        // written for exactly this case lived in a branch only a *timeout*
        // could reach — and a denied grant does not time out, it exits at once.
        let (_, error) = MailService.runJXAData(
            Self.deniedScript,
            retries: 0,
            timeout: 30,
            automationProbe: { .denied }
        )
        XCTAssertEqual(error, MailService.automationDeniedMessage())
        XCTAssertTrue(error?.contains("Reset Permissions") == true, error ?? "nil")
        XCTAssertFalse(error?.contains("-1743") == true, "the code is not what a caller can act on")
    }

    func testTheSameDenialIsReportedWhateverTheProbeHadPredicted() {
        // The diagnosis comes from what the spawn did, not from the prediction:
        // a probe that answered `.granted` a moment before a grant was revoked
        // must not turn a refusal back into "Mail did not respond".
        let (_, error) = MailService.runJXAData(
            Self.deniedScript,
            retries: 0,
            timeout: 30,
            automationProbe: { .granted }
        )
        XCTAssertEqual(error, MailService.automationDeniedMessage())
    }

    func testOnceOneSpawnHasEstablishedARefusalTheRestOfTheCallDoesNotSpawn() {
        // A full-scope `mail_search` is seven or more spawns. Each one used to
        // go and find out for itself, at whatever its deadline was, before the
        // caller was told to go and fix the grant.
        let marker = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macmcp-latch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }

        let call = MailCall(budget: 60) { .denied }
        let (_, first) = MailService.runJXAData(Self.deniedScript, retries: 0, timeout: 30, call: call)
        XCTAssertEqual(first, MailService.automationDeniedMessage())

        let (_, second) = MailService.runJXAData(
            """
            ObjC.import('Foundation');
            $.NSString.alloc.initWithUTF8String('ran')
                .writeToFileAtomicallyEncodingError('\(marker.path)', true, $.NSUTF8StringEncoding, $());
            'ok';
            """,
            retries: 0,
            timeout: 30,
            call: call
        )
        XCTAssertEqual(second, MailService.automationDeniedMessage())
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "the grant is refused for the process, so the second script had nothing to learn and should not have run"
        )
    }

    // MARK: - What a spawn costs before the script starts

    func testASpawnDoesNotPayAFixedPollingTaxBeforeItCanFinish() {
        // The wait used to tick in flat 0.05s steps, so every spawn paid up to
        // 50ms of pure sleep after its script had already exited — and a scan
        // spawns one process per account per pass. Ten trivial scripts is the
        // smallest sample where a 50ms tick is unmistakable against spawn cost.
        let started = Date()
        for _ in 0..<10 {
            let (_, error) = MailService.runJXAData("'x';", retries: 0, timeout: 30)
            XCTAssertNil(error)
        }
        let each = Date().timeIntervalSince(started) / 10
        // osascript itself costs ~60-90ms. The bound is what a 50ms tick on top
        // of that would not fit inside, with room for a loaded machine.
        XCTAssertLessThan(each, 0.12, "each spawn averaged \(Int(each * 1000))ms")
    }
}
