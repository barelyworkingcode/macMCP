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

    /// Asserts the text conveys something, without pinning the sentence it
    /// currently uses to convey it.
    ///
    /// The assertions here used to be `contains("re-send")` and
    /// `contains("reports 15")`, so a legitimate reword failed a test while
    /// nothing had got worse (#41). What has to hold is that the interface's own
    /// names and numbers are there — those are stable, being the thing a caller
    /// reads — and that each caveat is stated in one of the ways it can be
    /// stated.
    private func assertMentions(
        _ text: String,
        anyOf alternatives: [String],
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            alternatives.contains { text.range(of: $0, options: .caseInsensitive) != nil },
            "nothing about \(what) — none of \(alternatives) in: \(text)",
            file: file, line: line
        )
    }

    /// A message can nest multipart parts as deep as its sender likes. macMCP
    /// stops descending at `MIME.maxDepth`, which makes the attachment list
    /// short rather than wrong — and short is indistinguishable from "this
    /// message has fewer attachments" unless the schema says the field exists
    /// and what it means (#R3-1).
    func testTheAttachmentToolsSayWhenAMessageWasNotReadInFull() throws {
        for tool in ["mail_get_email", "mail_save_attachment"] {
            assertMentions(
                try description(of: tool),
                anyOf: ["parsed_complete"],
                "\(tool) reporting a message it could not parse in full"
            )
        }
    }

    func testListMailboxesNamesMailsOwnLocalMailboxes() throws {
        // They are scanned and their rows come back labelled `On My Mac:...`,
        // so a listing that does not name them hands a caller a mailbox they
        // cannot ask for -- and relay's resource scoping cannot scope what the
        // enumeration does not name (#54).
        let text = try description(of: "mail_list_mailboxes") + property("account", of: "mail_list_mailboxes")
        assertMentions(text, anyOf: ["On My Mac"], "Mail's local mailboxes")
        for tool in ["mail_get_emails", "mail_search"] {
            assertMentions(
                try property("account", of: tool),
                anyOf: ["On My Mac"],
                "\(tool) accepting the local boxes as a scope"
            )
        }
    }

    /// `contains("LF")` is true of "CRLF", which is the opposite of the thing
    /// being checked, so the term has to stand on its own.
    private func assertMentionsWord(
        _ text: String,
        _ word: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            text.range(of: "\\b\(word)\\b", options: [.regularExpression]) != nil,
            "\(word) does not appear as a word of its own in: \(text)",
            file: file, line: line
        )
    }

    // MARK: - A cross-account move changes the bytes (#21)

    func testTargetAccountSaysItIsAReUploadRatherThanAMove() throws {
        let text = try property("target_account", of: "mail_move")
        assertMentions(text, anyOf: ["re-send", "re-upload", "reupload", "upload"], "the message being sent again")
        assertMentions(text, anyOf: ["server-side", "server side"], "what it is not")
        // The three consequences a caller can be bitten by, each measured
        // against the fixture's Maildir. These are interface names, not prose:
        // a caller matches on them.
        XCTAssertTrue(text.contains("Message-Id"), "what survives: \(text)")
        XCTAssertTrue(text.contains("message_id"), "what does not: \(text)")
        XCTAssertTrue(text.contains("NUL"), "the byte-level caveat: \(text)")
    }

    // MARK: - rendered_chars is not the body's length (#22)

    func testBothComposeToolsSayWhatRenderedCharsCounts() throws {
        for tool in ["mail_send", "mail_create_draft"] {
            let text = try description(of: tool)
            XCTAssertTrue(text.contains("rendered_chars"), tool)
            assertMentions(text, anyOf: ["whitespace"], "what is not counted (\(tool))")
            // The worked example is what makes it unmissable: both numbers have
            // to be there, because the point is the gap between them. Which way
            // round the sentence puts them is not the test's business.
            for number in ["15", "18"] {
                XCTAssertTrue(text.contains(number), "the worked example's \(number) (\(tool)): \(text)")
            }
        }
    }

    // MARK: - A fetched source is not the message (#20, #38, #39)

    func testTheSourceToolsWarnThatTheBytesAreNotTheMessages() throws {
        let source = try description(of: "mail_get_source")
        assertMentions(source, anyOf: ["NOT byte-identical", "not byte-identical"], "the headline claim")
        XCTAssertTrue(source.contains("fidelity"), source)
        assertMentionsWord(source, "LF")
        XCTAssertTrue(source.contains("CRLF"), source)
        XCTAssertTrue(source.contains("0x80"), source)

        let save = try description(of: "mail_save_attachment")
        XCTAssertTrue(save.contains("fidelity"), save)
        assertMentions(save, anyOf: ["base64"], "the case that is unaffected")
    }

    func testTheSourceSchemaSaysWhenCompletenessWasNotActuallyChecked() throws {
        // #39: `complete` is "nothing contradicts it" when Mail would not report
        // the message's size, and a caller reading it as a verified match has no
        // way to tell from the field alone.
        let source = try description(of: "mail_get_source")
        XCTAssertTrue(source.contains("message_size"), source)
        assertMentions(source, anyOf: ["null", "not report"], "the unknown-size case")
    }

    // MARK: - mail_get_email withholds what it could not check (#33)

    func testGetEmailSaysWhichFieldsItWillNotReportOnAnIncompleteMessage() throws {
        let text = try description(of: "mail_get_email")
        XCTAssertTrue(text.contains("fidelity"), text)
        XCTAssertTrue(text.contains("omitted"), text)
        XCTAssertTrue(text.contains("has_attachments"), text)
        XCTAssertTrue(text.contains("listed_by_mail"), "the reconciled list: \(text)")
    }
}
