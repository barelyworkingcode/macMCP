import XCTest
@testable import macmcp

/// Covers the RFC 822 reader that `mail_save_attachment` and `mail_get_email`
/// both depend on. These describe behaviour that already worked; they are here
/// so a change made for one of the mail fixes cannot quietly break it.
final class MIMETests: XCTestCase {
    private func message(_ lines: String) -> Data {
        Data(lines.replacingOccurrences(of: "\n", with: "\r\n").utf8)
    }

    func testBase64AttachmentDecodesByteExact() {
        let payload = Data([0x00, 0x01, 0xFF, 0xFE, 0x80, 0x7F])
        let source = message("""
        From: a@example.org
        Subject: hi
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        body
        --B
        Content-Type: application/octet-stream; name="raw.bin"
        Content-Disposition: attachment; filename="raw.bin"
        Content-Transfer-Encoding: base64

        \(payload.base64EncodedString())
        --B--
        """)
        let attachments = MIME.attachments(of: MIME.parse(source))
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments[0].name, "raw.bin")
        XCTAssertEqual(attachments[0].mimeType, "application/octet-stream")
        XCTAssertEqual(attachments[0].data, payload)
    }

    func testTextBodyPartsAreNotAttachments() {
        let source = message("""
        Content-Type: multipart/alternative; boundary="B"

        --B
        Content-Type: text/plain

        plain
        --B
        Content-Type: text/html

        <p>html</p>
        --B--
        """)
        XCTAssertTrue(MIME.attachments(of: MIME.parse(source)).isEmpty)
    }

    func testQuotedPrintableAndEncodedWordFilename() {
        let source = message("""
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain; charset=utf-8
        Content-Disposition: attachment; filename="=?utf-8?Q?caf=C3=A9.txt?="
        Content-Transfer-Encoding: quoted-printable

        caf=C3=A9
        --B--
        """)
        let attachments = MIME.attachments(of: MIME.parse(source))
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments[0].name, "café.txt")
        XCTAssertEqual(String(data: attachments[0].data, encoding: .utf8), "café")
    }

    func testMimeTypeFromFilenameIsAGuess() {
        // The filename guess is fine as a fallback and wrong as a source of
        // truth -- see MailAttachmentTypeTests for the difference that matters.
        XCTAssertEqual(MIME.mimeType(forFilename: "data.csv"), "text/csv")
        XCTAssertEqual(MIME.mimeType(forFilename: "no-extension"), "application/octet-stream")
    }
}

/// Proves the JavaScript harness itself works, so a failure in a generated-script
/// test can be read as a failure of the script rather than of the plumbing.
final class JXAHarnessTests: XCTestCase {
    func testStubMailExposesAccountsAndBulkColumns() throws {
        let script = """
        \(MailStubJS.source)
        var mail = makeMail({accounts: [
            {name: 'Alice', mailboxes: [{name: 'INBOX', messages: [{id: 1, subject: 'one'}]}]},
            {name: 'Bob', mailboxes: [{name: 'INBOX', messages: [{id: 2, subject: 'two'}]}]}
        ]});
        var accts = mail.accounts();
        JSON.stringify({
            names: accts.map(function(a) { return a.name(); }),
            ids: accts[1].mailboxes()[0].messages.id(),
            element: accts[1].mailboxes()[0].messages[0].subject()
        });
        """
        let result = try JXA.runJSON(script)
        XCTAssertEqual(result["names"] as? [String], ["Alice", "Bob"])
        XCTAssertEqual(result["ids"] as? [Int], [2])
        XCTAssertEqual(result["element"] as? String, "two")
    }

    func testStubRecordsMailboxAssignment() throws {
        let script = """
        \(MailStubJS.source)
        var mail = makeMail({accounts: [
            {name: 'Alice', mailboxes: [{name: 'INBOX', messages: [{id: 1}]}, {name: 'Archive'}]}
        ]});
        var acct = mail.accounts()[0];
        acct.mailboxes()[0].messages[0].mailbox = acct.mailboxes()[1];
        JSON.stringify(mail.log.moves);
        """
        let output = try JXA.run(script)
        XCTAssertTrue(output.contains("\"Archive\""), output)
    }
}

