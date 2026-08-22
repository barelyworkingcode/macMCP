import XCTest
@testable import macmcp

/// Cover for `mail_get_email` checking what Mail told it against the message
/// itself (issue #33).
///
/// `content()` and `mailAttachments()` answer for what Mail has downloaded and
/// answer without complaint when that is nothing. With the fixture's IMAPS
/// proxy severed mid-fetch, a 400 KB message carrying one attachment came back
/// as `body: ""`, `has_attachments: false`, `attachments: []`, `isError` unset —
/// next to a `message_size` of 400595 in the same response. And after the
/// connection came back and the body appeared, `mailAttachments()` stayed empty
/// **permanently**, while `mail_save_attachment` extracted the attachment
/// byte-exactly from the same message.
///
/// Both numbers below are from that run.
final class MailMessageCheckTests: XCTestCase {
    /// A message declaring one real attachment and one inline image.
    private let source = Data("""
    Subject: probe
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="B"

    --B
    Content-Type: text/plain

    plain part
    --B
    Content-Type: application/octet-stream; name="raw.bin"
    Content-Disposition: attachment; filename="raw.bin"

    payload
    --B
    Content-Type: image/png
    Content-ID: <logo@example.org>
    Content-Disposition: inline; filename="logo.png"

    pngdata
    --B--
    """.utf8)

    /// Either the whole source, sized to match it, or the nothing at all that
    /// Mail returned for the severed message — which it still sized at 400595.
    private func fidelity(complete: Bool) -> MailService.SourceFidelity {
        complete
            ? MailService.sourceFidelity(source, expectedSize: source.count + source.filter { $0 == 0x0A }.count)
            : MailService.sourceFidelity(Data(), expectedSize: 400_595)
    }

    private func checked(
        body: String,
        listedByMail: [[String: Any]] = [],
        complete: Bool
    ) -> [String: Any] {
        MailService.messageChecked(
            ["id": "429", "subject": "probe", "body": body],
            listedByMail: listedByMail,
            source: complete ? source : Data(),
            fidelity: fidelity(complete: complete)
        )
    }

    // MARK: - What the MIME reader could and could not read

    /// A message nested deeper than the reader descends yields a *shorter*
    /// attachment list, and a short list is indistinguishable from a message
    /// with fewer attachments. `structure` is what separates the two, on the
    /// same footing as `fidelity` beside it (#R3-1).
    func testAMessageTooDeeplyNestedToReadInFullSaysSoInTheResult() throws {
        var text = ""
        for level in 1...MIME.maxDepth {
            text += "Content-Type: multipart/mixed; boundary=\"B\(level)\"\r\n\r\n--B\(level)\r\n"
        }
        text += "Content-Type: application/octet-stream\r\n"
        text += "Content-Disposition: attachment; filename=\"deep.bin\"\r\n\r\ndeep\r\n"
        for level in stride(from: MIME.maxDepth, through: 1, by: -1) { text += "--B\(level)--\r\n" }
        let deep = Data(text.utf8)

        let payload = MailService.messageChecked(
            ["id": "429", "subject": "probe", "body": "b"],
            listedByMail: [],
            source: deep,
            fidelity: MailService.sourceFidelity(deep, expectedSize: deep.count)
        )
        let structure = try XCTUnwrap(payload["structure"] as? [String: Any], "nothing said the parse stopped short")
        XCTAssertEqual(structure["parsed_complete"] as? Bool, false)
        XCTAssertEqual(structure["max_depth"] as? Int, MIME.maxDepth)
        XCTAssertTrue(try XCTUnwrap(structure["note"] as? String).contains("not in this result"))
        // And the list really is short, which is the point.
        XCTAssertEqual(payload["has_attachments"] as? Bool, false)
    }

    func testAnOrdinaryMessageReportsItsStructureToo() throws {
        // Reported whether or not anything went wrong: a field that appears only
        // on failure is one a caller never learns to read.
        let payload = checked(body: "plain part", complete: true)
        let structure = try XCTUnwrap(payload["structure"] as? [String: Any])
        XCTAssertEqual(structure["parsed_complete"] as? Bool, true)
        XCTAssertEqual(structure["parts"] as? Int, 4, "the root and its three parts")
        XCTAssertEqual(structure["depth"] as? Int, 2)
        XCTAssertNil(structure["note"])
    }

    // MARK: - A negative from an incomplete fetch is not reported

    func testAnEmptyBodyAndEmptyAttachmentListAreOmittedRatherThanReported() throws {
        let payload = checked(body: "", complete: false)

        XCTAssertNil(payload["body"], "\"\" is an answer a caller acts on")
        XCTAssertNil(payload["attachments"])
        XCTAssertNil(payload["has_attachments"], "the field that stayed wrong for good")
        XCTAssertEqual(
            Set(payload["omitted"] as? [String] ?? []),
            ["body", "attachments", "has_attachments"]
        )
        XCTAssertTrue(try XCTUnwrap(payload["omitted_reason"] as? String).contains("finished downloading"))

        // What is still true about the message stays.
        XCTAssertEqual(payload["subject"] as? String, "probe")
        let fidelity = try XCTUnwrap(payload["fidelity"] as? [String: Any])
        XCTAssertEqual(fidelity["complete"] as? Bool, false)
        XCTAssertEqual(fidelity["message_size"] as? Int, 400_595)
    }

