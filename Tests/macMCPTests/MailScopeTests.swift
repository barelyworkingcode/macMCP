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
        XCTAssertNil(scope.fileDirs)
        XCTAssertEqual(scope.accountsAccess, .unscoped)
        XCTAssertEqual(scope.mailboxesAccess, .unscoped)
        XCTAssertEqual(scope.fileDirsAccess, .unscoped)
    }

    func testMetaPresentWithNoneOfTheThreeKeysIsGovernedAndRefuses() {
        // The correction ADR-011 decision 4 requires, and the opposite of what
        // the first cut of this type did. "A call is scoped if it carries one
        // of my restrict fields" has a hole in the fail-open direction: relay
        // failing to inject a field, for any reason, produces a call that
        // looks to macMCP exactly like an unmediated one, so the confinement
        // would rest entirely on relay's own call-time check having run.
        //
        // Relay injects `_meta.project_id` on EVERY mediated call and has
        // since ADR-007, so `_meta` present is a reliable signal that a
        // chokepoint mediated this one -- and a mediated call with no mail
        // scope in it has no mail resource it may reach.
        let scope = MailScope.parse(["project_id": .string("prof_123")])
        XCTAssertTrue(scope.isScoped)
        XCTAssertEqual(scope.accountsAccess, .refuse)
        XCTAssertEqual(scope.mailboxesAccess, .refuse)
        XCTAssertEqual(scope.fileDirsAccess, .refuse)
    }

    func testEmptyMetaObjectIsGovernedToo() {
        // `_meta: {}` is still `_meta`. Nothing about a chokepoint that
        // mediated the call and then wrote nothing into it makes it safer
        // than one that wrote a project id.
        let scope = MailScope.parse([:])
        XCTAssertTrue(scope.isScoped)
        XCTAssertEqual(scope.accountsAccess, .refuse)
    }

    func testOnlyAnAbsentMetaIsUnscoped() {
        // The one thing that means "nobody mediated this": an operator
        // running macmcp over stdio by hand, which is same-user local access
        // equivalent to opening Mail.app.
        XCTAssertFalse(MailScope.parse(nil).isScoped)
        XCTAssertTrue(MailScope.parse([:]).isScoped)
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
            "file_dirs": .array([.string("/tmp/project")])
        ])
        XCTAssertTrue(scope.isScoped)
        XCTAssertEqual(scope.accountsAccess, .allowed(["Bob"]))
        XCTAssertEqual(scope.mailboxesAccess, .allowed(["INBOX", "Archive"]))
        XCTAssertEqual(scope.fileDirsAccess, .allowed(["/tmp/project"]))
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
        // file_dirs is the only field a relay-derived local project always
        // gets (source: project_path); mail_accounts has no reason to be set
        // for a profile that never touches mail scope through the operator
        // surface. That must refuse mail_accounts-governed tools, not treat
        // the call as though no scope were in play.
        let scope = MailScope.parse(["file_dirs": .array([.string("/tmp/project")])])
        XCTAssertTrue(scope.isScoped)
        XCTAssertEqual(scope.fileDirsAccess, .allowed(["/tmp/project"]))
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

    // MARK: - The reconciliation rule: accounts

    private func scoped(_ meta: JSONObject) -> MailCall {
        MailCall.forArguments(nil, default: 30, meta: meta)
    }

    func testAnOmittedAccountResolvesToTheScopeAndNotToEverything() {
        // ADR-011 finding 4, and the whole of what `resolveTargets` was
        // getting wrong: an absent argument expanded to every configured
        // account plus the local pass, so "read Bob's INBOX" meant "read both
        // accounts and Mail's own mailboxes".
        let call = scoped(["mail_accounts": .array([.string("Bob")])])
        let (targets, failure) = MailService.resolveTargets(account: nil, call: call)
        XCTAssertNil(failure)
        XCTAssertEqual(targets.map { $0 ?? "<local>" }, ["Bob"])
    }

    func testAScopedExpansionSpendsNoAppleEvent() {
        // The allowed list *is* the answer, so `mail.accounts()` is never
        // read. Worth pinning because it is also what makes this test
        // hermetic: an unscoped expansion would spawn osascript against the
        // real Mail.app, which no test in this suite may do.
        let call = scoped(["mail_accounts": .array([.string("Bob"), .string("Alice")])])
        let (targets, failure) = MailService.resolveTargets(account: nil, call: call)
        XCTAssertNil(failure)
        XCTAssertEqual(targets.map { $0 ?? "<local>" }, ["Bob", "Alice"])
    }

    func testAnExplicitAccountInScopeIsTheOnlyTarget() {
        let call = scoped(["mail_accounts": .array([.string("Bob"), .string("Alice")])])
        let (targets, failure) = MailService.resolveTargets(account: "Alice", call: call)
        XCTAssertNil(failure)
        XCTAssertEqual(targets.map { $0 ?? "<local>" }, ["Alice"])
    }

    func testAnExplicitAccountOutOfScopeIsAnErrorAndNotASilentNarrowing() {
        // "Silent narrowing lets an agent build a false model of what it can
        // reach and burn calls discovering the truth" -- so this is an error,
        // marked, rather than Bob's mail returned under a request for Alice's
        // or an empty result that reads as "Alice has no mail".
        let call = scoped(["mail_accounts": .array([.string("Bob")])])
        let (targets, failure) = MailService.resolveTargets(account: "Alice", call: call)
        XCTAssertEqual(targets.count, 0)
        XCTAssertEqual(failure?.isError, true)
        XCTAssertEqual(failure?.meta?["scope_violation"], .bool(true))
        let text = failure?.content.first?.text ?? ""
        XCTAssertTrue(text.contains("\"Alice\" is outside"), text)
        XCTAssertTrue(text.contains("Bob"), "the refusal names what would have worked: \(text)")
    }

    func testOnMyMacIsNameableInAScopeAndMeansTheLocalPass() {
        // It is an account name every mail tool accepts (#54): the scan labels
        // those rows with it and `mail_list_mailboxes` lists it, so relay must
        // be able to scope it -- and naming something that then cannot be
        // asked for is worse than not naming it.
        let call = scoped(["mail_accounts": .array([.string("On My Mac")])])
        let (targets, failure) = MailService.resolveTargets(account: nil, call: call)
        XCTAssertNil(failure)
        XCTAssertEqual(targets.count, 1)
        XCTAssertNil(targets[0], "nil is the local pass")
    }

    func testAScopeThatDoesNotNameOnMyMacDoesNotReachIt() {
        let call = scoped(["mail_accounts": .array([.string("Bob")])])
        let (targets, _) = MailService.resolveTargets(account: nil, call: call)
        XCTAssertFalse(targets.contains(where: { $0 == nil }))
        let (_, failure) = MailService.resolveTargets(account: "On My Mac", call: call)
        XCTAssertEqual(failure?.meta?["scope_violation"], .bool(true))
    }

    func testAMediatedCallWithNoAccountScopeReachesNoAccount() {
        // Decision 4, end to end through the seam: `_meta` present, no
        // `mail_accounts` in it, so there is nothing this call may read and
        // saying so is the answer. Never "every account".
        let call = scoped(["project_id": .string("prof_1")])
        let (targets, failure) = MailService.resolveTargets(account: nil, call: call)
        XCTAssertEqual(targets.count, 0)
        XCTAssertEqual(failure?.meta?["scope_violation"], .bool(true))
        XCTAssertTrue((failure?.content.first?.text ?? "").contains("mail_accounts"))
    }

    func testAnUnscopedResolveWithAnExplicitAccountIsUnchanged() {
        let (targets, failure) = MailService.resolveTargets(account: "Alice")
        XCTAssertNil(failure)
        XCTAssertEqual(targets.map { $0 ?? "<local>" }, ["Alice"])
    }

    // MARK: - The reconciliation rule: mailboxes

    func testTheWildcardResolvesToTheScopeRatherThanErroring() {
        let scope = MailScope.parse(["mail_mailboxes": .array([.string("INBOX")])])
        XCTAssertEqual(scope.mailboxTargets(requested: "all"), .use(["INBOX"]))
        XCTAssertEqual(scope.mailboxTargets(requested: "ALL"), .use(["INBOX"]))
        XCTAssertEqual(scope.mailboxTargets(requested: nil), .use(["INBOX"]))
    }

    func testAnExplicitMailboxOutOfScopeIsARefusal() {
        let scope = MailScope.parse(["mail_mailboxes": .array([.string("INBOX")])])
        guard case .refuse(let message) = scope.mailboxTargets(requested: "Archive") else {
            return XCTFail("an explicit out-of-scope mailbox must be an error")
        }
        XCTAssertTrue(message.contains("\"Archive\" is outside"), message)
    }

    func testALeafNameOfAnAllowedPathIsAccepted() {
        // The scope value is a full path (`Projects/Archive`), which is what
        // `mail_list_mailboxes` returns; a caller may still write the leaf
        // name, which every mailbox argument here resolves as a fallback. The
        // intersection with what Mail actually holds happens inside the scan,
        // against paths read off Mail rather than against strings.
        let scope = MailScope.parse(["mail_mailboxes": .array([.string("Projects/Archive")])])
        XCTAssertEqual(scope.mailboxTargets(requested: "Archive"), .use(["Projects/Archive"]))
        XCTAssertEqual(scope.mailboxTargets(requested: "projects/archive"), .use(["Projects/Archive"]))
        guard case .refuse = scope.mailboxTargets(requested: "Sub") else {
            return XCTFail("a leaf name nothing in scope carries is still out of scope")
        }
    }

    func testAToolsOwnDefaultResolvesToTheScopeToo() {
        // `mail_get_emails` defaults `mailbox` to INBOX. A default is not a
        // choice the caller made, so under a scope of `Archive` the default
        // call must read Archive rather than answer with an empty INBOX that
        // reads as "there is nothing there".
        let call = scoped(["mail_mailboxes": .array([.string("Archive")])])
        XCTAssertEqual(MailService.scopedMailboxArgument(nil, default: "INBOX", call: call), "all")
        XCTAssertEqual(MailService.scopedMailboxArgument("Archive", default: "INBOX", call: call), "Archive")
        // Unscoped, the tool's default is exactly what it always was.
        XCTAssertEqual(
            MailService.scopedMailboxArgument(nil, default: "INBOX", call: MailCall(budget: 30) { .granted }),
            "INBOX"
        )
    }

    func testTheByIdToolsRefuseAnExplicitArgumentOutOfScope() {
        // For those tools `account` and `mailbox` are only hints -- a numeric
        // id resolves globally and the real check is post-hoc off the message
        // -- but an explicit argument outside the scope still has to be an
        // error, or `mail_get_email {account: "Alice"}` answers "message not
        // found", which is a sentence about the message rather than about the
        // boundary.
        let call = scoped([
            "mail_accounts": .array([.string("Bob")]),
            "mail_mailboxes": .array([.string("INBOX")])
        ])
        XCTAssertNil(MailService.scopeRefusal(for: MCPCallContext(arguments: ["message_id": .int(1)], toolName: "mail_get_email"), call: call))
        XCTAssertNil(MailService.scopeRefusal(for: MCPCallContext(arguments: ["account": .string("Bob")], toolName: "mail_get_email"), call: call))
        XCTAssertEqual(
            MailService.scopeRefusal(for: MCPCallContext(arguments: ["account": .string("Alice")], toolName: "mail_get_email"), call: call)?
                .meta?["scope_violation"],
            .bool(true)
        )
        XCTAssertEqual(
            MailService.scopeRefusal(for: MCPCallContext(arguments: ["mailbox": .string("Archive")], toolName: "mail_get_email"), call: call)?
                .meta?["scope_violation"],
            .bool(true)
        )
        // mail_move writes its two ends under different names, and both are
        // checked.
        XCTAssertEqual(
            MailService.scopeRefusal(
                for: MCPCallContext(arguments: ["target_mailbox": .string("Archive")], toolName: "mail_move"),
                call: call,
                accountKeys: ["account", "target_account"],
                mailboxKeys: ["source_mailbox", "target_mailbox"]
            )?.meta?["scope_violation"],
            .bool(true)
        )
    }

    func testAScopeThatReachesNoMailboxIsSaidSoRatherThanCountedAsZero() {
        // `all` resolves to the scope, so a scope naming a mailbox Mail does
        // not hold intersects with nothing -- and the caller would be handed
        // `total_messages: 0` with `scan_complete: true`, which is an
        // affirmative claim that the mailboxes it may read are empty. Same
        // shape as "a scan that read nothing is an error, not an empty
        // result", arriving by a different route.
        // Nothing was scanned because nothing intersected: `scanned` names the
        // mailboxes whose columns were actually fetched.
        let outcome = MailService.ScanOutcome()
        let scope = MailScope.parse(["mail_mailboxes": .array([.string("Inbocks")])])
        let result = MailService.scanFailure(outcome, targets: ["Bob"], mailbox: "all", scope: scope)
        XCTAssertEqual(result?.isError, true)
        let text = result?.content.first?.text ?? ""
        XCTAssertTrue(text.contains("Inbocks"), text)
        // Not a scope violation: nothing reached outside the boundary. The
        // boundary itself names something that is not there, which is an
        // operator's typo rather than a client probing, and marking it would
        // put a misconfiguration into relay's violation alerting.
        XCTAssertNil(result?.meta)
    }

    func testAScopeThatDoesReachAMailboxIsAllowedToFindItEmpty() {
        var outcome = MailService.ScanOutcome()
        outcome.scanned = ["Bob:INBOX"]
        outcome.matchedMailbox = true
        let scope = MailScope.parse(["mail_mailboxes": .array([.string("INBOX")])])
        XCTAssertNil(MailService.scanFailure(outcome, targets: ["Bob"], mailbox: "all", scope: scope))
    }

    // MARK: - file_dirs

    func testFileDirsUnscopedIsTodaysBehaviour() {
        XCTAssertEqual(MailScope.none.writeDestination("/tmp/anything"), .unscoped)
    }

    func testAMediatedCallWithNoFileDirsMayNotWriteAtAll() {
        // ADR-011 finding 1, the escalation one: `mail_save_attachment` takes
        // a required absolute `destination`, so a mail-only remote client held
        // a filesystem write on the host -- `~/.zshrc`,
        // `~/Library/LaunchAgents/*.plist` -- from inside a grant whose whole
        // premise was that it never touches the host filesystem. `file_dirs`
        // is `source: "project_path"` and an access profile has no path, so it
        // gets no value and the tool is unusable to one by construction.
        let scope = MailScope.parse(["mail_accounts": .array([.string("Bob")])])
        guard case .refuse(let message) = scope.writeDestination("/tmp/x") else {
            return XCTFail("absent file_dirs must refuse, not mean anywhere")
        }
        XCTAssertTrue(message.contains("may not write files"), message)
    }

    func testAnEmptyFileDirsListIsARefusalAndNotNoRestriction() {
        // fsMCP's `if (allowedDirs.length === 0) return null; // no
        // restrictions` (finding 8) is the shape this must never grow.
        guard case .refuse = MailScope.parse(["file_dirs": .array([])]).writeDestination("/etc/passwd") else {
            return XCTFail("an empty list grants nothing")
        }
    }

    func testAPathInsideAnAllowedDirectoryIsAccepted() throws {
        let root = try temporaryDirectory()
        let scope = MailScope.parse(["file_dirs": .array([.string(root.path)])])
        XCTAssertEqual(scope.writeDestination(root.path), .use(root.path))
        let inside = root.appendingPathComponent("sub/file.pdf").path
        XCTAssertEqual(scope.writeDestination(inside), .use(inside))
    }

    func testASiblingWithTheSamePrefixIsNotInside() throws {
        // The trailing-separator rule: `/foo` must not match `/foobar`.
        let root = try temporaryDirectory()
        let scope = MailScope.parse(["file_dirs": .array([.string(root.path)])])
        guard case .refuse = scope.writeDestination(root.path + "bar/file.txt") else {
            return XCTFail("/foo must not admit /foobar")
        }
    }

    func testDotDotCannotClimbOut() throws {
        let root = try temporaryDirectory()
        let scope = MailScope.parse(["file_dirs": .array([.string(root.path)])])
        guard case .refuse = scope.writeDestination(root.path + "/../escaped.txt") else {
            return XCTFail("`..` must be resolved before the comparison, not after")
        }
    }

    func testASymlinkPointingOutIsResolvedBeforeComparing() throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        let link = root.appendingPathComponent("way-out")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let scope = MailScope.parse(["file_dirs": .array([.string(root.path)])])
        guard case .refuse = scope.writeDestination(link.appendingPathComponent("f.txt").path) else {
            return XCTFail("a symlink out of the allowed directory is out of it")
        }
    }

    func testARelativePathIsRefusedRatherThanResolvedAgainstWhateverCwdIs() {
        let scope = MailScope.parse(["file_dirs": .array([.string("/tmp")])])
        guard case .refuse(let message) = scope.writeDestination("notes.txt") else {
            return XCTFail("a relative path has no meaning to a caller on another machine")
        }
        XCTAssertTrue(message.contains("must be absolute"), message)
    }

    private func temporaryDirectory() throws -> URL {
        // `resolvingSymlinksInPath` because /tmp is itself a symlink to
        // /private/tmp on macOS -- which is exactly the case the comparison
        // has to get right, and exactly the case a test can accidentally
        // assert its way around.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macmcp-scope-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - The marker relay reads

    func testTheScopeViolationMarkerRidesOnTheResultsMeta() throws {
        // ADR-011 decision 7: not a new outcome -- relay is relaying the MCP's
        // answer rather than making a decision of its own -- but a structured
        // marker, so alerting has a signal that does not depend on anyone
        // parsing the sentence.
        let result = scopeViolationResult("nope")
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(result.meta?["scope_violation"], .bool(true))

        // The wire key is `_meta`, a sibling of content and isError.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(data: try encoder.encode(result), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"_meta\":{\"scope_violation\":true}"), json)
        XCTAssertFalse(json.contains("\"meta\":"), json)
    }

    func testAnOrdinaryErrorCarriesNoMetaAtAll() {
        // Absent rather than `false`, so a relay that does not read it sees
        // exactly what it saw before, and one that does can tell "not a scope
        // violation" from "this server does not report them".
        XCTAssertNil(errorResult("something went wrong").meta)
        XCTAssertNil(textResult("fine").meta)
    }

    func testTheSentinelSurvivesARoundTripAndIsInvisibleAfterwards() {
        // How a refusal raised inside generated JavaScript says what it is:
        // the script marks the sentence, `mailError` takes the mark off and
        // sets the field instead, so nothing downstream ever parses prose.
        let marked = MailScopeRefusal.mark("the destination is outside...")
        XCTAssertTrue(marked.hasPrefix(MailScopeRefusal.sentinel))
        let split = MailScopeRefusal.split(marked)
        XCTAssertTrue(split.violation)
        XCTAssertEqual(split.message, "the destination is outside...")
        // Anything that never carried one comes through byte-identical, which
        // is every message written before this existed.
        let untouched = MailScopeRefusal.split("account not found: Zed")
        XCTAssertFalse(untouched.violation)
        XCTAssertEqual(untouched.message, "account not found: Zed")
    }

    // MARK: - A held source belongs to the scope that fetched it

    func testTheSourceCacheKeyIncludesTheConfinement() {
        // A cache hit returns bytes without running a script, and the script
        // is where the scope is checked -- so two callers with different
        // scopes reaching one macmcp process must not share an entry, or the
        // second is served a message the first was entitled to and it is not.
        let bob = MailScope.parse(["mail_accounts": .array([.string("Bob")])])
        let alice = MailScope.parse(["mail_accounts": .array([.string("Alice")])])
        XCTAssertNotEqual(
            MailService.sourceCacheKey(account: nil, mailbox: "INBOX", messageId: "1", scope: bob),
            MailService.sourceCacheKey(account: nil, mailbox: "INBOX", messageId: "1", scope: alice)
        )
        XCTAssertNotEqual(
            MailService.sourceCacheKey(account: nil, mailbox: "INBOX", messageId: "1", scope: bob),
            MailService.sourceCacheKey(account: nil, mailbox: "INBOX", messageId: "1")
        )
        // The same confinement is the same key, however the list was written.
        XCTAssertEqual(
            MailService.sourceCacheKey(account: nil, mailbox: "INBOX", messageId: "1", scope: bob),
            MailService.sourceCacheKey(
                account: nil, mailbox: "INBOX", messageId: "1",
                scope: MailScope.parse(["mail_accounts": .array([.string("bob")])])
            )
        )
    }
}