/// Cover for the limits the reader applies to a message it did not write, and
/// for saying so when it applies one.
///
/// The parse used to be recursive with no depth bound at all, over a structure
/// the *sender* chooses. A 929 KB message nested ~13,000 levels deep exhausted
/// the 8 MB main-thread stack and killed macmcp with SIGSEGV — no response, no
/// error, and all 46 tools gone with it, macmcp being one synchronous stdin
/// loop. It was reachable from `mail_get_email` and `mail_save_attachment`,
/// both of which parse raw source. Measured at the time: depth 12,000 parsed,
/// depth 13,000 exited 139.
///
/// So these are not decoration. Every one of them either crashed the test
/// runner outright against the old parser or asserted a report that did not
/// exist.
final class MIMELimitTests: XCTestCase {
    /// A message whose `multipart/*` parts nest `levels` deep, with a single
    /// attachment at the bottom of the stack.
    ///
    /// The leaf sits one level below the innermost multipart, so
    /// `nested(levels: n)` is a tree of depth `n + 1`.
    private func nested(levels: Int, payload: String = "deep") -> Data {
        var text = ""
        for level in 1...levels {
            text += "Content-Type: multipart/mixed; boundary=\"B\(level)\"\r\n\r\n--B\(level)\r\n"
        }
        text += "Content-Type: application/octet-stream\r\n"
        text += "Content-Disposition: attachment; filename=\"deep.bin\"\r\n\r\n\(payload)\r\n"
        for level in stride(from: levels, through: 1, by: -1) {
            text += "--B\(level)--\r\n"
        }
        return Data(text.utf8)
    }

    // MARK: - Depth

    func testAnOrdinaryMessageIsReportedAsCompleteAndSaysItsShape() {
        let report = MIME.parseReporting(nested(levels: 2)).report
        XCTAssertTrue(report.complete)
        XCTAssertEqual(report.depth, 3, "two multiparts and the leaf below them")
        XCTAssertEqual(report.parts, 3)
        XCTAssertEqual(report.unparsedMultiparts, 0)
        XCTAssertNil(report.note)
        XCTAssertEqual(report.dict["parsed_complete"] as? Bool, true)
    }

    func testAMessageNestedExactlyToTheCapIsReadInFull() {
        // The deepest tree that is still entirely read: the innermost multipart
        // sits one level above the cap, so its children are still descended to.
        let source = nested(levels: MIME.maxDepth - 1)
        let parsed = MIME.parseReporting(source)
        XCTAssertTrue(parsed.report.complete, parsed.report.note ?? "")
        XCTAssertEqual(parsed.report.depth, MIME.maxDepth)
        XCTAssertEqual(MIME.attachments(of: parsed.part).map(\.name), ["deep.bin"])
    }

    func testAMessageNestedPastTheCapStopsDescendingAndReportsIt() throws {
        let parsed = MIME.parseReporting(nested(levels: MIME.maxDepth))
        XCTAssertFalse(parsed.report.complete)
        XCTAssertTrue(parsed.report.depthLimited)
        XCTAssertEqual(parsed.report.unparsedMultiparts, 1)
        XCTAssertEqual(parsed.report.depth, MIME.maxDepth)

        // The attachment below the cap is simply not there — which is exactly
        // why the report has to be, since a short list is indistinguishable
        // from a message that has fewer attachments.
        XCTAssertTrue(MIME.attachments(of: parsed.part).isEmpty)

        let dict = parsed.report.dict
        XCTAssertEqual(dict["parsed_complete"] as? Bool, false)
        XCTAssertEqual(dict["unparsed_parts"] as? Int, 1)
        XCTAssertEqual(dict["max_depth"] as? Int, MIME.maxDepth)
        let note = try XCTUnwrap(dict["note"] as? String)
        XCTAssertTrue(note.contains("\(MIME.maxDepth)"), note)
        XCTAssertTrue(note.contains("not in this result"), note)
    }

    func testTheDeepestPartIsKeptRatherThanDropped() {
        // Not descended into is not the same as discarded: the part is still in
        // the tree, still carries its own bytes, and is flagged. Inventing a
        // leaf, or silently dropping the branch, would both be answers the
        // reader cannot stand behind.
        var part = MIME.parseReporting(nested(levels: MIME.maxDepth)).part
        for _ in 1..<MIME.maxDepth {
            XCTAssertFalse(part.unparsed)
            part = try! XCTUnwrap(part.parts.first)
        }
        XCTAssertTrue(part.isMultipart)
        XCTAssertTrue(part.unparsed)
        XCTAssertTrue(part.parts.isEmpty)
        XCTAssertFalse(part.body.isEmpty, "the unread bytes are still there")
    }

    func testTheDepthThatUsedToKillTheProcessNowJustComesBackWithAReport() {
        // 20,000 levels is well past the 13,000 that exited 139, and past the
        // 12,000 that was the last depth to survive. Both the parse and the
        // attachment walk are exercised, because both used to recurse.
        let source = nested(levels: 20_000)
        XCTAssertGreaterThan(source.count, 929_000, "at least as large as the message that crashed")
        let parsed = MIME.parseReporting(source)
        XCTAssertTrue(parsed.report.depthLimited)
        XCTAssertEqual(parsed.report.depth, MIME.maxDepth)
        XCTAssertTrue(MIME.attachments(of: parsed.part).isEmpty)
    }

