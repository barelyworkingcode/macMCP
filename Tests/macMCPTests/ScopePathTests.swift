import XCTest
@testable import macmcp

/// The pure seam every `context/enumerate` answer for calendars, reminder
/// lists and contact groups is built out of: rows of (container, leaf) in,
/// picker entries out.
///
/// EventKit and Contacts cannot be driven from a hermetic test -- there is no
/// stub store, and touching the real one reads the user's own data -- so the
/// framework read and the shaping are deliberately separate: `calendarRows`,
/// `listRows` and `groupRows` do nothing but read, and everything that can be
/// wrong about *what an operator is shown* is here.
final class ScopePathTests: XCTestCase {
    private let rows: [ScopePath.Row] = [
        .init(container: "iCloud", leaf: "Work"),
        .init(container: "iCloud", leaf: "Home"),
        .init(container: "On My Mac", leaf: "Work"),
        .init(container: "Exchange", leaf: "Team")
    ]

    // MARK: - The value is a path, because a leaf name is not an identity

    /// The bug this representation exists to prevent: `EKCalendar.title` is
    /// not unique, and `CalendarService` matches with `$0.title == name`,
    /// which returns *both* "Work" calendars. A scope value of `Work` would
    /// be a permission that silently granted two.
    func testTwoContainersHoldingOneLeafNameStayTwoValues() {
        let entries = ScopePath.entries(fromRows: rows, containerFilter: nil)
        XCTAssertEqual(entries.map(\.value), ["iCloud/Work", "iCloud/Home", "On My Mac/Work", "Exchange/Team"])
    }

    /// `value` goes into `_meta` verbatim; `label` is display only.
    func testTheLabelIsReadableAndTheValueIsThePath() {
        let entries = ScopePath.entries(fromRows: rows, containerFilter: ["Exchange"])
        XCTAssertEqual(entries.map(\.value), ["Exchange/Team"])
        XCTAssertEqual(entries.map(\.label), ["Team (Exchange)"])
    }

    /// A `/` cannot occur inside a Mail mailbox leaf name -- creating `a/b`
    /// creates `b` inside `a` -- but a calendar title or a group name has no
    /// such rule. The path is therefore matched **whole** and never split, so
    /// a slash in a name is just a character in a value.
    func testASlashInALeafNameIsCarriedRatherThanTakenAsStructure() {
        let entries = ScopePath.entries(
            fromRows: [.init(container: "iCloud", leaf: "Q1/Q2 planning")],
            containerFilter: nil
        )
        XCTAssertEqual(entries.map(\.value), ["iCloud/Q1/Q2 planning"])
        XCTAssertEqual(entries.map(\.label), ["Q1/Q2 planning (iCloud)"])
    }

    // MARK: - An empty filter means ALL, never none

    /// `depends_on`'s picker is opened before its dependency has been chosen
    /// -- that is its normal initial state -- so an empty-but-present filter
    /// must mean "across everything". Reading it as "match nothing" shows an
    /// operator zero calendars at exactly the moment they are trying to choose
    /// one, and is indistinguishable from a Mac that holds none. macMCP got
    /// this wrong once already during the mail work.
    func testAnEmptyFilterMeansEverythingExactlyAsAnAbsentOneDoes() {
        let all = ScopePath.entries(fromRows: rows, containerFilter: nil).map(\.value)
        XCTAssertEqual(ScopePath.entries(fromRows: rows, containerFilter: []).map(\.value), all)
        XCTAssertEqual(all.count, 4)
    }

    func testAFilterKeepsOnlyTheNamedContainers() {
        XCTAssertEqual(
            ScopePath.entries(fromRows: rows, containerFilter: ["iCloud"]).map(\.value),
            ["iCloud/Work", "iCloud/Home"]
        )
    }

