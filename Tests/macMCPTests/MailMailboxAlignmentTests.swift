import XCTest
@testable import macmcp

/// Cover for `boundByName` pairing a name read in one Apple Event with an
/// element read in another.
///
/// `boundByName(collection)` calls `collection.name()` — one bulk Apple Event,
/// giving the names — and then, lazily, `collection()` — a second one, giving
/// the elements. It walks the two in lockstep by index and never checks that
/// they describe the same collection. That is precisely the guard the message
/// scan applies one level down: it re-reads the id column and requires it to
/// come back identical before it will pair an id with a subject.
///
/// The window is not small. Measured on Bob's 25 mailboxes it is ~400ms, most
/// of it the `exists()` probes `boundByName` makes *between* the two fetches. A
/// mailbox created, deleted or re-filed in that window shifts every element
/// after it by one, and the name a shifted element is stamped with is the name
/// every scanned row then carries: `"mailbox": "Archive"` on ids that came out
/// of INBOX. The id/subject pairing is guarded; the id/mailbox pairing is not.
///
/// The unique names are not exposed, because a unique name is bound with
/// `collection.byName(...)`, which re-resolves and cannot be shifted. What is
/// exposed is exactly what Mail's flattened mailbox tree produces: a repeated
/// leaf name, which falls through to the positional binding, and a name whose
/// `byName` specifier does not resolve, which falls through the same way.
///
/// The stub's own mailbox array is mutated between the two fetches by wrapping
/// the collection, which is the mailbox-level equivalent of what
/// `MailScanAlignmentTests` does to a message collection.
final class MailMailboxAlignmentTests: XCTestCase {
    /// Bob with two mailboxes called `Archive` — the fixture's
    /// `Projects/Archive` and its top-level `Archive` — plus an extra account
    /// whose mailbox is spliced in as "created while the scan was reading".
    ///
    /// Every mailbox holds a message with an id that names it, so a row can be
    /// checked against where it really came from rather than against the label
    /// the scan gave it.
    private static let account = """
    var mail = makeMail({accounts: [
        {name: 'Bob', mailboxes: [
            {name: 'Archive',  messages: [{id: 10, subject: 'in Projects/Archive', date: 1000}]},
            {name: 'Projects', messages: [{id: 11, subject: 'in Projects', date: 1100}]},
            {name: 'Archive',  messages: [{id: 12, subject: 'in top-level Archive', date: 1200}]},
            {name: 'INBOX',    messages: [{id: 13, subject: 'in INBOX', date: 1300}]}
        ]},
        {name: 'Spare', mailboxes: [
            {name: 'Newsletters', messages: [{id: 99, subject: 'in a mailbox created mid-scan', date: 1400}]}
        ]}
    ]});
    var bob = mail.accounts()[0];
    var live = bob.mailboxes();
    var newlyCreated = mail.accounts()[1].mailboxes()[0];
    """

    /// Wraps Bob's mailbox collection so that `mutate` runs after `name()` has
    /// answered and before `collection()` is called — the window `boundByName`
    /// holds open while it probes `exists()`.
    private static func window(_ mutate: String) -> String {
        """
        (function() {
            var original = bob.mailboxes;
            var wrapped = function() { return original(); };
            Object.defineProperty(wrapped, 'name', {
                value: function() {
                    var names = original.name();
                    \(mutate)
                    return names;
                },
                writable: true, configurable: true
            });
            wrapped.byName = function(n) { return original.byName(n); };
            bob.mailboxes = wrapped;
        })();
        """
    }

    private func scan(mutate: String, mailbox: String) throws -> [String: Any] {
        try JXA.runJSON("""
        \(MailStubJS.source)
        \(Self.account)
        \(Self.window(mutate))
        \(MailService.scanScriptJXA(
            account: "Bob",
            mailbox: mailbox,
            query: nil,
            searchRecipients: false,
            limit: 20
        ))
        """)
    }

    /// The ids that really live in a mailbox called `Archive`.
    private static let archiveIds: Set<String> = ["10", "12"]

    private func ids(_ payload: [String: Any]) -> [String] {
        (payload["rows"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    // MARK: - The defect

    func testEveryRowComesFromTheMailboxItIsStampedWith() throws {
        // A mailbox is created after Mail answered with the names, so
        // `collection()` returns one more element than there are names and
        // everything from index 0 on is bound to the previous mailbox's name.
        // The two `Archive` entries then point at the new mailbox and at
        // `Projects`, and their rows come back stamped `Bob:Archive`.
        let payload = try scan(mutate: "live.splice(0, 0, newlyCreated);", mailbox: "Archive")

        for id in ids(payload) {
            XCTAssertTrue(
                Self.archiveIds.contains(id),
                "id \(id) is not in any mailbox called Archive, but was returned stamped as one"
            )
        }
    }

    func testNoRowIsStampedWithTheNameOfAMailboxItDidNotComeFrom() throws {
        // The other direction: a mailbox is deleted in the window, so
        // `collection()` is one short and every element after it slides back by
        // one. `Projects` goes, so the second `Archive` binds to `INBOX` — the
        // shape measured on the fixture, rows carrying `"mailbox": "Archive"`
        // whose ids came from INBOX.
        let payload = try scan(mutate: "live.splice(1, 1);", mailbox: "Archive")

        for id in ids(payload) {
            XCTAssertTrue(
                Self.archiveIds.contains(id),
                "id \(id) is not in any mailbox called Archive, but was returned stamped as one"
            )
        }
    }

    func testAMailboxThatWasNamedAndThenCouldNotBeBoundIsReported() throws {
        // A mailbox list that never settles: one more mailbox is spliced in on
        // every read, so no two reads of it agree and nothing in it can be
        // paired with anything else.
        //
        // The old code had no opinion about that — it read the names once, the
        // elements once, and walked the two by index, so a name whose element
        // had slid out from under it got `positional(i) === null` and the entry
        // was dropped on the floor: the mailbox appeared in neither `scanned`
        // nor `skipped`, and `scan_complete` stayed true. A short answer
        // presented as a complete one, which is the shape #57 fixed for the
        // message scan.
        //
        // What has to hold is that every mailbox the scan was asked for is
        // accounted for somewhere. Being unreadable is a fine answer; vanishing
        // is not.
        let payload = try scan(mutate: "live.splice(1, 0, newlyCreated);", mailbox: "Archive")

        let scanned = payload["scanned"] as? [String] ?? []
        let skipped = payload["skipped"] as? [String] ?? []
        XCTAssertTrue(
            scanned.isEmpty,
            "no mailbox held still long enough to be read, so none should be reported as scanned: \(scanned)"
        )
        XCTAssertGreaterThanOrEqual(
            skipped.count, 2,
            "Bob has two mailboxes called Archive; they left the result without being reported (scanned: \(scanned), skipped: \(skipped))"
        )
        XCTAssertEqual(
            (payload["rows"] as? [[String: Any]] ?? []).count, 0,
            "rows came out of a mailbox list that could not be read"
        )
    }

    // MARK: - The control, which passes today

    func testASettledAccountPairsEveryNameWithItsOwnMailbox() throws {
        let payload = try scan(mutate: "", mailbox: "Archive")
        XCTAssertEqual(ids(payload).sorted(), ["10", "12"])
        XCTAssertEqual(payload["scanned"] as? [String] ?? [], ["Bob:Archive", "Bob:Archive"])
        XCTAssertEqual(payload["total"] as? Int, 2)
    }
}
