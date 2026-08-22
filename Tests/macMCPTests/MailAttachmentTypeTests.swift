import XCTest
@testable import macmcp

/// Regression cover for `mail_get_email` guessing an attachment's `mime_type`
/// from its filename (issue #9), and so disagreeing with what the message
/// declares and with what `mail_save_attachment` reports for the same part.
///
/// Rewritten for #R2-2/#R4-4. The seam these used to drive,
/// `declaredAttachmentTypes`, took Mail's own rows and tried to look each one's
/// type up in the source **by filename** — which is what emitted a single part
/// twice whenever Mail rendered the filename differently from the header, one
/// copy carrying a type guessed from the extension. There is now one list, built
/// from the message source by `MailService.attachmentList`, and Mail's rows only
/// annotate it (`reconcileWithMail`). Every assertion below is the same claim
/// about the same message, made against that list.
final class MailAttachmentTypeTests: XCTestCase {
    private func message(_ lines: String) -> Data {
        Data(lines.replacingOccurrences(of: "\n", with: "\r\n").utf8)
    }

    /// The fixture from the issue: the header says one thing, the extension
    /// says another.
    private lazy var conflicting = message("""
    Subject: mime fixture
    Content-Type: multipart/mixed; boundary="B"

    --B
    Content-Type: text/plain

    body
    --B
    Content-Type: image/png; name="data.csv"
    Content-Disposition: attachment; filename="data.csv"
    Content-Transfer-Encoding: base64

    aGVsbG8K
    --B
    Content-Type: application/octet-stream; name="raw.bin"
    Content-Disposition: attachment; filename="raw.bin"
    Content-Transfer-Encoding: base64

    aGVsbG8K
    --B--
    """)

    /// The one list, as `mail_get_email` puts it in front of a caller.
    private func reported(_ source: Data, listedByMail: [[String: Any]] = []) -> [[String: Any]] {
        let list = MailService.attachmentList(of: MIME.parse(source))
        return MailService
            .reconcileWithMail(list.attachments + list.inlineParts, listedByMail: listedByMail)
            .entries
            .filter { !$0.part.inline }
            .map(MailService.attachmentDict)
    }

    private func unlocated(_ source: Data, listedByMail: [[String: Any]]) -> [[String: Any]] {
        let list = MailService.attachmentList(of: MIME.parse(source))
        return MailService
            .reconcileWithMail(list.attachments + list.inlineParts, listedByMail: listedByMail)
            .unlocated
    }

    private func field(_ attachments: [[String: Any]], _ key: String) -> [String?] {
        attachments.map { $0[key] as? String }
    }

    // MARK: - The reported defect

    func testDeclaredTypeWinsOverTheFilenameExtension() {
        // text/csv vs image/png for one attachment, from the issue.
        let typed = reported(conflicting, listedByMail: [["name": "data.csv", "size": 6, "id": "2"]])
        XCTAssertEqual(typed[0]["name"] as? String, "data.csv")
        XCTAssertEqual(typed[0]["mime_type"] as? String, "image/png")
        XCTAssertEqual(typed[0]["mime_type_source"] as? String, "declared")
    }

    func testOctetStreamIsNotUpgradedToAFilenameGuess() {
        // The issue's second case: application/macbinary was invented from ".bin".
        let typed = reported(conflicting, listedByMail: [["name": "raw.bin", "size": 6, "id": "3"]])
        XCTAssertEqual(typed[1]["name"] as? String, "raw.bin")
        XCTAssertEqual(typed[1]["mime_type"] as? String, "application/octet-stream")
        XCTAssertEqual(typed[1]["mime_type_source"] as? String, "declared")
    }

    func testTheTwoToolsNowAgree() {
        // mail_save_attachment reads the type out of the parsed MIME part; this
        // asserts mail_get_email lands on the same value for the same part —
        // which it cannot fail to, both being the same list.
        let selectable = MailService.attachmentList(of: MIME.parse(conflicting)).attachments
        let typed = reported(conflicting, listedByMail: selectable.map { ["name": $0.name] })
        XCTAssertEqual(field(typed, "mime_type"), selectable.map { Optional($0.mimeType) })
        XCTAssertEqual(field(typed, "name"), selectable.map { Optional($0.name) })
        XCTAssertEqual(field(typed, "part_path"), selectable.map { Optional($0.path) })
    }

