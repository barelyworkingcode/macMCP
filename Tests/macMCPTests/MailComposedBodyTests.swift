import XCTest
@testable import macmcp

/// Cover for the compose body being reported as a clean success while Mail had
/// rewritten it (issue #8).
///
/// The body itself cannot be fixed from here — Mail applies the transformation
/// to anything set through its scripting interface, and textbook AppleScript
/// reproduces it exactly. What was fixable is the reporting: `rendered_chars`
/// is read off `msg.content()` before Mail generates the alternatives, so it
/// reports a plausible number for a message whose plain-text part is quoted or
/// empty, and nothing else contradicted it.
///
/// The samples below are the real Mail output captured from the testMail
/// fixture, not invented.
final class MailComposedBodyTests: XCTestCase {
    private func message(_ lines: String) -> Data {
        Data(lines.replacingOccurrences(of: "\n", with: "\r\n").utf8)
    }

    /// A draft saved by mail_create_draft: the text/plain part is empty and the
    /// body survives only as HTML.
    private let emptyPlainDraft = """
    Subject: BODYTEST-draft
    Content-Type: multipart/alternative;
    \tboundary="Apple-Mail=_BF8A9640"

    --Apple-Mail=_BF8A9640
    Content-Transfer-Encoding: 7bit
    Content-Type: text/plain;
    \tcharset=us-ascii


    --Apple-Mail=_BF8A9640
    Content-Transfer-Encoding: 7bit
    Content-Type: text/html;
    \tcharset=us-ascii

    <html><body><div class="Apple-Mail-URLShareWrapperClass"><blockquote type="cite">just one line here</blockquote></div></body></html>
    --Apple-Mail=_BF8A9640--
    """

    /// A message delivered by mail_send: every line of the plain part carries
    /// Mail's citation prefix.
    private let quotedPlainSend = """
    Subject: BODYTEST-multiline
    Content-Type: multipart/alternative;
    \tboundary="Apple-Mail=_26847804"

    --Apple-Mail=_26847804
    Content-Transfer-Encoding: 7bit
    Content-Type: text/plain;
    \tcharset=us-ascii


    > alpha line
    > bravo line
    > charlie line

    --Apple-Mail=_26847804
    Content-Transfer-Encoding: 7bit
    Content-Type: text/html;
    \tcharset=us-ascii

    <html><body><blockquote type="cite">alpha line<br>bravo line<br>charlie line</blockquote></body></html>
    --Apple-Mail=_26847804--
    """

    // MARK: - The two reported symptoms

    func testEmptyPlainPartInADraftIsReportedAsAMismatch() {
        let check = MailService.checkComposedBody(
            source: message(emptyPlainDraft),
            requestedBody: "just one line here"
        )
        XCTAssertFalse(check.matches)
        XCTAssertEqual(check.detail?.contains("empty text/plain"), true, check.detail ?? "nil")
        XCTAssertEqual(check.detail?.contains("blank"), true, check.detail ?? "nil")
    }

    func testQuotedPlainPartIsRecognisedAsQuotingRatherThanAsUnrelatedText() {
        let check = MailService.checkComposedBody(
            source: message(quotedPlainSend),
            requestedBody: "alpha line\nbravo line\ncharlie line"
        )
        XCTAssertFalse(check.matches)
        XCTAssertEqual(check.detail?.contains("\"> \""), true, check.detail ?? "nil")
    }

    // MARK: - What a correct message looks like

    func testAMessageWhosePlainPartIsTheBodyPasses() {
        // The shape a hand-composed Mail message has: one text/plain part
        // holding exactly what was typed. Verified against the fixture.
        let clean = message("""
        Subject: BODYTEST-typed
        Content-Type: text/plain;
        \tcharset=us-ascii
        Content-Transfer-Encoding: 7bit

        alpha line
        bravo line
        charlie line
        """)
        let check = MailService.checkComposedBody(
            source: clean,
            requestedBody: "alpha line\nbravo line\ncharlie line"
        )
        XCTAssertTrue(check.matches, check.detail ?? "nil")
        XCTAssertNil(check.detail)
    }

    func testTrailingWhitespaceAndLineEndingsDoNotCountAsAMismatch() {
        let clean = message("""
        Content-Type: text/plain; charset=utf-8

        alpha line
        bravo line
        """)
        XCTAssertTrue(
            MailService.checkComposedBody(source: clean, requestedBody: "alpha line\r\nbravo line\r\n").matches
        )
    }

    // MARK: - Degenerate messages

    func testNoPlainPartAtAllIsReportedAsSuch() {
        let htmlOnly = message("""
        Content-Type: text/html; charset=utf-8

        <p>hello</p>
        """)
        let check = MailService.checkComposedBody(source: htmlOnly, requestedBody: "hello")
        XCTAssertFalse(check.matches)
        XCTAssertEqual(check.detail?.contains("no text/plain part"), true, check.detail ?? "nil")
    }

    func testAnAttachedTextFileIsNotMistakenForTheBody() {
        let withAttachment = message("""
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain; charset=utf-8

        the real body
        --B
        Content-Type: text/plain; charset=utf-8
        Content-Disposition: attachment; filename="notes.txt"

        not the body
        --B--
        """)
        XCTAssertTrue(
            MailService.checkComposedBody(source: withAttachment, requestedBody: "the real body").matches
        )
    }

    func testUnrelatedTextIsNotExcusedAsQuoting() {
        let wrong = message("""
        Content-Type: text/plain; charset=utf-8

        something else entirely
        """)
        let check = MailService.checkComposedBody(source: wrong, requestedBody: "alpha line")
        XCTAssertFalse(check.matches)
        XCTAssertEqual(check.detail?.contains("not the body that was supplied"), true, check.detail ?? "nil")
    }
}
