import XCTest
@testable import macmcp

/// Regression cover for `mail_mark_read` and `mail_move` returning "message not
/// found" as a raw JSON blob while every sibling returned prose (issue #10).
///
/// Both handlers detected the condition with `output.contains("\"error\"")` and
/// then passed the whole JSON string through. That is two problems: the shape
/// the caller sees, and a content check standing in for a structural one.
final class MailScriptPayloadTests: XCTestCase {
    // MARK: - The reported inconsistency

    func testAnErrorObjectBecomesTheSentenceOnItsOwn() {
        let payload = MailService.scriptPayload(#"{"error":"message not found with id: 99999999"}"#)
        XCTAssertEqual(payload, .failure("message not found with id: 99999999"))
    }

    func testASuccessObjectIsNotMistakenForAFailure() {
        guard case .object(let object) = MailService.scriptPayload(
            #"{"status":"moved","account":"Bob","mailbox":"Archive"}"#
        ) else {
            return XCTFail("expected an object")
        }
        XCTAssertEqual(object["status"] as? String, "moved")
        XCTAssertEqual(object["account"] as? String, "Bob")
    }

    // MARK: - The fragility underneath it

    func testAMailboxNamedErrorIsNotAFailedMove() {
        // `output.contains("\"error\"")` was a content check standing in for a
        // structural one. Moving a message into a mailbox called "error" puts
        // those exact characters in a successful result, and it was reported as
        // a failure -- with the whole payload as the message.
        guard case .object(let object) = MailService.scriptPayload(
            #"{"status":"moved","account":"Bob","mailbox":"error"}"#
        ) else {
            return XCTFail("a mailbox named \"error\" is not an error")
        }
        XCTAssertEqual(object["mailbox"] as? String, "error")
    }

    func testANonStringErrorFieldIsNotPresentedAsAMessage() {
        // Nothing readable to show the caller, so it stays an object rather
        // than becoming the string "42".
        guard case .object = MailService.scriptPayload(#"{"error":42}"#) else {
            return XCTFail("expected an object")
        }
    }

    // MARK: - Scripts that do not return JSON

    func testABareStringResultIsPassedThroughAsText() {
        // mail_mark_read's success value is the bare string 'done'.
        XCTAssertEqual(MailService.scriptPayload("done"), .text("done"))
    }

    func testEmptyOutputIsText() {
        XCTAssertEqual(MailService.scriptPayload(""), .text(""))
    }

    func testAJSONArrayIsNotAnObject() {
        XCTAssertEqual(MailService.scriptPayload("[1,2,3]"), .text("[1,2,3]"))
    }
}
