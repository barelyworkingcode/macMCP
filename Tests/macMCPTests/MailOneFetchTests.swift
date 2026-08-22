import XCTest
@testable import macmcp

/// One fetch per message, and one script to fetch it with.
///
/// `mail_get_email` used to run two osascript processes with a
/// `findMessageJXA` in each: the first for Mail's own properties, the second
/// for the source those properties are then checked against. The second one is
/// not optional — Mail answers `body: ""` and `has_attachments: false` for a
/// message it has not finished downloading, without complaint — so the message
/// was being downloaded on every call regardless, and the split bought a second
/// process, a second bind, and two readings of `messageSize` taken at two
/// moments.
///
/// Measured against the fixture: a small `mail_get_email` went 0.71s → 0.45s
/// (n=5 each), and the natural `mail_get_email` → `mail_save_attachment`
/// sequence on a 7,082,933-byte message went 1.15s → 0.65s, with the second
/// call falling from 0.30s to 0.02s because the source it needs is the source
/// the first call already fetched. The attachment it writes is byte-identical
/// either way (sha256 38d3b1d3…, the same bytes Python's `email` module
/// extracts from the Maildir).
///
/// What makes both possible is one line of ASCII in front of the message bytes.
final class MailOneFetchTests: XCTestCase {
    private static let stub = """
    var mail = makeMail({accounts: [
        {name: 'Alice', mailboxes: [
            {name: 'INBOX', messages: [
                {id: 200, messageId: 'probe@relaytest.local', subject: 'Quarterly numbers',
                 sender: 'bob@relaytest.local', content: 'hello there',
                 source: 'Subject: Quarterly numbers\\n\\nhello there\\n', size: 40}
            ]}
        ]}
    ]});
    """

    /// Runs the source script against the stub and hands back exactly what it
    /// wrote, the way `fetchSource` receives it.
    private func fetch(meta: String?, stub: String = MailOneFetchTests.stub) throws -> Data {
        try JXA.runRaw("""
        \(MailStubJS.source)
        \(stub)
        \(MailService.sourceScriptJXA(
            account: "Alice", mailbox: "INBOX", messageId: "200",
            attempts: 1, interval: 0, meta: meta
        ))
        """)
    }

    // MARK: - Both answers, one script

    func testThePropertiesAndTheBytesComeBackTogether() throws {
        let raw = try fetch(meta: "{subject: '' + found.subject(), body: '' + found.content()}")
        let head = MailService.splitMetaMarker(raw)
        XCTAssertNil(head.error, "\(head.error ?? "")")
        let meta = try XCTUnwrap(head.meta, "the script wrote no properties line")
        XCTAssertEqual(meta["subject"] as? String, "Quarterly numbers")
        XCTAssertEqual(meta["body"] as? String, "hello there")

        // And the bytes behind it are still the message, split by the same
        // marker as before.
        let marker = MailService.splitSourceSizeMarker(head.rest)
        XCTAssertNil(marker.error)
        XCTAssertEqual(marker.size, 40)
        XCTAssertEqual(
            String(decoding: MailService.decodeSourceBytes(marker.body), as: UTF8.self),
            "Subject: Quarterly numbers\n\nhello there\n"
        )
    }

    func testAFetchThatAsksForNoPropertiesIsUnchanged() throws {
        // Every other caller of the source fetch gets exactly the bytes it got
        // before: the marker cannot be at offset 0, because MACMCP-SIZE: is.
        let raw = try fetch(meta: nil)
        let head = MailService.splitMetaMarker(raw)
        XCTAssertNil(head.meta)
        XCTAssertNil(head.error)
        XCTAssertEqual(head.rest, raw, "bytes were taken off the front of a fetch that asked for nothing")
    }

    // MARK: - The line has to survive sitting in front of raw bytes

