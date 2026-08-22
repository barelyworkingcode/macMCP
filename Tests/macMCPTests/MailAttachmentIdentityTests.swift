import XCTest
@testable import macmcp

/// Cover for #R4-4: reconciling Mail's attachment list with the message source
/// **by filename**, so that one part came back as two attachments whenever Mail
/// rendered the filename differently from the header — and the copy that came
/// from Mail's row lost the type the message declares for a type guessed from
/// the extension.
///
/// Measured live against the fixture, one part, `Content-Type: image/png;
/// name="da\"ta.csv"`:
///
/// ```
/// mail_get_email 132054 -> [ da"ta.csv   / text/csv  / mime_type_source "filename",
///                            da\"ta.csv  / image/png / mime_type_source "declared" ]
/// ```
///
/// `text/csv` for a part the message declares as `image/png` is verbatim the
/// example CLAUDE.md gives as the bug `mime_type_source` was added to fix.
/// Neither handle worked: `index: 1` was out of range and
/// `attachment_name: "da\"ta.csv"` matched nothing.
///
/// Four independent triggers, each confirmed on a real message, each of which
/// makes Mail's rendering of a filename differ from the header's. They are the
/// reason the identity is the **MIME part path** (`mail attachment.id`, which
/// Mail reports as `2`, `3`, `1.2` — the numbering IMAP `BODYSTRUCTURE` uses)
/// and not the name: a position is not a rendering of anything, so none of the
/// four can move it.
///
/// Hermetic: these are pure MIME/reconciliation seams, so there is no mailbox
/// and no Mail here. The Mail rows below are what Mail really returned for
/// these four messages, copied out of the live runs.
final class MailAttachmentIdentityTests: XCTestCase {
    /// A `multipart/mixed` with a text body and one attachment, headed however
    /// the caller says. `filename` nil means the part declares none at all,
    /// which is trigger 3.
    private func message(filename: String?, type: String = "image/png") -> Data {
        let contentType = filename.map { "Content-Type: \(type); name=\"\($0)\"" } ?? "Content-Type: \(type)"
        let disposition = filename.map { "Content-Disposition: attachment; filename=\"\($0)\"" }
            ?? "Content-Disposition: attachment"
        let lines = [
            "From: alice@relaytest.local",
            "To: bob@relaytest.local",
            "Subject: identity probe",
            "MIME-Version: 1.0",
            "Content-Type: multipart/mixed; boundary=\"BND\"",
            "",
            "--BND",
            "Content-Type: text/plain",
            "",
            "see attachment",
            "--BND",
            contentType,
            disposition,
            "Content-Transfer-Encoding: base64",
            "",
            "UjQtUFJPQkUtcGF5bG9hZAo=",
            "--BND--",
            ""
        ]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    /// What `mail_get_email` puts in front of a caller for that message and
    /// Mail's rows for it.
    private func reported(_ source: Data, listedByMail: [[String: Any]]) -> [[String: Any]] {
        let payload = MailService.messageChecked(
            ["id": "1", "body": "see attachment"],
            listedByMail: listedByMail,
            source: source,
            fidelity: MailService.sourceFidelity(source, expectedSize: source.count)
        )
        return payload["attachments"] as? [[String: Any]] ?? []
    }

    /// The list `mail_save_attachment` selects out of — the same helper it calls.
    private func selectable(_ source: Data) -> [MIME.Attachment] {
        MailService.attachmentList(of: MIME.parse(source)).attachments
    }

    /// One part must come back as one attachment, carrying the type the message
    /// declares, and every name reported must be one the save tool can match.
    private func assertOnePartOneAttachment(
        _ source: Data,
        listedByMail: [[String: Any]],
        expectedName: String,
        expectedType: String,
        expectedMailName: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let attachments = reported(source, listedByMail: listedByMail)
        XCTAssertEqual(
            attachments.count, 1,
            "one part in the message, \(attachments.count) attachment(s) reported: \(attachments.map { $0["name"] as? String ?? "?" })",
            file: file, line: line
        )
        guard let only = attachments.first else { return }
        XCTAssertEqual(only["name"] as? String, expectedName, file: file, line: line)
        XCTAssertEqual(
            only["mime_type"] as? String, expectedType,
            "the type must be the one the message declares, never one guessed off the extension",
            file: file, line: line
        )
        XCTAssertEqual(only["mime_type_source"] as? String, "declared", file: file, line: line)
        XCTAssertEqual(
            only["listed_by_mail"] as? Bool, true,
            "Mail's row is for this very part; failing to match it reports the part as one Mail does not know about",
            file: file, line: line
        )
        XCTAssertEqual(only["mail_name"] as? String, expectedMailName, file: file, line: line)

        // And the handle works: the name reported is a name the save tool has.
        let usable = Set(selectable(source).map { $0.name.lowercased() })
        XCTAssertTrue(
            usable.contains((only["name"] as? String ?? "").lowercased()),
            "mail_get_email reported \"\(only["name"] as? String ?? "")\", which mail_save_attachment has no name for — it has: \(selectable(source).map(\.name))",
            file: file, line: line
        )
    }

    // MARK: - Trigger 1: an escaped quote in a quoted-string filename

    func testAPartWhoseFilenameContainsAnEscapedQuoteIsOneAttachment() {
        // Live: message 132054 in Bob's R4-PROBE-Hostile.
        assertOnePartOneAttachment(
            message(filename: "da\\\"ta.csv"),
            listedByMail: [["name": "da\"ta.csv", "size": 19, "downloaded": true, "id": "2"]],
            expectedName: "da\"ta.csv",
            expectedType: "image/png",
            expectedMailName: nil
        )
    }

    func testTheHeaderReaderUndoesAQuotedPairRatherThanKeepingTheBackslash() {
        // The half of trigger 1 that lives in MIME.swift: stripping the
        // surrounding quotes without undoing `\"` left a name no reader agrees
        // with, and the two-entry result followed from that.
        let source = message(filename: "da\\\"ta.csv")
        XCTAssertEqual(selectable(source).map(\.name), ["da\"ta.csv"])
    }

    func testUnquotingIsOnlyForQuotedStrings() {
        // A bare token keeps every character it has; there is no quoted-pair to
        // undo, and a backslash in one is data.
        XCTAssertEqual(MIME.unquote("plain.txt"), "plain.txt")
        XCTAssertEqual(MIME.unquote("a\\b"), "a\\b")
        XCTAssertEqual(MIME.unquote("\"a\\\\b\""), "a\\b", "an escaped backslash is one backslash")
        // Unterminated: the last backslash escaped nothing, and swallowing it
        // would lose a character of the sender's filename.
        XCTAssertEqual(MIME.unquote("\"trailing\\\""), "trailing\\")
    }

    // MARK: - Trigger 2: a raw non-ASCII filename

    func testAPartWithANonASCIIFilenameIsOneAttachment() {
        // Live: message 132114. Mail hands back its own Latin-1 mojibake for
        // this name — verified through plain JXA, so macMCP is relaying Mail
        // faithfully and no decoding on this side will ever make the two
        // strings equal. Matching on them therefore cannot work, and matching
        // on the part position is unaffected.
        assertOnePartOneAttachment(
            message(filename: "naïve—ünïcode.txt", type: "application/octet-stream"),
            listedByMail: [["name": "naÃ¯veâ\u{80}\u{94}Ã¼nÃ¯code.txt", "size": 19, "downloaded": true, "id": "2"]],
            expectedName: "naïve—ünïcode.txt",
            expectedType: "application/octet-stream",
            expectedMailName: "naÃ¯veâ\u{80}\u{94}Ã¼nÃ¯code.txt"
        )
    }

    // MARK: - Trigger 3: no filename parameter at all

    func testAPartWithNoFilenameAtAllIsOneAttachment() {
        // Live: message 132113. Mail invents "Mail Attachment"; the source has
        // nothing to invent from, so macMCP numbers it. Two names for one part,
        // neither derivable from the other.
        assertOnePartOneAttachment(
            message(filename: nil, type: "application/octet-stream"),
            listedByMail: [["name": "Mail Attachment", "size": 19, "downloaded": true, "id": "2"]],
            expectedName: "attachment-1",
            expectedType: "application/octet-stream",
            expectedMailName: "Mail Attachment"
        )
    }

    // MARK: - Trigger 4: a "/" in the filename

    func testAPartWhoseFilenameContainsASlashIsOneAttachment() {
        // Live: message 132055. Mail sanitises the separators, the source keeps
        // them. `safeFilename` still strips them on the way to disk — this is
        // about the two lists agreeing, not about where the bytes land.
        assertOnePartOneAttachment(
            message(filename: "../../../../tmp/R4-PROBE-ESCAPE.txt", type: "application/octet-stream"),
            listedByMail: [["name": ".._.._.._.._tmp_R4-PROBE-ESCAPE.txt", "size": 19, "downloaded": true, "id": "2"]],
            expectedName: "../../../../tmp/R4-PROBE-ESCAPE.txt",
            expectedType: "application/octet-stream",
            expectedMailName: ".._.._.._.._tmp_R4-PROBE-ESCAPE.txt"
        )
    }

    // MARK: - The identity itself

    func testPartPathsAreTheNumberingMailReportsAsAnAttachmentId() {
        // Measured on Mail 16: three attachments of a flat multipart/mixed come
        // back as ids "2", "3", "4"; an inline image inside a multipart/related
        // that is part 1 of a multipart/mixed comes back as "1.2". This is that
        // numbering, which is what makes Mail's rows matchable at all.
        let source = Data([
            "Subject: paths",
            "MIME-Version: 1.0",
            "Content-Type: multipart/mixed; boundary=\"M\"",
            "",
            "--M",
            "Content-Type: multipart/related; boundary=\"R\"",
            "",
            "--R",
            "Content-Type: text/html",
            "",
            "<html><body>hi</body></html>",
            "--R",
            "Content-Type: image/png",
            "Content-Id: <logo@example.org>",
            "",
            "pngdata",
            "--R--",
            "--M",
            "Content-Type: application/pdf; name=\"doc.pdf\"",
            "Content-Disposition: attachment; filename=\"doc.pdf\"",
            "",
            "pdfdata",
            "--M--",
            ""
        ].joined(separator: "\r\n").utf8)

        let list = MailService.attachmentList(of: MIME.parse(source))
        XCTAssertEqual(list.attachments.map(\.path), ["2"])
        XCTAssertEqual(list.attachments.map(\.name), ["doc.pdf"])
        XCTAssertEqual(list.inlineParts.map(\.path), ["1.2"], "the CID image, inside the related part that is part 1")
    }

    func testASinglePartMessageIsPartOne() {
        // IMAP numbers a message that is not multipart as part 1, and so does
        // Mail; the reader has to agree or the one row it gets never matches.
        let source = Data([
            "Subject: lone",
            "MIME-Version: 1.0",
            "Content-Type: application/pdf; name=\"lone.pdf\"",
            "Content-Disposition: attachment; filename=\"lone.pdf\"",
            "",
            "pdfdata",
            ""
        ].joined(separator: "\r\n").utf8)
        XCTAssertEqual(MailService.attachmentList(of: MIME.parse(source)).attachments.map(\.path), ["1"])
    }

    func testAMailRowThatMatchesNoPartIsNotGivenAPartsIdentity() {
        // The guard on the identity: a row that matches nothing must not be
        // allowed to claim a part by falling through to a looser rule. Two
        // parts share a size here, so the size pass has no unambiguous answer
        // and declines rather than guessing.
        let source = Data([
            "Content-Type: multipart/mixed; boundary=\"B\"",
            "",
            "--B",
            "Content-Type: application/octet-stream; name=\"a.bin\"",
            "Content-Disposition: attachment; filename=\"a.bin\"",
            "",
            "sevenxx",
            "--B",
            "Content-Type: application/octet-stream; name=\"b.bin\"",
            "Content-Disposition: attachment; filename=\"b.bin\"",
            "",
            "sevenyy",
            "--B--",
            ""
        ].joined(separator: "\r\n").utf8)

        let list = MailService.attachmentList(of: MIME.parse(source))
        let outcome = MailService.reconcileWithMail(
            list.attachments,
            listedByMail: [["name": "somethingelse.bin", "size": 7]]
        )
        XCTAssertEqual(outcome.entries.map(\.listedByMail), [false, false])
        XCTAssertEqual(outcome.unlocated.count, 1)
    }
}
