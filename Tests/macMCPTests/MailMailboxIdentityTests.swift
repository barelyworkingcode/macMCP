import XCTest
@testable import macmcp

/// What a mailbox *is*, as far as every mail tool is concerned.
///
/// Mail flattens an account's mailbox tree and reports **leaf** names, so one
/// account really does enumerate two mailboxes called `Archive` (a top-level
/// one and `Projects/Archive`), two called `Trash`, two called `Drafts`. Every
/// tool here used to resolve, label and exclude a mailbox by that name, and
/// each of those is a different way of guessing between two mailboxes:
///
/// * `mail_move` to `"Archive"` filed into `Projects/Archive`, and to
///   `"Trash"` into `R4-PROBE-Deep/Trash` — a "delete this" left undeleted in a
///   user's project folder — both reported `verified: true`, because the
///   read-back looked in the mailbox the pick had chosen.
/// * a scan stamped every row `"mailbox": "Archive"` whichever `Archive` it
///   came out of, so the label could not be passed back as a scope.
/// * `mailbox: "all"` excluded Trash, Junk and Drafts by leaf name, silently
///   dropping any user folder anywhere in the tree that carried one of those
///   names, with `skipped_mailboxes: []` and `scan_complete: true`.
///
/// The identity is the **path**: the leaf names of a mailbox's containers,
/// outermost first, joined with `/`. It is not a label invented here — Mail's
/// own `byName` takes one (`byName('Projects/Archive')` resolves,
/// `byName('Archive')` resolves to the top-level one), so it is also the
/// handle the mailbox is bound by, and `/` cannot occur inside a leaf name
/// because Mail treats it as the separator.
///
/// These run the generated JavaScript against the stub, because which mailbox
/// object the script picks is not visible from Swift, and they check the answer
/// against the stub's own arrays rather than against what the script reported.
final class MailMailboxIdentityTests: XCTestCase {
    /// Bob as the fixture has him: nested folders enumerated before their
    /// parents, the account's own special mailboxes last, and two mailboxes
    /// each called `Archive` and `Trash`.
    private static let bob = """
    var mail = makeMail({accounts: [{name: 'Bob', mailboxes: [
        {name: 'Archive', container: 'Projects', messages: [
            {id: 10, messageId: 'nested-archive@relaytest.local', subject: 'NESTED-ARCHIVE', date: 1000}]},
        {name: 'Projects', messages: []},
        {name: 'Trash', container: 'R4-PROBE-Deep', messages: [
            {id: 11, messageId: 'nested-trash@relaytest.local', subject: 'R4-PROBE-NESTED-Trash', date: 1100}]},
        {name: 'Drafts', container: 'R4-PROBE-Deep', messages: [
            {id: 14, messageId: 'nested-drafts@relaytest.local', subject: 'R4-PROBE-NESTED-Drafts', date: 1150}]},
        {name: 'R4-PROBE-Deep', messages: []},
        {name: 'Archive', messages: [
            {id: 12, messageId: 'top-archive@relaytest.local', subject: 'Decommission plan', date: 1200}]},
        {name: 'INBOX', messages: [
            {id: 100, messageId: 'bob-inbox@relaytest.local', subject: 'Lunch Thursday?', date: 1300}]},
        {name: 'Drafts', messages: []},
        {name: 'Trash', messages: []},
        {name: 'Junk', messages: []}
    ]}]});
    """

    /// Two mailboxes carrying the same leaf name with **no** top-level mailbox
    /// of that name, so nothing in the request can distinguish them.
    private static let bobWithTwins = """
    var mail = makeMail({accounts: [{name: 'Bob', mailboxes: [
        {name: 'Dup', container: 'Projects', messages: [{id: 20, subject: 'in Projects/Dup', date: 1000}]},
        {name: 'Projects', messages: []},
        {name: 'Dup', container: 'Receipts', messages: [{id: 21, subject: 'in Receipts/Dup', date: 1100}]},
        {name: 'Receipts', messages: []},
        {name: 'INBOX', messages: [{id: 100, messageId: 'bob-inbox@relaytest.local', subject: 'hi', date: 1300}]}
    ]}]});
    """

