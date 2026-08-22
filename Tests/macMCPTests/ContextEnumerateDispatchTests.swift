import XCTest
@testable import macmcp

/// `context/enumerate` (ADR-011 decision 6) is a JSON-RPC method dispatched
/// directly from `main.swift`'s top-level `switch req.method`, not a tool --
/// so it has no `ToolRegistry` entry to call in-process. See
/// `StdioServerTestCase` for the harness and for why every case here is
/// decided before `MailService.enumerateContext` -- the one function that
/// would spawn `osascript` -- is ever called. A positive `mail_accounts` /
/// `mail_mailboxes` enumeration is not exercised here for exactly that
/// reason; it belongs with `MailSourceOnDiskTests`, against the real fixture.
final class ContextEnumerateDispatchTests: StdioServerTestCase {
    // MARK: - The method still returns -32601 for anything it does not implement

    func testAnUnknownMethodStillReturnsMinus32601() throws {
        let response = try send(method: "totally/unsupported", params: nil)
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32601)
        let message = try XCTUnwrap(error["message"] as? String)
        XCTAssertTrue(message.contains("totally/unsupported"), message)
        XCTAssertNil(response["result"])
    }

    // MARK: - context/enumerate error paths

    func testMissingFieldParameterIsInvalidParams() throws {
        let response = try send(method: "context/enumerate", params: [:])
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
    }

    /// A field `contextSchema` has never heard of.
    func testAnUnknownFieldIsRefusedAsInvalidParams() throws {
        let response = try send(method: "context/enumerate", params: ["field": "no_such_field"])
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        let message = try XCTUnwrap(error["message"] as? String)
        XCTAssertTrue(message.contains("no_such_field"), message)
        XCTAssertNil(response["result"])
    }

    /// `file_dirs` is declared in `contextSchema` but not `enumerable: true`
    /// -- it is `source: "project_path"`, which relay derives and an operator
    /// never picks from a list. This is the one the task names explicitly:
    /// "file_dirs must be refused this way."
    func testANonEnumerableFieldIsRefusedAsInvalidParams() throws {
        let response = try send(method: "context/enumerate", params: ["field": "file_dirs"])
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        let message = try XCTUnwrap(error["message"] as? String)
        XCTAssertTrue(message.contains("file_dirs"), message)
        XCTAssertNil(response["result"])
    }

    // MARK: - initialize still advertises the schema this dispatch reads

    /// Not a `context/enumerate` case, but the fact this dispatch and
    /// `initialize`'s `contextSchema` are reading the *same* declaration is
    /// exactly what keeps `file_dirs`'s refusal above from silently going
    /// stale if the schema changes shape.
    func testInitializeStillDeclaresTheEnumerableFieldsThisDispatchHonours() throws {
        let response = try send(method: "initialize", params: [:])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let serverInfo = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        let schema = try XCTUnwrap(serverInfo["contextSchema"] as? [String: Any])
        let mailAccounts = try XCTUnwrap(schema["mail_accounts"] as? [String: Any])
        XCTAssertEqual(mailAccounts["enumerable"] as? Bool, true)
        let fileDirs = try XCTUnwrap(schema["file_dirs"] as? [String: Any])
        XCTAssertNil(fileDirs["enumerable"], "file_dirs must stay non-enumerable for the refusal test above to mean anything")
    }

    /// The calendar / contacts / reminders fields reach the wire too. Their
    /// shape is pinned in `ScopeDeclarationTests` against the declaration
    /// itself; what this adds is that the rendering actually leaves the
    /// process, which is the only thing relay ever sees.
    func testInitializeCarriesTheCalendarContactsAndRemindersFields() throws {
        let response = try send(method: "initialize", params: [:])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let serverInfo = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(serverInfo["contextSchemaVersion"] as? Int, 2)
        let schema = try XCTUnwrap(serverInfo["contextSchema"] as? [String: Any])
        for name in ["calendar_accounts", "calendars", "contact_accounts",
                     "contact_groups", "reminder_accounts", "reminder_lists"] {
            let fragment = try XCTUnwrap(schema[name] as? [String: Any], name)
            XCTAssertEqual(fragment["scope"] as? String, "restrict", name)
            XCTAssertEqual(fragment["enumerable"] as? Bool, true, name)
        }
    }
}
