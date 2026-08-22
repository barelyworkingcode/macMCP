import Foundation
import XCTest
@testable import macmcp

/// `_meta` reaching a handler at all (ADR-011 finding 3).
///
/// `main.swift` used to read only `params.name` and `params.arguments`; a
/// grep for `_meta` across `Sources/` returned nothing, and `ToolHandler` was
/// a bare `(JSONObject?) -> MCPCallResult` with no side channel to carry it.
/// These tests exercise the plumbing end to end through `ToolRegistry`
/// itself, independent of any one service, so they stay meaningful even once
/// a real consumer (`MailScope`) is doing something with the value.
final class MCPCallContextTests: XCTestCase {
    /// A registry with one tool whose handler reports back exactly what it
    /// was given, so the test can assert on the context rather than on any
    /// service's own behaviour.
    private func echoRegistry() -> ToolRegistry {
        let registry = ToolRegistry()
        registry.register(
            MCPTool(name: "echo_ctx", description: "test", inputSchema: emptySchema()),
            category: "Test"
        ) { ctx in
            var payload: [String: Any] = [
                "has_arguments": ctx.arguments != nil,
                "has_meta": ctx.meta != nil
            ]
            if let probe = ctx.arguments?["probe"]?.stringValue {
                payload["probe"] = probe
            }
            if let projectID = ctx.meta?["project_id"]?.stringValue {
                payload["project_id"] = projectID
            }
            return jsonResult(payload)
        }
        return registry
    }

    private func decode(_ result: MCPCallResult) -> [String: Any] {
        guard let text = result.content.first?.text,
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("result was not the JSON object the test handler returns")
            return [:]
        }
        return obj
    }

    func testMetaReachesTheHandler() {
        let registry = echoRegistry()
        let result = registry.call(
            name: "echo_ctx",
            arguments: ["probe": .string("hi")],
            meta: ["project_id": .string("prof_123")]
        )
        let payload = decode(result)
        XCTAssertEqual(payload["has_meta"] as? Bool, true)
        XCTAssertEqual(payload["project_id"] as? String, "prof_123")
        XCTAssertEqual(payload["probe"] as? String, "hi")
    }

    /// Absent `_meta` must be indistinguishable from today's behaviour: a
    /// call made the way every caller made one before this change (no third
    /// argument at all) still reaches the handler, with `meta` reading `nil`
    /// rather than an empty object standing in for "not sent".
    func testOmittingMetaBehavesAsBeforeTheChange() {
        let registry = echoRegistry()
        let result = registry.call(name: "echo_ctx", arguments: ["probe": .string("hi")])
        let payload = decode(result)
        XCTAssertEqual(payload["has_meta"] as? Bool, false)
        XCTAssertEqual(payload["probe"] as? String, "hi")
    }

    /// `meta: nil` passed explicitly is the same as omitting it -- the
    /// parameter exists so `main.swift` can always pass whatever
    /// `req.params?["_meta"]?.objectValue` produced, without special-casing
    /// the absent case itself.
    func testExplicitNilMetaIsTheSameAsOmittingIt() {
        let registry = echoRegistry()
        let result = registry.call(name: "echo_ctx", arguments: nil, meta: nil)
        let payload = decode(result)
        XCTAssertEqual(payload["has_arguments"] as? Bool, false)
        XCTAssertEqual(payload["has_meta"] as? Bool, false)
    }

    /// An unknown tool name still reports the same error it always did --
    /// widening `ToolHandler` must not change the not-found path, which never
    /// reaches a handler at all.
    func testUnknownToolIsStillReportedTheSameWay() {
        let registry = echoRegistry()
        let result = registry.call(name: "no_such_tool", arguments: nil)
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(result.content.first?.text, "unknown tool: no_such_tool")
    }
}