    // MARK: - Harness

    private struct MoveOutcome {
        /// What the script threw, if it refused.
        let thrown: String?
        let result: [String: Any]?
        /// The **path** of the mailbox that now holds the message, read off the
        /// stub's own arrays. This is the only thing here that can tell
        /// `Archive` from `Projects/Archive`.
        let landedIn: String?
    }

    private func move(
        _ stub: String,
        messageId: String = "100",
        targetMailbox: String
    ) throws -> MoveOutcome {
        let payload = try JXA.runJSON("""
        \(MailStubJS.source)
        \(stub)
        function whereIs(id) {
            var boxes = mail.accounts()[0].mailboxes();
            for (var i = 0; i < boxes.length; i++) {
                for (var j = 0; j < boxes[i]._msgs.length; j++) {
                    if (('' + boxes[i]._msgs[j]._id) === ('' + id)) return boxes[i]._path;
                }
            }
            return null;
        }
        var thrown = null;
        var moveResult = null;
        try {
        \(MailService.moveScriptJXA(
            messageId: messageId,
            sourceMailbox: "INBOX",
            targetMailbox: targetMailbox,
            account: nil,
            targetAccount: nil
        ))
        } catch (e) { thrown = '' + e; }
        JSON.stringify({
            thrown: thrown,
            result: moveResult === null ? null : JSON.parse(JSON.stringify(moveResult)),
            landed_in: whereIs(\(messageId))
        });
        """)
        return MoveOutcome(
            thrown: payload["thrown"] as? String,
            result: payload["result"] as? [String: Any],
            landedIn: payload["landed_in"] as? String
        )
    }

    private func scan(_ stub: String, mailbox: String, extra: String = "") throws -> [String: Any] {
        try JXA.runJSON("""
        \(MailStubJS.source)
        \(stub)
        \(extra)
        \(MailService.scanScriptJXA(
            account: "Bob",
            mailbox: mailbox,
            query: nil,
            searchRecipients: false,
            limit: 50
        ))
        """)
    }

    private func rows(_ payload: [String: Any]) -> [(mailbox: String, id: String)] {
        (payload["rows"] as? [[String: Any]] ?? []).map {
            ($0["mailbox"] as? String ?? "", $0["id"] as? String ?? "")
        }
    }

    // MARK: - A destination is resolved by identity (R2-1 / R4-1)

    func testABareNameNamesTheMailboxAtTheRootOfTheAccount() throws {
        // The defect, in one assertion. Mail enumerates children before parents,
        // so "the first mailbox called Archive" is systematically the nested
        // one — and the caller who typed `Archive` meant the mailbox carrying
        // the account's `\\Archive` flag. A bare name is a path with one
        // component, which is how Mail's own `byName` reads it too.
        let outcome = try move(Self.bob, targetMailbox: "Archive")

        XCTAssertNil(outcome.thrown, "an unambiguous destination was refused")
        XCTAssertEqual(outcome.landedIn, "Archive", "the message was filed into the wrong Archive")
        XCTAssertEqual(outcome.result?["mailbox"] as? String, "Archive")
        XCTAssertEqual(outcome.result?["verified"] as? Bool, true)
    }

    func testDeletingSomethingDoesNotFileItIntoAUsersProjectFolder() throws {
        // The measured shape of the bug: a move to "Trash" landed in
        // `R4-PROBE-Deep/Trash`, so a message the caller asked to delete stayed
        // in a user folder and the result said `verified: true`.
        let outcome = try move(Self.bob, targetMailbox: "Trash")

        XCTAssertEqual(outcome.landedIn, "Trash", "\"delete this\" filed the message into a user folder")
        XCTAssertEqual(outcome.result?["mailbox"] as? String, "Trash")
    }