    /// Matched under `fold` -- the one spelling every scope comparison is made
    /// in -- so a container an operator typed in another case still reaches
    /// its rows, and an accented name is not two names.
    func testTheFilterMatchesUnderTheSameFoldEverythingElseUses() {
        XCTAssertEqual(
            ScopePath.entries(fromRows: rows, containerFilter: ["icloud"]).map(\.value),
            ["iCloud/Work", "iCloud/Home"]
        )
        // Decomposed on the row, precomposed in the filter. Swift's `==`
        // would call these equal anyway; `fold` is what makes the same
        // comparison hold on the JavaScript side of a mail scope, and using
        // one rule everywhere is what stops an operator's picked value from
        // matching here and failing there.
        let accented: [ScopePath.Row] = [.init(container: "Re\u{0301}union", leaf: "Planning")]
        XCTAssertEqual(
            ScopePath.entries(fromRows: accented, containerFilter: ["R\u{00E9}union"]).map(\.value),
            ["Re\u{0301}union/Planning"],
            "the value returned is the container's own spelling, matched under fold"
        )
    }

    /// A container nobody has filters to nothing -- an empty list is a valid
    /// answer meaning "there are none" -- rather than falling back to
    /// everything, which would be a picker widening a grant on a typo.
    func testAFilterMatchingNoContainerYieldsAnEmptyListRatherThanEverything() {
        XCTAssertTrue(ScopePath.entries(fromRows: rows, containerFilter: ["Nowhere"]).isEmpty)
    }

    // MARK: - Containers

    func testContainerEntriesAreDistinctAndInFirstSeenOrder() {
        XCTAssertEqual(
            ScopePath.containerEntries(fromRows: rows).map(\.value),
            ["iCloud", "On My Mac", "Exchange"]
        )
        XCTAssertEqual(ScopePath.containerEntries(fromRows: rows).map(\.label), ["iCloud", "On My Mac", "Exchange"])
    }

    func testNoRowsIsAnEmptyListAndNotACrash() {
        XCTAssertTrue(ScopePath.containerEntries(fromRows: []).isEmpty)
        XCTAssertTrue(ScopePath.entries(fromRows: [], containerFilter: ["iCloud"]).isEmpty)
    }

    // MARK: - Ambiguity is detected rather than hidden

    /// Two resources that really do share a container and a name are
    /// indistinguishable *by this representation*. Offering the same string
    /// twice would suggest a choice the value cannot express, so the picker
    /// shows it once -- and `ambiguousValues` is what phase 2's resolution
    /// refuses on, the way `mail_move` refuses two mailboxes carrying one
    /// name rather than filing into whichever came first.
    func testADuplicatePathIsOfferedOnceAndReportedAsAmbiguous() {
        let duplicated: [ScopePath.Row] = [
            .init(container: "iCloud", leaf: "Work"),
            .init(container: "iCloud", leaf: "Work"),
            .init(container: "iCloud", leaf: "Home")
        ]
        XCTAssertEqual(
            ScopePath.entries(fromRows: duplicated, containerFilter: nil).map(\.value),
            ["iCloud/Work", "iCloud/Home"]
        )
        XCTAssertEqual(ScopePath.ambiguousValues(in: duplicated), ["iCloud/Work"])
    }

    func testAnUnambiguousSetReportsNothing() {
        XCTAssertTrue(ScopePath.ambiguousValues(in: rows).isEmpty)
    }

    /// The residual hazard of a `/` in a name: two different (container, leaf)
    /// pairs can generate one string. It is reported on exactly the same
    /// footing as two resources genuinely sharing a name, which is the point
    /// of detecting it on the generated value rather than on the pair.
    func testTwoDifferentPairsGeneratingOneStringAreReportedAsAmbiguous() {
        let colliding: [ScopePath.Row] = [
            .init(container: "a", leaf: "b/c"),
            .init(container: "a/b", leaf: "c")
        ]
        XCTAssertEqual(ScopePath.ambiguousValues(in: colliding), ["a/b/c"])
        XCTAssertEqual(ScopePath.entries(fromRows: colliding, containerFilter: nil).count, 1)
    }
}
