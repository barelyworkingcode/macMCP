import XCTest
@testable import macmcp

/// The pure Swift half of `context/enumerate` (ADR-011 decision 6): the
/// account list's `On My Mac` fallback and the mailbox rows' account filter.
/// Neither needs Mail, a stub, or even `osascript` -- both are plain
/// `[data] -> [data]` functions, the "pure seam" pattern this file's tests
/// already use for `presentRows` and `sortNewestFirst`.
final class ContextEnumerationTests: XCTestCase {
    // MARK: - accountEnumerationEntries

    func testOnMyMacIsAppendedWhenMailDidNotListIt() {
        let entries = MailService.accountEnumerationEntries(fromNames: ["Alice", "Bob"])
        XCTAssertEqual(entries.map(\.value), ["Alice", "Bob", "On My Mac"])
        XCTAssertEqual(entries.map(\.label), ["Alice", "Bob", "On My Mac"])
    }

    func testOnMyMacIsNotDuplicatedIfMailAlreadyListedIt() {
        // Case-insensitively, like every other account comparison in this file.
        let entries = MailService.accountEnumerationEntries(fromNames: ["Alice", "on my mac"])
        XCTAssertEqual(entries.map(\.value), ["Alice", "on my mac"], "a second entry was appended")
    }

    func testEmptyAccountListStillYieldsOnMyMac() {
        // Zero real accounts is not "nothing to enumerate": On My Mac is
        // nameable whether or not Mail has a configured account at all.
        let entries = MailService.accountEnumerationEntries(fromNames: [])
        XCTAssertEqual(entries.map(\.value), ["On My Mac"])
    }

    // MARK: - mailboxEnumerationEntries

    private let rows: [[String: Any]] = [
        ["account": "Alice", "mailboxes": ["INBOX", "Projects/Archive"]],
        ["account": "Bob", "mailboxes": ["INBOX", "Archive"]],
        ["account": "On My Mac", "mailboxes": ["Notes"]]
    ]

    func testNilFilterReturnsEveryAccountsMailboxes() {
        let entries = MailService.mailboxEnumerationEntries(fromRows: rows, accountFilter: nil)
        XCTAssertEqual(entries.map(\.value), ["INBOX", "Projects/Archive", "INBOX", "Archive", "Notes"])
    }

    /// The wire contract's "absent or empty means all accounts" -- an empty
    /// array must not be read as "no account is wanted", which would silently
    /// turn a picker that has not yet been narrowed into one reporting no
    /// mailboxes anywhere.
    func testEmptyFilterReturnsEveryAccountsMailboxesTheSameAsNil() {
        let entries = MailService.mailboxEnumerationEntries(fromRows: rows, accountFilter: [])
        XCTAssertEqual(entries.map(\.value), ["INBOX", "Projects/Archive", "INBOX", "Archive", "Notes"])
    }

    func testFilterKeepsOnlyTheNamedAccounts() {
        let entries = MailService.mailboxEnumerationEntries(fromRows: rows, accountFilter: ["Bob"])
        XCTAssertEqual(entries.map(\.value), ["INBOX", "Archive"])
        XCTAssertEqual(entries.map(\.label), ["INBOX (Bob)", "Archive (Bob)"])
    }

    func testFilterMatchesCaseInsensitively() {
        let entries = MailService.mailboxEnumerationEntries(fromRows: rows, accountFilter: ["bob"])
        XCTAssertEqual(entries.map(\.value), ["INBOX", "Archive"])
    }

    func testFilterNamingOnMyMacReachesTheLocalRow() {
        let entries = MailService.mailboxEnumerationEntries(fromRows: rows, accountFilter: ["On My Mac"])
        XCTAssertEqual(entries.map(\.value), ["Notes"])
    }

    func testFilterMatchingNoAccountYieldsAnEmptyListNotAnError() {
        // Empty is a valid answer (the wire contract is explicit about this),
        // distinguished from a failed read by the tuple's `error` half, which
        // this pure function has none of to give -- the distinction is made
        // one level up, where the osascript result is read.
        let entries = MailService.mailboxEnumerationEntries(fromRows: rows, accountFilter: ["Carol"])
        XCTAssertTrue(entries.isEmpty, "a nonexistent account should filter to nothing, not fall back to everything: \(entries)")
    }

    func testRowMissingAnAccountKeyIsSkippedRatherThanCrashing() {
        let malformed: [[String: Any]] = [["mailboxes": ["INBOX"]]]
        XCTAssertTrue(MailService.mailboxEnumerationEntries(fromRows: malformed, accountFilter: nil).isEmpty)
    }
}
