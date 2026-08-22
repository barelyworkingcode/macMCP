import XCTest
@testable import macmcp

/// What `_meta` has to look like before macMCP will believe a chokepoint
/// mediated a call (ADR-011 decision 4).
///
/// This is the one test decision 4 says belongs to the MCP rather than to
/// relay: "an absent `_meta` means nobody mediated", and everything else means
/// somebody did. Getting the *absent* half wrong is the fail-open direction,
/// because a call that looks unmediated is answered with every account, every
/// mailbox and `mail_send`.
///
/// `main.swift` used to read `req.params?["_meta"]?.objectValue`, which is
/// `nil` for `null`, for an array, for a string and for a number alike --
/// indistinguishable from the key being absent. `"_meta": null` therefore took
/// the unmediated branch. Relay always sends an object, so nothing reachable
/// through relay produced it; that is precisely why it had to be closed here,
/// since a check that holds only because of what the other side happens to
/// send is one check and not two.
///
/// Hermetic **in both directions**, which is what a load-bearing test of a
/// gate has to be: the malformed cases name a tool that does not exist, so
/// they are decided in `main.swift` before `ToolRegistry` dispatches when the
/// check is in place *and* answered by the registry's own "unknown tool" when
/// it is not -- neither path reaches a service. A test that proved the gate by
/// letting a mail tool run once it was removed would talk to Mail.app on
/// exactly the run where the check had regressed.
final class MetaMediationDispatchTests: StdioServerTestCase {
    private func call(tool: String, meta: Any?) throws -> [String: Any] {
        var params: [String: Any] = ["name": tool, "arguments": [:]]
        if let meta { params["_meta"] = meta }
        return try send(method: "tools/call", params: params)
    }

    /// The shape that must refuse, in every rendering of "present but not an
    /// object" a JSON encoder can produce.
    private func assertRefused(_ meta: Any, _ label: String) throws {
        let response = try call(tool: "no_such_tool", meta: meta)
        let error = try XCTUnwrap(response["error"] as? [String: Any], "\(label): expected a JSON-RPC error")
        XCTAssertEqual(error["code"] as? Int, -32602, label)
        let message = try XCTUnwrap(error["message"] as? String)
        XCTAssertTrue(message.contains("_meta"), "\(label): \(message)")
        XCTAssertNil(response["result"], "\(label): a refused call must not carry a result")
    }

    func testANullMetaIsRefusedRatherThanReadAsUnmediated() throws {
        // The exact reproduction: `_meta: null` used to yield every account,
        // every mailbox and mail_send.
        try assertRefused(NSNull(), "null")
    }

    func testAnArrayMetaIsRefused() throws {
        try assertRefused([1, 2, 3], "array")
    }

    func testAStringMetaIsRefused() throws {
        try assertRefused("mail_accounts=Bob", "string")
    }

    func testANumberMetaIsRefused() throws {
        try assertRefused(7, "number")
    }

    func testABooleanMetaIsRefused() throws {
        try assertRefused(true, "boolean")
    }

    /// The other half, and the one that keeps the fix from being "refuse
    /// everything": a genuinely absent `_meta` is the unmediated call macmcp
    /// has always served over a bare stdio pipe, and it must still reach
    /// `ToolRegistry`. Reaching the registry is the whole assertion -- the
    /// registry answering "unknown tool" is proof the request got past the
    /// gate, from a call that can touch nothing.
    func testAnAbsentMetaStillMeansNobodyMediated() throws {
        let response = try call(tool: "no_such_tool", meta: nil)
        XCTAssertNil(response["error"], "an absent _meta is not malformed; it is the unmediated case")
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertEqual(text, "unknown tool: no_such_tool", "the call reached the registry")
    }

    /// An **empty object** is a mediated call carrying no scope, which is a
    /// refusal by decision 4 -- but a *tool* refusal, made by the handler,
    /// not a malformed request. The distinction is the whole point: one is
    /// "this request is not well formed", the other is "this client was
    /// granted nothing", and they are answered in different places with
    /// different shapes.
    func testAnEmptyObjectMetaIsMediatedAndRefusedByTheHandler() throws {
        let response = try call(tool: "mail_list_accounts", meta: [String: Any]())
        XCTAssertNil(response["error"], "a well-formed _meta is not a protocol error")
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let meta = try XCTUnwrap(result["_meta"] as? [String: Any], "a scope refusal carries the marker")
        XCTAssertEqual(meta["scope_violation"] as? Bool, true)
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(text.contains("mail_accounts"), text)
    }
}
