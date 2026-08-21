import XCTest
@testable import macmcp

/// Regression cover for `mail_get_email` guessing an attachment's `mime_type`
/// from its filename (issue #9), and so disagreeing with what the message
/// declares and with what `mail_save_attachment` reports for the same part.
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

    // MARK: - The reported defect

    func testDeclaredTypeWinsOverTheFilenameExtension() {
        // text/csv vs image/png for one attachment, from the issue.
        let typed = MailService.declaredAttachmentTypes(
            [["name": "data.csv", "size": 6]],
            source: conflicting
        )
        XCTAssertEqual(typed[0]["mime_type"] as? String, "image/png")
        XCTAssertEqual(typed[0]["mime_type_source"] as? String, "declared")
    }

    func testOctetStreamIsNotUpgradedToAFilenameGuess() {
        // The issue's second case: application/macbinary was invented from ".bin".
        let typed = MailService.declaredAttachmentTypes(
            [["name": "raw.bin", "size": 6]],
            source: conflicting
        )
        XCTAssertEqual(typed[0]["mime_type"] as? String, "application/octet-stream")
        XCTAssertEqual(typed[0]["mime_type_source"] as? String, "declared")
    }

    func testTheTwoToolsNowAgree() {
        // mail_save_attachment reads the type out of the parsed MIME part; this
        // asserts mail_get_email lands on the same value for the same part.
        let saved = MIME.attachments(of: MIME.parse(conflicting))
        let typed = MailService.declaredAttachmentTypes(
            saved.map { ["name": $0.name] },
            source: conflicting
        )
        XCTAssertEqual(
            typed.map { $0["mime_type"] as? String },
            saved.map(\.mimeType)
        )
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
        let typed = MailService.declaredAttachmentTypes(
            [["name": "page.dat"], ["name": "page.dat"]],
            source: duplicates
        )
        XCTAssertEqual(typed[0]["mime_type"] as? String, "image/png")
        XCTAssertEqual(typed[1]["mime_type"] as? String, "application/pdf")
    }

    func testNameMatchingIsCaseInsensitive() {
        let typed = MailService.declaredAttachmentTypes(
            [["name": "DATA.CSV"]],
            source: conflicting
        )
        XCTAssertEqual(typed[0]["mime_type"] as? String, "image/png")
    }

    // MARK: - Falling back

    func testAnAttachmentWithNoCounterpartKeepsTheGuessAndSaysSo() {
        // Better a guess that admits it than the type of an unrelated part.
        let typed = MailService.declaredAttachmentTypes(
            [["name": "elsewhere.csv"]],
            source: conflicting
        )
        XCTAssertEqual(typed[0]["mime_type"] as? String, "text/csv")
        XCTAssertEqual(typed[0]["mime_type_source"] as? String, "filename")
    }

    func testAnUnreadableSourceLeavesTheGuessInPlace() {
        let typed = MailService.declaredAttachmentTypes(
            [["name": "data.csv"]],
            source: Data("not a message".utf8)
        )
        XCTAssertEqual(typed[0]["mime_type"] as? String, "text/csv")
        XCTAssertEqual(typed[0]["mime_type_source"] as? String, "filename")
    }

    func testOtherFieldsSurvive() {
        let typed = MailService.declaredAttachmentTypes(
            [["name": "data.csv", "size": 14, "downloaded": true, "id": "3"]],
            source: conflicting
        )
        XCTAssertEqual(typed[0]["size"] as? Int, 14)
        XCTAssertEqual(typed[0]["downloaded"] as? Bool, true)
        XCTAssertEqual(typed[0]["id"] as? String, "3")
    }
}