    // MARK: - Part count

    /// A flat multipart with `count` trivial parts.
    private func flat(count: Int) -> Data {
        var text = "Content-Type: multipart/mixed; boundary=\"B\"\r\n\r\n"
        for i in 0..<count {
            text += "--B\r\nContent-Type: application/octet-stream\r\n"
            text += "Content-Disposition: attachment; filename=\"f\(i).bin\"\r\n\r\nx\r\n"
        }
        return Data((text + "--B--\r\n").utf8)
    }

    func testAMessageWithMorePartsThanTheCapStopsAndReportsIt() throws {
        let parsed = MIME.parseReporting(flat(count: MIME.maxParts + 50))
        XCTAssertTrue(parsed.report.partLimited)
        XCTAssertFalse(parsed.report.complete)
        XCTAssertEqual(parsed.report.parts, MIME.maxParts)
        XCTAssertEqual(MIME.attachments(of: parsed.part).count, MIME.maxParts - 1, "the root is not an attachment")
        let note = try XCTUnwrap(parsed.report.dict["note"] as? String)
        XCTAssertTrue(note.contains("\(MIME.maxParts)"), note)
    }

    func testABodyOfNothingButDelimitersDoesNotRunAway() {
        // 200,000 delimiters with a single byte between them — the cheapest a
        // part can be, eight bytes each. Without a ceiling the delimiter list
        // alone is built in full before a single part is, and every one of them
        // becomes a `Part` that `attachments(of:)` would hand to a caller.
        var text = "Content-Type: multipart/mixed; boundary=\"B\"\r\n\r\n"
        text += String(repeating: "--B\r\nx\r\n", count: 200_000)
        let parsed = MIME.parseReporting(Data(text.utf8))
        XCTAssertTrue(parsed.report.partLimited)
        XCTAssertLessThanOrEqual(parsed.report.parts, MIME.maxParts)
    }

    // MARK: - Header block

    func testAMessageThatIsAllHeadersIsCutAtTheCapAndSaysSo() throws {
        // A message with no blank line in it is treated as all headers on
        // purpose — that is what a truncated fetch looks like — so a hostile
        // sender can make the "header block" the whole message.
        var text = "Content-Type: text/plain; charset=utf-8\r\n"
        text += String(repeating: "X-Filler: 0123456789012345678901234567890123456789\r\n", count: 8_000)
        let parsed = MIME.parseReporting(Data(text.utf8))
        XCTAssertGreaterThan(text.utf8.count, MIME.maxHeaderBytes)
        XCTAssertTrue(parsed.report.headerLimited)
        XCTAssertFalse(parsed.report.complete)
        // What was inside the cap is still read.
        XCTAssertEqual(parsed.part.contentType, "text/plain")
        let note = try XCTUnwrap(parsed.report.dict["note"] as? String)
        XCTAssertTrue(note.contains("\(MIME.maxHeaderBytes)"), note)
    }

    func testAnOrdinaryHeaderBlockIsNotCut() {
        let parsed = MIME.parseReporting(Data("Content-Type: text/plain\r\n\r\nbody\r\n".utf8))
        XCTAssertFalse(parsed.report.headerLimited)
        XCTAssertTrue(parsed.report.complete)
    }

    // MARK: - The iterative walk answers exactly as the recursive one did

    func testAttachmentsStillComeBackInDocumentOrder() {
        // `mail_save_attachment`'s `index` argument refers to this order, so a
        // rewrite that reversed it would silently save the wrong file.
        let source = Data("""
        Content-Type: multipart/mixed; boundary="A"\r
        \r
        --A\r
        Content-Type: application/octet-stream; name="one.bin"\r
        \r
        1\r
        --A\r
        Content-Type: multipart/mixed; boundary="B"\r
        \r
        --B\r
        Content-Type: application/octet-stream; name="two.bin"\r
        \r
        2\r
        --B\r
        Content-Type: application/octet-stream; name="three.bin"\r
        \r
        3\r
        --B--\r
        --A\r
        Content-Type: application/octet-stream; name="four.bin"\r
        \r
        4\r
        --A--\r
        """.utf8)
        XCTAssertEqual(
            MIME.attachments(of: MIME.parse(source)).map(\.name),
            ["one.bin", "two.bin", "three.bin", "four.bin"]
        )
    }
}