    func testANonAsciiSubjectSurvivesTheSourceDecoding() throws {
        // The bytes behind this line are decoded UTF-8-in, Latin-1-out, which
        // would mangle anything above U+007F written literally. The script
        // escapes every such scalar as \\uXXXX, so the line is pure ASCII and
        // comes through untouched — the same reason CLAUDE.md gives for Mail
        // escaping non-ASCII in generated JXA.
        let stub = Self.stub.replacingOccurrences(
            of: "subject: 'Quarterly numbers'",
            with: "subject: 'שלום — naïve'"
        )
        let raw = try fetch(meta: "{subject: '' + found.subject()}", stub: stub)
        for byte in raw.prefix(while: { $0 != 0x0A }) {
            XCTAssertLessThan(byte, 0x80, "the properties line is not ASCII, so it cannot sit in front of raw bytes")
        }
        let meta = try XCTUnwrap(MailService.splitMetaMarker(raw).meta)
        XCTAssertEqual(meta["subject"] as? String, "שלום — naïve")
    }

    // MARK: - Failing closed

    func testAMalformedPropertiesLineCostsTheBytesRatherThanCorruptingThem() throws {
        // Same rule as the size marker: anything left on the front of a message
        // reaches save_to files, byte counts and MIME.parse as a bogus header.
        let raw = Data("MACMCP-META:not json at all\nMACMCP-SIZE:10\nhello\n".utf8)
        let head = MailService.splitMetaMarker(raw)
        XCTAssertNotNil(head.error)
        XCTAssertTrue(head.rest.isEmpty, "bytes were returned beneath a line that could not be read")
    }

    func testAPropertiesLineWithNoEndIsRefused() throws {
        let head = MailService.splitMetaMarker(Data("MACMCP-META:{\"a\":1}".utf8))
        XCTAssertNotNil(head.error)
        XCTAssertTrue(head.rest.isEmpty)
    }

    // MARK: - What the held source is keyed on

    func testANumericIdIsKeyedWithoutTheMailbox() throws {
        // `findMessageJXA` ignores `mailbox` entirely for a numeric id — it
        // binds through `mail.inbox.messages.byId` and asks the message where
        // it is. So `mail_get_email` (which knows the message is in
        // "R4-PROBE-Hostile") and `mail_save_attachment` (which defaults to
        // "INBOX") have to reach the same held bytes, or the sequence this
        // exists for downloads twice anyway.
        XCTAssertEqual(
            MailService.sourceCacheKey(account: "Bob", mailbox: "INBOX", messageId: "132052"),
            MailService.sourceCacheKey(account: "Bob", mailbox: "R4-PROBE-Hostile", messageId: "132052")
        )
    }

    func testAnRfcMessageIdKeepsTheMailboxInTheKey() throws {
        // That path *is* searched mailbox-first, and a duplicated Message-ID
        // can be in two mailboxes, so the same string can name two messages.
        XCTAssertNotEqual(
            MailService.sourceCacheKey(account: "Bob", mailbox: "INBOX", messageId: "<a@b.test>"),
            MailService.sourceCacheKey(account: "Bob", mailbox: "Archive", messageId: "<a@b.test>")
        )
    }

    func testTheAccountIsPartOfTheKeyAndIsCaseInsensitive() throws {
        XCTAssertEqual(
            MailService.sourceCacheKey(account: "bob", mailbox: "INBOX", messageId: "132052"),
            MailService.sourceCacheKey(account: "Bob", mailbox: "INBOX", messageId: "132052")
        )
        XCTAssertNotEqual(
            MailService.sourceCacheKey(account: nil, mailbox: "INBOX", messageId: "132052"),
            MailService.sourceCacheKey(account: "Bob", mailbox: "INBOX", messageId: "132052")
        )
    }

    func testAnIdentifierNothingCanCarryIsNeverKeyed() throws {
        XCTAssertNil(MailService.sourceCacheKey(account: nil, mailbox: "INBOX", messageId: "0132085"))
    }
}