    func testAnExactPathReachesTheNestedMailbox() throws {
        // The other half: the nested mailbox has to remain reachable, and by a
        // string that names it and nothing else.
        let outcome = try move(Self.bob, targetMailbox: "Projects/Archive")

        XCTAssertNil(outcome.thrown)
        XCTAssertEqual(outcome.landedIn, "Projects/Archive")
        XCTAssertEqual(outcome.result?["mailbox"] as? String, "Projects/Archive")
    }

    func testAResultNamesTheDestinationSoTheTwoCanBeToldApart() throws {
        // Both moves used to come back `{"mailbox": "Archive", "verified": true}`
        // — the same response for two different mailboxes, which is what made
        // the wrong one invisible.
        let top = try move(Self.bob, targetMailbox: "Archive")
        let nested = try move(Self.bob, targetMailbox: "Projects/Archive")

        XCTAssertNil(top.thrown, "the top-level Archive could not be named")
        XCTAssertNil(nested.thrown, "the nested Archive could not be named")
        XCTAssertNotEqual(top.landedIn, nested.landedIn, "the two runs should file into different mailboxes")
        XCTAssertNotEqual(
            top.result?["mailbox"] as? String, nested.result?["mailbox"] as? String,
            "two different destinations, one description"
        )
    }

    func testWhereAMessageCameFromIsAlsoNamedByIdentity() throws {
        // `moved_from` is read off the message rather than off the request, and
        // it is a claim a caller may act on — it is the string they would pass
        // back to put the message where it was.
        let payload = try JXA.runJSON("""
        \(MailStubJS.source)
        \(Self.bob)
        var moveResult = null;
        \(MailService.moveScriptJXA(
            messageId: "10",
            sourceMailbox: "Projects/Archive",
            targetMailbox: "INBOX",
            account: nil,
            targetAccount: nil
        ))
        JSON.stringify({result: JSON.parse(JSON.stringify(moveResult))});
        """)
        let result = payload["result"] as? [String: Any] ?? [:]
        let from = result["moved_from"] as? [String: Any] ?? [:]
        XCTAssertEqual(from["mailbox"] as? String, "Projects/Archive")
    }

    // MARK: - An ambiguous name is refused, with its candidates

    func testATargetNameTwoMailboxesCarryIsRefusedAndBothAreNamed() throws {
        // Neither is at the root, so neither is the one a bare name means, and
        // there is nothing left to resolve it by. Filing into one of the two is
        // a coin toss whose result the response cannot show, so it refuses —
        // and it names both paths, because "ambiguous" without them leaves the
        // caller no way to answer.
        let outcome = try move(Self.bobWithTwins, targetMailbox: "Dup")

        XCTAssertEqual(outcome.landedIn, "INBOX", "the message was filed despite the ambiguity")
        let message = try XCTUnwrap(
            outcome.thrown ?? outcome.result?["error"] as? String,
            "the ambiguity was resolved silently: \(outcome.result ?? [:])"
        )
        XCTAssertTrue(message.contains("Projects/Dup"), "the candidates are not named: \(message)")
        XCTAssertTrue(message.contains("Receipts/Dup"), "the candidates are not named: \(message)")
    }

    func testAUniqueLeafNameStillReachesANestedMailbox() throws {
        // The convenience the refusal must not cost: `Trash` under
        // `R4-PROBE-Deep` is the only mailbox called that in this account, and
        // Mail's own `byName` cannot reach it, so resolving it by leaf name is
        // the only way to name it short of its path.
        let outcome = try move("""
        var mail = makeMail({accounts: [{name: 'Bob', mailboxes: [
            {name: 'Sub', container: 'Archive', messages: []},
            {name: 'Archive', messages: []},
            {name: 'INBOX', messages: [{id: 100, messageId: 'bob-inbox@relaytest.local', subject: 'hi', date: 1}]}
        ]}]});
        """, targetMailbox: "Sub")

        XCTAssertNil(outcome.thrown)
        XCTAssertEqual(outcome.landedIn, "Archive/Sub")
        XCTAssertEqual(outcome.result?["mailbox"] as? String, "Archive/Sub")
    }

