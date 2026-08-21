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