    // MARK: - Matching

    func testDuplicateFilenamesGetTheirOwnTypesInOrder() {
        let duplicates = message("""
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: image/png; name="page.dat"
        Content-Disposition: attachment; filename="page.dat"

        one
        --B
        Content-Type: application/pdf; name="page.dat"
        Content-Disposition: attachment; filename="page.dat"

        two
        --B--
        """)
        let typed = reported(duplicates, listedByMail: [["name": "page.dat"], ["name": "page.dat"]])
        XCTAssertEqual(typed[0]["mime_type"] as? String, "image/png")
        XCTAssertEqual(typed[1]["mime_type"] as? String, "application/pdf")
        // Two parts, two entries — never one part reported twice.
        XCTAssertEqual(typed.count, 2)
        XCTAssertEqual(field(typed, "part_path"), ["1", "2"])
    }

    func testNameMatchingIsCaseInsensitive() {
        // A Mail that reports no usable id falls back to the name, and Mail
        // case-folds some of them.
        let typed = reported(conflicting, listedByMail: [["name": "DATA.CSV"]])
        XCTAssertEqual(typed[0]["listed_by_mail"] as? Bool, true)
        XCTAssertEqual(typed[0]["mime_type"] as? String, "image/png")
        XCTAssertEqual(typed[0]["mail_name"] as? String, "DATA.CSV", "what Mail displays, beside what the message says")
    }

    // MARK: - Falling back

    func testARowWithNoCounterpartInTheMessageIsNotTurnedIntoAnAttachment() {
        // It used to be: Mail's row was kept, with a type guessed from its
        // extension, which is how the same part came back twice under two names.
        // A row nothing in the message accounts for has no bytes behind it, so
        // it cannot be saved and is reported apart rather than offered as an
        // attachment.
        let typed = reported(conflicting, listedByMail: [["name": "elsewhere.csv", "size": 999]])
        XCTAssertEqual(field(typed, "name"), ["data.csv", "raw.bin"])
        XCTAssertFalse(field(typed, "mime_type").contains("text/csv"), "no type was borrowed from an extension")
        XCTAssertTrue(typed.allSatisfy { $0["listed_by_mail"] as? Bool == false })

        let stray = unlocated(conflicting, listedByMail: [["name": "elsewhere.csv", "size": 999]])
        XCTAssertEqual(stray.count, 1)
        XCTAssertEqual(stray.first?["name"] as? String, "elsewhere.csv")
    }

    func testAnUnreadableSourceYieldsNoAttachmentsRatherThanGuessedOnes() {
        // Nothing can be selected out of bytes that are not a message, so
        // nothing is offered as selectable. The row Mail gave is kept where a
        // caller can see it, not passed off as a part of the message.
        let junk = Data("not a message".utf8)
        XCTAssertEqual(reported(junk, listedByMail: [["name": "data.csv"]]).count, 0)
        XCTAssertEqual(unlocated(junk, listedByMail: [["name": "data.csv"]]).count, 1)
    }

    func testMailsOwnFieldsSurviveOnAMatchedEntry() {
        let typed = reported(
            conflicting,
            listedByMail: [["name": "data.csv", "size": 6, "downloaded": true, "id": "2"]]
        )
        XCTAssertEqual(typed[0]["downloaded"] as? Bool, true)
        XCTAssertEqual(typed[0]["id"] as? String, "2")
        XCTAssertEqual(typed[0]["listed_by_mail"] as? Bool, true)
        // The size is measured off the part rather than taken on trust, and the
        // two agree: Mail quotes fileSize in decoded bytes.
        XCTAssertEqual(typed[0]["size"] as? Int, 6)
    }
}
