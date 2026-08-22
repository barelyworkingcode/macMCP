import Foundation
import XCTest
@testable import macmcp

/// `MailScope` is plumbing for ADR-011's resource-scope mechanism: it parses
/// `_meta` into a value a later change can enforce against, and enforces
/// nothing itself. What has to be right here is the representation --
/// decision 4 ("Absent and empty are refusals, on all three sides") depends
/// on three states staying distinguishable:
///
///   1. no scope in play at all (unscoped: behave exactly as today)
///   2. a scope in play, but this field absent/empty (refuse)
///   3. a scope in play, with a list of what is allowed
///
/// and on state 1 never being confused with state 2 just because a field
/// happens to read `nil` in both.
final class MailScopeTests: XCTestCase {
    // MARK: - No scope in play at all

    func testNoMetaAtAllIsUnscoped() {
        let scope = MailScope.parse(nil)
        XCTAssertEqual(scope, .none)
        XCTAssertFalse(scope.isScoped)
        XCTAssertNil(scope.mailAccounts)
        XCTAssertNil(scope.mailMailboxes)
        XCTAssertNil(scope.writeDirs)
        XCTAssertEqual(scope.accountsAccess, .unscoped)
        XCTAssertEqual(scope.mailboxesAccess, .unscoped)
        XCTAssertEqual(scope.writeDirsAccess, .unscoped)
    }

    func testMetaPresentWithNoneOfTheThreeKeysIsStillUnscoped() {
        // Every relay-mediated call carries `_meta.project_id` (ADR-007) even
        // when the calling profile declares no mail resource scope at all.
        // `_meta` being present must not, by itself, make a call look scoped.
        let scope = MailScope.parse(["project_id": .string("prof_123")])
        XCTAssertFalse(scope.isScoped)
        XCTAssertEqual(scope.accountsAccess, .unscoped)
        XCTAssertEqual(scope.mailboxesAccess, .unscoped)
        XCTAssertEqual(scope.writeDirsAccess, .unscoped)
    }

    func testEmptyMetaObjectIsUnscoped() {
        let scope = MailScope.parse([:])
        XCTAssertFalse(scope.isScoped)
    }

    // MARK: - Scoped, with values

    func testAPresentFieldWithValuesIsAllowed() {
        let scope = MailScope.parse(["mail_accounts": .array([.string("Bob")])])
        XCTAssertTrue(scope.isScoped)
        XCTAssertEqual(scope.mailAccounts, ["Bob"])
        XCTAssertEqual(scope.accountsAccess, .allowed(["Bob"]))
    }

    func testAllThreeFieldsParseTogether() {
        let scope = MailScope.parse([
            "mail_accounts": .array([.string("Bob")]),
            "mail_mailboxes": .array([.string("INBOX"), .string("Archive")]),
            "write_dirs": .array([.string("/tmp/project")])
        ])
        XCTAssertTrue(scope.isScoped)
        XCTAssertEqual(scope.accountsAccess, .allowed(["Bob"]))
        XCTAssertEqual(scope.mailboxesAccess, .allowed(["INBOX", "Archive"]))
        XCTAssertEqual(scope.writeDirsAccess, .allowed(["/tmp/project"]))
    }

    // MARK: - Scoped, but this field refuses

    func testAPresentEmptyArrayIsARefusalDistinctFromAbsent() {
        let scope = MailScope.parse(["mail_accounts": .array([])])
        XCTAssertTrue(scope.isScoped, "the key was present, so this call is scoped")
        // Present-but-empty is a distinct fact from absent...
        XCTAssertEqual(scope.mailAccounts, [])
        XCTAssertNotEqual(scope.mailAccounts, nil as [String]?)
        // ...but decision 4 requires both to refuse identically.
        XCTAssertEqual(scope.accountsAccess, .refuse)
    }

    func testAFieldAbsentFromAScopedMetaRefusesRatherThanFallingBackToUnrestricted() {
        // write_dirs is the only field a relay-derived local project always
        // gets (source: project_path); mail_accounts has no reason to be set
        // for a profile that never touches mail scope through the operator
        // surface. That must refuse mail_accounts-governed tools, not treat
        // the call as though no scope were in play.
        let scope = MailScope.parse(["write_dirs": .array([.string("/tmp/project")])])
        XCTAssertTrue(scope.isScoped)
        XCTAssertEqual(scope.writeDirsAccess, .allowed(["/tmp/project"]))
        XCTAssertEqual(scope.accountsAccess, .refuse)
        XCTAssertEqual(scope.mailboxesAccess, .refuse)
    }

    func testAMalformedFieldFailsClosedRatherThanReadingAsUnscoped() {
        // mail_accounts present as the wrong shape (not a string or an array
        // of strings) parses to nil, same as absent -- but the key WAS
        // present, so isScoped must stay true and the field must refuse, not
        // silently present as "no scope in play" just because parsing failed.
        let scope = MailScope.parse(["mail_accounts": .int(5)])
        XCTAssertTrue(scope.isScoped)
        XCTAssertNil(scope.mailAccounts)
        XCTAssertEqual(scope.accountsAccess, .refuse)
    }

    func testAnExplicitJSONNullStillCountsAsPresent() {
        let scope = MailScope.parse(["mail_mailboxes": .null])
        XCTAssertTrue(scope.isScoped)
        XCTAssertNil(scope.mailMailboxes)
        XCTAssertEqual(scope.mailboxesAccess, .refuse)
    }

    // MARK: - MailCall carries the parsed scope

    func testMailCallDefaultsToNoScope() {
        // Every existing call site and every existing test constructs a
        // MailCall with no scope; this must keep meaning exactly what it
        // always meant.
        let call = MailCall(budget: 30) { .granted }
        XCTAssertEqual(call.scope, .none)
    }

    func testForArgumentsParsesMetaIntoTheCallsScope() {
        let call = MailCall.forArguments(
            ["timeout_seconds": .int(10)],
            default: 30,
            meta: ["mail_accounts": .array([.string("Alice")])]
        )
        XCTAssertTrue(call.scope.isScoped)
        XCTAssertEqual(call.scope.accountsAccess, .allowed(["Alice"]))
    }

    func testForArgumentsWithNoMetaKeepsTodaysBehaviour() {
        let call = MailCall.forArguments(["timeout_seconds": .int(10)], default: 30)
        XCTAssertEqual(call.scope, .none)
        XCTAssertFalse(call.scope.isScoped)
    }
}