    func testWhatMailDoesHaveIsKeptEvenThoughTheMessageIsNotAllThere() throws {
        // Positive evidence is evidence: a body Mail has read, or an attachment
        // it has already listed, is not made less true by the rest being
        // missing. Only the negatives are withheld.
        let payload = checked(
            body: "the part that arrived",
            listedByMail: [["name": "raw.bin", "size": 7]],
            complete: false
        )
        XCTAssertEqual(payload["body"] as? String, "the part that arrived")
        XCTAssertEqual(payload["has_attachments"] as? Bool, true)
        XCTAssertNil(payload["omitted"])
        // The type cannot be read out of a source that has not arrived, so it
        // stays a guess and says so.
        let attachments = try XCTUnwrap(payload["attachments"] as? [[String: Any]])
        XCTAssertEqual(attachments.first?["mime_type_source"] as? String, "filename")
    }

    func testABodyThatArrivedIsKeptWhileTheMissingAttachmentListIsNot() throws {
        let payload = checked(body: "text", complete: false)
        XCTAssertEqual(payload["body"] as? String, "text")
        XCTAssertNil(payload["has_attachments"])
        XCTAssertEqual(Set(payload["omitted"] as? [String] ?? []), ["attachments", "has_attachments"])
    }

    // MARK: - The list is reconciled with the message (the permanent half)

    func testAnAttachmentMailWillNotListIsTakenFromTheMessage() throws {
        // Mail's list for the severed message stayed empty after the download
        // finished, while mail_save_attachment read the attachment out of the
        // same source. The two tools now agree.
        let payload = checked(body: "plain part", complete: true)
        let attachments = try XCTUnwrap(payload["attachments"] as? [[String: Any]])
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments.first?["name"] as? String, "raw.bin")
        XCTAssertEqual(attachments.first?["mime_type"] as? String, "application/octet-stream")
        XCTAssertEqual(attachments.first?["mime_type_source"] as? String, "declared")
        XCTAssertEqual(attachments.first?["listed_by_mail"] as? Bool, false)
        XCTAssertEqual(payload["has_attachments"] as? Bool, true)
        XCTAssertTrue(try XCTUnwrap(payload["attachments_note"] as? String).contains("not in Mail's own list"))
    }

    func testAnAttachmentMailDidListIsNotReportedTwice() throws {
        let payload = checked(
            body: "plain part",
            listedByMail: [["name": "raw.bin", "size": 7, "id": "2"]],
            complete: true
        )
        let attachments = try XCTUnwrap(payload["attachments"] as? [[String: Any]])
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments.first?["id"] as? String, "2", "Mail's own entry, kept")
        XCTAssertEqual(attachments.first?["mime_type_source"] as? String, "declared")
        XCTAssertNil(payload["attachments_note"])
    }

    func testAnInlineImageDoesNotBecomeAnAttachment() {
        // Mail deliberately does not list a body image, and turning
        // has_attachments true for every HTML message with a logo in it would
        // be a new wrong answer in place of the old one. The source here has
        // one inline part and one real attachment; only the second is added.
        let payload = checked(body: "plain part", complete: true)
        let names = (payload["attachments"] as? [[String: Any]] ?? []).map { $0["name"] as? String }
        XCTAssertEqual(names, ["raw.bin"])
    }

    func testTwoPartsSharingAName() {
        let part = """
        --B
        Content-Type: text/csv; name="data.csv"
        Content-Disposition: attachment; filename="data.csv"

        a,b

        """
        let source = Data((["Subject: two", "MIME-Version: 1.0", "Content-Type: multipart/mixed; boundary=\"B\"", "", ""].joined(separator: "\n") + part + part + "--B--\n").utf8)
        XCTAssertEqual(MIME.attachments(of: MIME.parse(source)).count, 2, "the fixture itself")

        func listedFlags(_ rows: [[String: Any]]) -> [Bool] {
            let list = MailService.attachmentList(of: MIME.parse(source))
            return MailService
                .reconcileWithMail(list.attachments + list.inlineParts, listedByMail: rows)
                .entries
                .map(\.listedByMail)
        }

        // Two parts sharing a filename are two entries, always — never one part
        // reported twice, and never two collapsed into one. Mail listed one of
        // the pair, so exactly one entry says so; each row claims at most one
        // part.
        XCTAssertEqual(listedFlags([["name": "data.csv"]]), [true, false])

        // And when Mail listed both, both are accounted for and nothing is left
        // over.
        XCTAssertEqual(listedFlags([["name": "data.csv"], ["name": "DATA.CSV"]]), [true, true])

        let list = MailService.attachmentList(of: MIME.parse(source))
        XCTAssertEqual(
            MailService.reconcileWithMail(
                list.attachments,
                listedByMail: [["name": "data.csv"], ["name": "DATA.CSV"]]
            ).unlocated.count,
            0
        )
    }

    // MARK: - A message with nothing wrong with it

    func testACompleteMessageWithNoAttachmentsSaysSoPlainly() throws {
        let source = Data("Subject: plain\n\njust text\n".utf8)
        let payload = MailService.messageChecked(
            ["id": "412", "body": "just text"],
            listedByMail: [],
            source: source,
            fidelity: MailService.sourceFidelity(source, expectedSize: source.count + 3)
        )
        XCTAssertEqual(payload["has_attachments"] as? Bool, false, "a checked negative is worth reporting")
        XCTAssertEqual((payload["attachments"] as? [[String: Any]])?.count, 0)
        XCTAssertNil(payload["omitted"])
        XCTAssertNil(payload["attachments_note"])
        XCTAssertEqual((payload["fidelity"] as? [String: Any])?["complete"] as? Bool, true)
    }
}
