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

    /// Every mail tool is bounded by one wall-clock budget for the whole call,
    /// and every one of them lets the caller change it. That has to be in the
    /// schema twice over: a caller whose request comes back short needs to know
    /// there is a knob, and a caller on a machine where Mail is busy needs to
    /// know the default was measured somewhere quieter — the same script has
    /// been measured at 2.16s alone and 17.58s with another client driving Mail.
    func testEveryMailToolDocumentsItsTimeBudgetAndItsDefault() throws {
        let defaults: [String: TimeInterval] = [
            "mail_list_accounts": MailService.Budget.listAccounts,
            "mail_list_mailboxes": MailService.Budget.listMailboxes,
            "mail_get_emails": MailService.Budget.getEmails,
            "mail_get_email": MailService.Budget.getEmail,
            "mail_search": MailService.Budget.search,
            "mail_send": MailService.Budget.send,
            "mail_create_draft": MailService.Budget.createDraft,
            "mail_save_attachment": MailService.Budget.saveAttachment,
            "mail_get_source": MailService.Budget.getSource,
            "mail_move": MailService.Budget.move,
            "mail_mark_read": MailService.Budget.markRead,
        ]
        XCTAssertEqual(Set(defaults.keys), Set(tools.keys), "a mail tool with no budget documented")

        for (tool, fallback) in defaults {
            let text = try property("timeout_seconds", of: tool)
            XCTAssertTrue(
                text.contains("\(Int(fallback))"),
                "\(tool) does not say its own default of \(Int(fallback))s: \(text)"
            )
            XCTAssertTrue(
                text.contains("\(Int(MailCall.maxCallerBudget))"),
                "\(tool) does not say how far the budget can be raised: \(text)"
            )
            assertMentions(
                text, anyOf: ["seconds"], "\(tool)'s budget being in seconds"
            )
        }
    }

    /// What running out of budget means is not the same for a read and for a
    /// tool that changes something. A read hands back what it read. A send can
    /// have the budget fire after Mail has already acted, so "nothing happened"
    /// is exactly what a caller must not infer — that is the difference between
    /// a safe retry and sending twice.
    func testOnlyTheReadsPromiseThatRunningOutCostsNothing() throws {
        for tool in ["mail_send", "mail_create_draft", "mail_move", "mail_mark_read"] {
            let text = try property("timeout_seconds", of: tool)
            XCTAssertFalse(
                text.contains("not an error"),
                "\(tool) changes something; it cannot promise the budget firing is free: \(text)"
            )
            assertMentions(
                text, anyOf: ["before retrying", "already acted"],
                "\(tool) warning that Mail may have acted already"
            )
        }
        for tool in ["mail_get_emails", "mail_search", "mail_get_email", "mail_get_source"] {
            assertMentions(
                try property("timeout_seconds", of: tool),
                anyOf: ["not an error"],
                "\(tool) saying a short read is still a result"
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

    // MARK: - The two tools share one attachment namespace (#R2-2, #R4-4)

    func testBothAttachmentToolsSayTheyAreTalkingAboutTheSameList() throws {
        // The defect a caller met first was a documented promise that was not
        // true: `attachment_name` said "as reported by mail_get_email" while
        // mail_save_attachment selected out of a different list, under different
        // names, in a different order. Now that they really are one list, both
        // descriptions have to say so — a caller who does not know they agree
        // has no reason to copy a name from one into the other.
        let get = try description(of: "mail_get_email")
        let save = try description(of: "mail_save_attachment")
        for text in [get, save] {
            assertMentions(
                text,
                anyOf: ["same list", "SAME list", "exactly the list mail_get_email reports"],
                "the two tools agreeing"
            )
            XCTAssertTrue(text.contains("part_path"), "the exact handle: \(text)")
            XCTAssertTrue(text.contains("inline"), "what is deliberately not an attachment: \(text)")
        }

        // And `attachment_name` names which of the two names is the handle,
        // since mail_get_email now reports both.
        let name = try property("attachment_name", of: "mail_save_attachment")
        XCTAssertTrue(name.contains("mail_name"), name)

        let path = try property("part_path", of: "mail_save_attachment")
        assertMentions(path, anyOf: ["inline"], "the one way to reach an inline part")
    }

    /// A mailbox that changes under a scan no longer costs the caller the
    /// mailbox — its rows are re-read one message at a time instead. That is a
    /// different answer with different fields in it, and the fields are only
    /// legible if the schema names them: `changed_mailboxes` says where it
    /// happened, `rows_reverified` / `rows_dropped` say what it cost, and for a
    /// search it is also why `scan_complete` is false.
    func testTheScanToolsSayWhatAChangedMailboxMeansForTheAnswer() throws {
        for tool in ["mail_get_emails", "mail_search"] {
            let text = try description(of: tool)
            XCTAssertTrue(text.contains("changed_mailboxes"), "\(tool): \(text)")
            XCTAssertTrue(text.contains("rows_reverified"), "\(tool): \(text)")
            XCTAssertTrue(text.contains("rows_dropped"), "\(tool): \(text)")
            assertMentions(
                text,
                anyOf: ["re-read", "reread", "read message by message"],
                "\(tool) saying the rows were re-read rather than discarded"
            )
            // `skipped_mailboxes` now carries a reason per entry, which is the
            // difference between a mailbox that is gone and one Mail was busy.
            XCTAssertTrue(text.contains("skipped_mailboxes"), "\(tool): \(text)")
        }

        // And the body pass reports its own coverage, because it is a second
        // scan of the same scope and can fall short where the first did not.
        let search = try description(of: "mail_search")
        XCTAssertTrue(search.contains("body_scan_complete"), search)
        assertMentions(
            search,
            anyOf: ["body_scan_skipped_mailboxes", "body_scan_note", "second pass's own coverage"],
            "the body pass's own coverage"
        )
    }
}
