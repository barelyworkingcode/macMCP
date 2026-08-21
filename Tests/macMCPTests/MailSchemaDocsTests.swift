import XCTest
@testable import macmcp

/// The schema is the only documentation a caller ever sees, so the few places
/// where a mail tool does something surprising have to say so *there* — not in a
/// code comment, and not in CLAUDE.md.
///
/// Each assertion below stands for a defect that was filed because the behaviour
/// was undocumented rather than wrong (#21, #22) or because it was claimed to be
/// something it is not (#20). A doc fix that nothing checks is a doc fix that
/// comes out in the next edit.
final class MailSchemaDocsTests: XCTestCase {
    private var tools: [String: MCPTool] = [:]

    override func setUp() {
        let registry = ToolRegistry()
        MailService.register(registry)
        tools = Dictionary(uniqueKeysWithValues: registry.allTools().map { ($0.name, $0) })
    }

    private func description(of tool: String) throws -> String {
        try XCTUnwrap(tools[tool]?.description, "\(tool) is not registered")
    }

    /// The `description` of one property of a tool's input schema.
    private func property(_ name: String, of tool: String) throws -> String {
        guard case let .object(schema)? = tools[tool]?.inputSchema,
              case let .object(properties)? = schema["properties"],
              case let .object(property)? = properties[name],
              case let .string(text)? = property["description"] else {
            XCTFail("\(tool) has no \(name) property")
            return ""
        }
        return text
    }

    // MARK: - A cross-account move changes the bytes (#21)

    func testTargetAccountSaysItIsAReUploadRatherThanAMove() throws {
        let text = try property("target_account", of: "mail_move")
        XCTAssertTrue(text.contains("re-send"), text)
        XCTAssertTrue(text.contains("not a server-side move"), text)
        // The three consequences a caller can be bitten by, each measured
        // against the fixture's Maildir.
        XCTAssertTrue(text.contains("Message-Id"), "what survives: \(text)")
        XCTAssertTrue(text.contains("numeric message_id"), "what does not: \(text)")
        XCTAssertTrue(text.contains("NUL"), "the byte-level caveat: \(text)")
    }

    // MARK: - rendered_chars is not the body's length (#22)

    func testBothComposeToolsSayWhatRenderedCharsCounts() throws {
        for tool in ["mail_send", "mail_create_draft"] {
            let text = try description(of: tool)
            XCTAssertTrue(text.contains("rendered_chars"), tool)
            XCTAssertTrue(text.contains("whitespace removed"), "\(tool): \(text)")
            // The example is the part that makes it unmissable: a caller
            // comparing 15 against body.count needs to see why.
            XCTAssertTrue(text.contains("reports 15"), "\(tool): \(text)")
        }
    }

    // MARK: - A fetched source is not the message (#20)

    func testTheSourceToolsWarnThatTheBytesAreNotTheMessages() throws {
        let source = try description(of: "mail_get_source")
        XCTAssertTrue(source.contains("NOT byte-identical"), source)
        XCTAssertTrue(source.contains("fidelity"), source)
        XCTAssertTrue(source.contains("LF"), source)
        XCTAssertTrue(source.contains("0x80"), source)

        let save = try description(of: "mail_save_attachment")
        XCTAssertTrue(save.contains("fidelity"), save)
        XCTAssertTrue(save.contains("base64"), "the case that is unaffected: \(save)")
    }
}