    func testANameNoMailboxCarriesIsStillRefusedAndTheAlternativesAreShownAsPaths() throws {
        let outcome = try move(Self.bob, targetMailbox: "Nowhere")
        let message = try XCTUnwrap(outcome.thrown ?? outcome.result?["error"] as? String)
        XCTAssertEqual(outcome.landedIn, "INBOX")
        XCTAssertTrue(
            message.contains("Projects/Archive"),
            "the mailboxes offered instead are leaf names, which is what could not be told apart: \(message)"
        )
    }

    // MARK: - `all` excludes by identity, and says what it excluded (R4-5)

    func testAUserFolderCalledTrashIsScannedRatherThanSilentlyDropped() throws {
        let payload = try scan(Self.bob, mailbox: "all")
        let scanned = payload["scanned"] as? [String] ?? []

        XCTAssertTrue(
            scanned.contains("Bob:R4-PROBE-Deep/Trash"),
            "a user folder called Trash was dropped from the scan: \(scanned)"
        )
        XCTAssertTrue(
            scanned.contains("Bob:R4-PROBE-Deep/Drafts"),
            "a user folder called Drafts was dropped from the scan: \(scanned)"
        )
        let subjects = (payload["rows"] as? [[String: Any]] ?? []).compactMap { $0["subject"] as? String }
        XCTAssertTrue(subjects.contains("R4-PROBE-NESTED-Trash"), "its messages are still unreachable: \(subjects)")
    }

    func testTheAccountsOwnSpecialMailboxesAreStillLeftOutAndAreNamed() throws {
        // Excluding them is the documented behaviour of `all`. Not saying which
        // ones is what let three messages disappear from a scan that reported
        // `scan_complete: true` and `skipped_mailboxes: []`.
        let payload = try scan(Self.bob, mailbox: "all")
        let excluded = payload["excluded"] as? [String] ?? []
        let scanned = payload["scanned"] as? [String] ?? []

        XCTAssertEqual(excluded.sorted(), ["Bob:Drafts", "Bob:Junk", "Bob:Trash"])
        for box in excluded {
            XCTAssertFalse(scanned.contains(box), "\(box) was both excluded and scanned")
        }
    }

    // MARK: - Every row carries the identity of the mailbox it came from

    func testARowIsStampedWithThePathOfTheMailboxItCameFrom() throws {
        let payload = try scan(Self.bob, mailbox: "all")
        let byId = Dictionary(uniqueKeysWithValues: rows(payload).map { ($0.id, $0.mailbox) })

        XCTAssertEqual(byId["10"], "Projects/Archive")
        XCTAssertEqual(byId["12"], "Archive")
        XCTAssertEqual(byId["11"], "R4-PROBE-Deep/Trash")
    }

    func testAskingForAMailboxByNameReadsTheOneAtTheRootOfTheAccount() throws {
        // The same rule the destination is resolved by, so a name means the
        // same mailbox to a read as it does to a move. Asking for `Archive` and
        // being given the union of two mailboxes is how a caller ends up acting
        // on a message that is not where they were told it is.
        let payload = try scan(Self.bob, mailbox: "Archive")

        XCTAssertEqual(payload["scanned"] as? [String] ?? [], ["Bob:Archive"])
        XCTAssertEqual(rows(payload).map(\.id), ["12"])
    }

    func testAskingForAMailboxByPathReadsThatMailbox() throws {
        let payload = try scan(Self.bob, mailbox: "Projects/Archive")

        XCTAssertEqual(payload["scanned"] as? [String] ?? [], ["Bob:Projects/Archive"])
        XCTAssertEqual(rows(payload).map(\.id), ["10"])
    }

    // MARK: - The schema is the only place a caller learns any of this

    private func property(_ name: String, of tool: String) throws -> String {
        let registry = ToolRegistry()
        MailService.register(registry)
        let tools = Dictionary(uniqueKeysWithValues: registry.allTools().map { ($0.name, $0) })
        guard case let .object(schema)? = tools[tool]?.inputSchema,
              case let .object(properties)? = schema["properties"],
              case let .object(property)? = properties[name],
              case let .string(text)? = property["description"] else {
            XCTFail("\(tool) has no \(name) property")
            return ""
        }
        return text
    }

