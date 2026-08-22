import Foundation
import XCTest
@testable import macmcp

/// A message id that arrives as a number is still a message id.
///
/// The schema says `string` and the handlers read `.stringValue`, so a client
/// that emitted `"message_id": 63926` unquoted was told `message_id is
/// required` — a message about a missing argument, for an argument that was
/// there. Several clients do it (LM Studio among them), because the value looks
/// like a number and models write it like one.
final class ArgumentCoercionTests: XCTestCase {
    func testANumericIdIsReadAsTheStringItStandsFor() {
        XCTAssertEqual(JSONValue.int(63926).coercedStringValue, "63926")
        XCTAssertEqual(JSONValue.string("63926").coercedStringValue, "63926")
    }

    func testAWholeNumberSentAsADoubleDoesNotGrowADecimalPoint() {
        // JSON has one number type, so a client may hand over 63926.0. Read
        // naively that becomes "63926.0", which matches no message at all.
        XCTAssertEqual(JSONValue.double(63926).coercedStringValue, "63926")
    }

    func testADoubleEncodedStringIsUnwrapped() {
        // The client quoted a value that was already quoted, so the decoded
        // string carries the quote characters. No id here can begin and end
        // with one: an RFC Message-ID is delimited by angle brackets.
        XCTAssertEqual(JSONValue.string("\"63926\"").coercedStringValue, "63926")
        XCTAssertEqual(JSONValue.string("\"\"63926\"\"").coercedStringValue, "63926")
    }

    func testAnRFCMessageIDIsUntouched() {
        let rfc = "<CAF=abc123@mail.example.org>"
        XCTAssertEqual(JSONValue.string(rfc).coercedStringValue, rfc)
    }

    func testAValueThatIsNotAnIdentifierAtAllIsStillRefused() {
        XCTAssertNil(JSONValue.bool(true).coercedStringValue)
        XCTAssertNil(JSONValue.null.coercedStringValue)
        XCTAssertNil(JSONValue.array([.string("63926")]).coercedStringValue)
        XCTAssertNil(JSONValue.double(.infinity).coercedStringValue)
    }

    func testAnEmptyStringSurvivesRatherThanBecomingNil() {
        // The handlers decide what to do about an empty id; this accessor is
        // not the place to turn one into "the argument was absent".
        XCTAssertEqual(JSONValue.string("").coercedStringValue, "")
    }

    func testEveryMailToolThatTakesAMessageIdDeclaresBothRenderings() throws {
        // The coercion is only reachable if the schema lets the value through:
        // a client validating against `"type": "string"` refuses to send the
        // number before the call is made.
        let registry = ToolRegistry()
        MailService.register(registry)

        var checked = 0
        for tool in registry.allTools() {
            guard case .object(let root) = tool.inputSchema,
                  case .object(let properties)? = root["properties"],
                  case .object(let messageID)? = properties["message_id"] else { continue }
            checked += 1
            XCTAssertEqual(
                messageID["type"],
                .array([.string("string"), .string("integer")]),
                "\(tool.name) still declares message_id as one type"
            )
        }
        XCTAssertGreaterThanOrEqual(checked, 5, "no mail tool declared a message_id at all")
    }
}
