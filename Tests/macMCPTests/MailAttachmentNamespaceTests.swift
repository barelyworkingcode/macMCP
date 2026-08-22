import XCTest
@testable import macmcp

/// Cover for `mail_save_attachment` selecting out of a different list than the
/// one `mail_get_email` reports.
///
/// `mail_get_email` reports Mail's own `mailAttachments()` list, reconciled
/// against the message source: types taken from the declaration, and anything
/// the source declares that Mail did not list added with `listed_by_mail:
/// false` — with inline parts deliberately excluded, so a body image does not
/// turn `has_attachments` true for every HTML message with a logo in it.
///
/// `mail_save_attachment` does none of that. It selects straight out of
/// `MIME.attachments(of: MIME.parse(source))`, in document order, *including*
/// inline parts, and synthesises `attachment-<n>.<ext>` for the ones with no
/// filename. So the two tools disagree about membership, about order, and about
/// names — while `attachment_name` is documented as "as reported by
/// mail_get_email".
///
/// Measured against a probe carrying an HTML body, a CID-only inline PNG and a
/// `report.txt` attachment:
///
/// ```
/// mail_get_email          -> [{report.txt, 0}, {Mail Attachment.png, 1}]
/// save_attachment index 0 -> wrote attachment-1.png (the inline image), isError: false
/// save_attachment name    -> "no attachment matching \"Mail Attachment.png\" —
///                             message has: attachment-1.png, report.txt"
/// ```
///
/// The name the caller was given cannot be used, the names that work were never
/// shown, and `index: 0` writes the body image to disk while reporting success.
/// With neither argument, every inline body image in the message is written out
/// too.
///
/// This is a pure seam: the message is built here, so there is no mailbox and no
/// Mail.
///
/// **Note for whoever fixes this.** The left-hand side of these assertions is
/// `MIME.attachments(of:)` because that is the list `saveAttachment` selects
/// from *today*. `saveAttachment` is private, so the selection cannot be called
/// directly. If the fix introduces a shared helper — which is the right shape,
/// one list built once and used by both tools — repoint `selectable` at it
/// rather than relaxing what is asserted.
final class MailAttachmentNamespaceTests: XCTestCase {
    /// A message with three leaf parts: an HTML body, an inline PNG referenced
    /// only by `Content-Id` (no filename, no `Content-Disposition`, which is
    /// how a pasted image arrives), and a real attachment.
    private static let source: Data = {
        let lines = [
            "From: Alice Tester <alice@relaytest.local>",
            "To: bob@relaytest.local",
            "Subject: attachment namespaces",
            "Message-Id: <r2-probe-cidonly@relaytest.local>",
            "MIME-Version: 1.0",
            "Content-Type: multipart/mixed; boundary=\"OUTER\"",
            "",
            "--OUTER",
            "Content-Type: multipart/related; boundary=\"INNER\"",
            "",
            "--INNER",
            "Content-Type: text/html; charset=utf-8",
            "Content-Transfer-Encoding: 7bit",
            "",
            "<html><body><p>hello</p><img src=\"cid:logo@relaytest.local\"></body></html>",
            "--INNER",
            "Content-Type: image/png",
            "Content-Transfer-Encoding: base64",
            "Content-Id: <logo@relaytest.local>",
            "",
            "iVBORw0KGgoAAAANSUhEUg==",
            "--INNER--",
            "--OUTER",
            "Content-Type: text/plain; charset=utf-8; name=\"report.txt\"",
            "Content-Disposition: attachment; filename=\"report.txt\"",
            "Content-Transfer-Encoding: 7bit",
            "",
            "col a,col b",
            "1,2",
            "--OUTER--",
            ""
        ]
        return Data(lines.joined(separator: "\r\n").utf8)
    }()

    /// What Mail's own `mailAttachments()` reported for the probe: the real
    /// attachment, and the inline image under the name Mail invents for a part
    /// with no filename.
    private static let listedByMail: [[String: Any]] = [
        ["name": "report.txt", "size": 13, "downloaded": true],
        ["name": "Mail Attachment.png", "size": 24, "downloaded": true]
    ]

    /// The list `mail_get_email` puts in front of a caller.
    private func reported() -> [[String: Any]] {
        let payload = MailService.messageChecked(
            ["body": "hello", "message_size": Self.source.count],
            listedByMail: Self.listedByMail,
            source: Self.source,
            fidelity: MailService.sourceFidelity(Self.source)
        )
        return payload["attachments"] as? [[String: Any]] ?? []
    }

    /// The list `mail_save_attachment` selects out of.
    private func selectable() -> [MIME.Attachment] {
        MIME.attachments(of: MIME.parse(Self.source))
    }

    private func names(_ attachments: [[String: Any]]) -> [String] {
        attachments.map { $0["name"] as? String ?? "" }
    }

    // MARK: - The defect

    func testTheAttachmentsAMessageReportsAreTheAttachmentsThatCanBeSelected() throws {
        // Same membership, same order, same names — because `index` is an index
        // into the reported list and `attachment_name` is one of its names.
        XCTAssertEqual(names(reported()), selectable().map(\.name))
    }

    func testEveryNameAMessageReportsCanBeUsedAsAnAttachmentName() throws {
        // The half a caller hits first: `attachment_name` copied out of
        // `mail_get_email` is rejected outright.
        let usable = Set(selectable().map { $0.name.lowercased() })
        for name in names(reported()) {
            XCTAssertTrue(
                usable.contains(name.lowercased()),
                "mail_get_email reported \"\(name)\", which mail_save_attachment cannot match — it has: \(selectable().map(\.name).joined(separator: ", "))"
            )
        }
    }

    func testAnIndexSelectsTheAttachmentThatWasReportedAtThatIndex() throws {
        // `index: 0` on this message writes the inline body image and reports
        // success, while the caller was shown `report.txt` at index 0.
        let reportedNames = names(reported())
        let selectableNames = selectable().map(\.name)
        for index in reportedNames.indices where index < selectableNames.count {
            XCTAssertEqual(
                selectableNames[index], reportedNames[index],
                "index \(index) selects a different attachment than the one reported at that index"
            )
        }
    }

    func testAMessagesInlineBodyImageIsNotOfferedAsOneOfItsAttachments() throws {
        // With neither `index` nor `attachment_name`, every entry in the
        // selection list is written to disk. A CID-only body image is not
        // something a caller asked to save, and `mail_get_email` already agrees
        // it is not an attachment.
        let inline = selectable().filter(\.inline).map(\.name)
        XCTAssertEqual(inline, [], "these would all be written to disk by an unqualified mail_save_attachment")
    }

    // MARK: - Controls, which pass today

    func testTheRealAttachmentIsPresentInBothLists() throws {
        XCTAssertTrue(names(reported()).contains("report.txt"))
        XCTAssertTrue(selectable().contains { $0.name == "report.txt" })
    }

    func testTheHTMLBodyIsNotAnAttachmentInEitherList() throws {
        XCTAssertFalse(selectable().contains { $0.mimeType == "text/html" })
        XCTAssertFalse(reported().contains { ($0["mime_type"] as? String) == "text/html" })
    }
}