    func testTheSchemaSaysAMailboxIsNamedByItsPath() throws {
        // A caller who does not know that `Archive` means the top-level one has
        // no way to ask for the other, and no reason to suspect there is
        // another. The example is the one measured on the fixture, so it is the
        // one a caller will meet.
        for (tool, property) in [
            ("mail_get_emails", "mailbox"),
            ("mail_search", "mailbox"),
            ("mail_move", "target_mailbox")
        ] {
            let text = try self.property(property, of: tool)
            XCTAssertTrue(text.contains("Projects/Archive"), "\(tool).\(property) does not show a path: \(text)")
        }
    }

    func testTheSchemaSaysAnAmbiguousDestinationIsRefused() throws {
        let text = try property("target_mailbox", of: "mail_move")
        XCTAssertTrue(
            text.range(of: "refus", options: .caseInsensitive) != nil,
            "nothing says an ambiguous name is refused rather than guessed at: \(text)"
        )
    }

    func testTheSchemaNamesTheFieldThatSaysWhatAnAllScanLeftOut() throws {
        // `all` excluding the account's own Trash, Junk and Drafts is by
        // design; not saying which ones is what made three messages vanish out
        // of a scan reporting `scan_complete: true`.
        for tool in ["mail_get_emails", "mail_search"] {
            let text = try property("mailbox", of: tool) + (
                {
                    let registry = ToolRegistry()
                    MailService.register(registry)
                    return registry.allTools().first { $0.name == tool }?.description ?? ""
                }()
            )
            XCTAssertTrue(
                text.contains("excluded_mailboxes"),
                "\(tool) never names the field that says what `all` left out: \(text)"
            )
        }
    }

    // MARK: - The window between the name column and the container columns

    /// Wraps Bob's mailbox collection so that `mutate` runs once, after the
    /// names have been read and before the container column that a path is
    /// built from.
    ///
    /// That is a second Apple Event on the same collection, read in lockstep by
    /// index exactly as the message scan reads a subject column beside an id
    /// column — so it gets exactly the message scan's guard, and this is what
    /// pins it.
    private static let containerWindow = """
    var bob = mail.accounts()[0];
    var live = bob.mailboxes();
    (function() {
        var original = bob.mailboxes;
        var fired = false;
        var wrapped = function() { return original(); };
        Object.defineProperty(wrapped, 'name', {
            value: function() { return original.name(); },
            writable: true, configurable: true
        });
        Object.defineProperty(wrapped, 'container', {
            get: function() {
                if (!fired) { fired = true; live.splice(0, 1); }
                return original.container;
            },
            configurable: true
        });
        wrapped.byName = function(n) { return original.byName(n); };
        bob.mailboxes = wrapped;
    })();
    """

    func testAMailboxDeletedBetweenTheNameAndContainerColumnsCannotShiftAPath() throws {
        // `Projects/Archive` goes while the columns are being read, so the
        // container column is one short and every name after it would be paired
        // with another mailbox's parent — `Projects` reading as
        // `R4-PROBE-Deep/Projects`, or the top-level `Archive` as a nested one.
        // The read is retried instead, and what comes back describes the
        // account as it is now.
        let payload = try scan(Self.bob, mailbox: "all", extra: Self.containerWindow)

        let byId = Dictionary(uniqueKeysWithValues: rows(payload).map { ($0.id, $0.mailbox) })
        XCTAssertNil(byId["10"], "Projects/Archive was deleted; its message should not be reported")
        XCTAssertEqual(byId["12"], "Archive")
        XCTAssertEqual(byId["11"], "R4-PROBE-Deep/Trash")
        XCTAssertEqual(byId["100"], "INBOX")
        XCTAssertFalse(
            (payload["scanned"] as? [String] ?? []).contains("Bob:R4-PROBE-Deep/Projects"),
            "a path was assembled out of two different mailboxes"
        )
    }
}
