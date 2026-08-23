import Foundation
import XCTest
@testable import macmcp

/// The holes an adversarial pass found in the shipped enforcement, each pinned
/// by the shape that produced it.
///
/// Every one of them is a place macMCP failed **open** on its own and was
/// saved only by relay's `checkScopePresence` having run first. ADR-011
/// decision 4's whole argument is that macMCP's test must be independent of
/// relay's -- "one check, not two" -- so a hole relay happens to cover is
/// still a hole, and the tests below deliberately exercise macMCP alone.
final class MailScopeHardeningTests: XCTestCase {
    private func scoped(_ meta: JSONObject) -> MailCall {
        MailCall(budget: 30, scope: MailScope.parse(meta))
    }

    private static let bobInboxScope: JSONObject = [
        "mail_accounts": .array([.string("Bob")]),
        "mail_mailboxes": .array([.string("INBOX")])
    ]

    // MARK: - A1: attachments are a read off this host, and were scoped by nothing

    /// `mail_send` and `mail_create_draft` take `attachments: [absolute POSIX
    /// paths]`, macMCP opens each one and its bytes leave the machine inside
    /// the message. Reproduced through the live `hermes-alice` write profile:
    /// `mail_send {"attachments": ["/tmp/zsec-secret.txt"]}` arrived base64'd
    /// in Alice's `.Sent` Maildir and decoded back to the secret.
    ///
    /// This is ADR-011 finding 1 on the read side and worse -- finding 1 was
    /// an arbitrary host *write*, this is an arbitrary host *read* wired
    /// directly to an outbound channel.
    func testAMediatedCallWithNoFileDirsMayAttachNothing() {
        let scope = MailScope.parse(Self.bobInboxScope)
        guard case .refuse(let message) = scope.readableAttachment("/tmp/zsec-secret.txt") else {
            return XCTFail("an absent file_dirs must refuse an attachment, not mean anywhere")
        }
        XCTAssertTrue(message.contains("may not attach files"), message)
        // The advice has to be actionable: the tool still works without it.
        XCTAssertTrue(message.contains("Omit `attachments`"), message)
    }

    func testAnAttachmentInsideFileDirsIsAllowedAndOutsideIsNot() throws {
        let root = try temporaryDirectory()
        let scope = MailScope.parse([
            "mail_accounts": .array([.string("Bob")]),
            "file_dirs": .array([.string(root.path)])
        ])
        let inside = root.appendingPathComponent("report.pdf").path
        XCTAssertEqual(scope.readableAttachment(inside), .use(inside))
        guard case .refuse(let message) = scope.readableAttachment("/etc/passwd") else {
            return XCTFail("a path outside file_dirs is not attachable")
        }
        XCTAssertTrue(message.contains("read files from"), message)
    }

    /// The same component-by-component resolution the write side uses. A
    /// repository is an ordinary checkout and repositories contain symlinks,
    /// so this is not a hypothetical a client has to plant.
    func testASymlinkOutOfFileDirsCannotBeAttached() throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        try "secret".write(to: outside.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent("way-out")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let scope = MailScope.parse(["file_dirs": .array([.string(root.path)])])
        guard case .refuse = scope.readableAttachment(link.appendingPathComponent("f.txt").path) else {
            return XCTFail("a symlink out of the allowed directory is out of it")
        }
    }

    /// An unmediated call -- macmcp on a bare stdio pipe, same-user local
    /// access -- attaches whatever it always could. Everything above must cost
    /// that nothing.
    func testAnUnmediatedCallAttachesWhateverItAlwaysCould() {
        XCTAssertEqual(MailScope.none.readableAttachment("/tmp/anything"), .unscoped)
    }

    /// End to end through the registry, which is the only thing that proves
    /// the check is actually wired into the compose path rather than merely
    /// available. Hermetic: `attachmentPaths` refuses before
    /// `mail.OutgoingMessage` is generated, let alone spawned.
    func testMailSendRefusesAnOutOfScopeAttachmentBeforeComposingAnything() {
        let registry = ToolRegistry()
        MailService.register(registry)
        // `Drafts` is in scope on purpose: what this pins is the *attachment*
        // refusal, and `mail_create_draft` now refuses a profile that cannot
        // reach its destination mailbox before it looks at anything else (see
        // `testCreateDraftAndMoveGiveTheSameAnswerAboutDrafts`). A scope that
        // tripped both would be pinning whichever came first.
        let scopeWithDrafts: JSONObject = [
            "mail_accounts": .array([.string("Bob")]),
            "mail_mailboxes": .array([.string("INBOX"), .string("Drafts")])
        ]
        for tool in ["mail_send", "mail_create_draft"] {
            let result = registry.call(
                name: tool,
                arguments: [
                    "to": .string("bob@relaytest.local"),
                    "subject": .string("probe"),
                    "body": .string("probe"),
                    "attachments": .array([.string("/tmp/zsec-secret.txt")])
                ],
                meta: scopeWithDrafts
            )
            XCTAssertEqual(result.isError, true, tool)
            XCTAssertEqual(result.meta?["scope_violation"], .bool(true), tool)
            XCTAssertTrue(
                (result.content.first?.text ?? "").contains("may not attach files"),
                "\(tool): \(result.content.first?.text ?? "")"
            )
        }
    }

    // MARK: - A draft is written into a mailbox, and that is reaching it

    /// **The three answers that disagreed.** With the same profile --
    /// `mail_mailboxes: ["Archive", "INBOX"]` -- `mail_move` to `Drafts` was
    /// refused, `mail_create_draft` wrote a complete message into that same
    /// `Drafts`, and `mail_get_email` on the id it handed back refused it as
    /// out of scope. This runs both refusals from one scope so the agreement
    /// is the assertion.
    ///
    /// End to end through the registry, which is the only thing that says the
    /// check is wired in rather than merely available. Hermetic: the refusal
    /// fires before `mail.OutgoingMessage` is generated, let alone spawned.
    func testCreateDraftAndMoveGiveTheSameAnswerAboutDrafts() {
        let registry = ToolRegistry()
        MailService.register(registry)
        let profile: JSONObject = [
            "mail_accounts": .array([.string("Alice")]),
            "mail_mailboxes": .array([.string("Archive"), .string("INBOX")])
        ]
        let move = registry.call(
            name: "mail_move",
            arguments: ["message_id": .int(1), "target_mailbox": .string("Drafts")],
            meta: profile
        )
        XCTAssertEqual(move.isError, true)
        XCTAssertEqual(move.meta?["scope_violation"], .bool(true))

        let draft = registry.call(
            name: "mail_create_draft",
            arguments: [
                "to": .string("bob@relaytest.local"),
                "subject": .string("probe"),
                "body": .string("probe")
            ],
            meta: profile
        )
        XCTAssertEqual(draft.isError, true)
        XCTAssertEqual(draft.meta?["scope_violation"], .bool(true))
        let text = draft.content.first?.text ?? ""
        XCTAssertTrue(text.contains("outside the mailboxes this client may reach"), text)
        XCTAssertTrue(text.contains("Nothing was composed"), text)
        // The advice names what would make it work, which is the one thing a
        // caller can act on: this tool takes no mailbox argument.
        XCTAssertTrue(text.contains("Drafts is one of the mailboxes"), text)
    }

    /// A profile that names `Drafts` drafts. The refusal must be about the
    /// mailbox and not about drafting.
    func testAProfileThatNamesDraftsIsNotRefusedByThisCheck() {
        let call = MailCall(budget: 30, scope: MailScope.parse([
            "mail_accounts": .array([.string("Alice")]),
            "mail_mailboxes": .array([.string("INBOX"), .string("Drafts")])
        ]))
        XCTAssertNil(MailService.draftDestinationRefusal(call: call))
    }

    /// Matched as a **path**, with no leaf-name fallback. `mailboxTargets`
    /// accepts a leaf name for an argument a caller wrote; nobody wrote this
    /// one, and a grant of a project folder called Drafts is not a grant of
    /// the account's Drafts. `mail_move` reaches the same conclusion one step
    /// later, when `fmAllowed` checks the resolved destination path.
    func testANestedFolderCalledDraftsIsNotAGrantOfTheAccountsDrafts() {
        let call = MailCall(budget: 30, scope: MailScope.parse([
            "mail_accounts": .array([.string("Alice")]),
            "mail_mailboxes": .array([.string("Projects/Drafts")])
        ]))
        XCTAssertNotNil(MailService.draftDestinationRefusal(call: call))
    }

    /// An unmediated call -- macmcp on a bare stdio pipe -- drafts exactly as
    /// it always has. Every existing caller is this one.
    func testAnUnmediatedCallDraftsWhereItAlwaysDid() {
        XCTAssertNil(MailService.draftDestinationRefusal(
            call: MailCall(budget: 30, scope: .none)))
    }

    /// **`mail_send` is deliberately not bound by this**, and the asymmetry is
    /// a decision rather than an oversight, so it is pinned. What that tool
    /// produces is a message on the wire; the Sent copy is bookkeeping about a
    /// delivery that has already happened, is not a destination the caller
    /// chose, and yields no handle. Requiring `Sent` in `mail_mailboxes` would
    /// take sending away from every write profile to bound a copy that changes
    /// nothing about who received the mail.
    ///
    /// A `mail_send` from a Drafts-less profile therefore gets past the scope
    /// checks and fails on Mail instead -- which is what this asserts, by the
    /// refusal it does NOT carry.
    func testMailSendIsNotRefusedForNotNamingSentOrDrafts() {
        let registry = ToolRegistry()
        MailService.register(registry)
        let result = registry.call(
            name: "mail_send",
            arguments: [
                "to": .string("bob@relaytest.local"),
                "subject": .string("probe"),
                "body": .string("probe"),
                // Zero budget so the call cannot reach Mail: what is being
                // asserted is which refusal comes back, not that one does.
                "timeout_seconds": .int(0)
            ],
            meta: [
                "mail_accounts": .array([.string("Alice")]),
                "mail_mailboxes": .array([.string("Archive"), .string("INBOX")])
            ]
        )
        XCTAssertNil(result.meta?["scope_violation"], result.content.first?.text ?? "")
        XCTAssertFalse(
            (result.content.first?.text ?? "").contains("outside the mailboxes"),
            result.content.first?.text ?? ""
        )
    }

    // MARK: - A2: a bound that is not an absolute path bounds nothing

    /// `realPath` walks components from a `/` seed, so it answered `/` for
    /// `"."`, `""` and `".."` alike -- and `/` is a prefix of every absolute
    /// path, so one such entry turned the containment check into a no-op that
    /// still reported a confinement. Reproduced over stdio: `file_dirs: ["."]`
    /// let `mail_get_source` write a message to `/tmp/zoutside/...`.
    ///
    /// Note the trigger for the `[""]` spelling: a bare JSON string reaches
    /// `stringsValue` as a one-element array.
    func testANonAbsoluteFileDirsEntryIsRefusedRatherThanResolvedToRoot() {
        for spelling in [JSONValue.array([.string(".")]),
                         .array([.string("")]),
                         .array([.string("..")]),
                         .string("")] {
            let scope = MailScope.parse(["file_dirs": spelling])
            guard case .misconfigured(let message) = scope.writeDestination("/tmp/zoutside/x.eml") else {
                return XCTFail("\(spelling) must not resolve to the filesystem root")
            }
            XCTAssertTrue(message.contains("not an absolute path"), message)
        }
    }

    func testFileDirsNamingTheFilesystemRootBoundsNothingAndIsRefused() {
        let scope = MailScope.parse(["file_dirs": .array([.string("/")])])
        guard case .misconfigured(let message) = scope.writeDestination("/etc/passwd") else {
            return XCTFail("`/` is not a bound")
        }
        XCTAssertTrue(message.contains("bounds nothing"), message)
    }

    /// It is an operator mistake, not a client probing a boundary, so it must
    /// not wear the violation marker -- ADR-011 decision 11 keeps a
    /// configuration error out of the security signal for the same reason it
    /// keeps a nonexistent mailbox out of it.
    func testAMisconfiguredScopeIsAnErrorAndNotAViolation() {
        let registry = ToolRegistry()
        MailService.register(registry)
        let result = registry.call(
            name: "mail_get_source",
            arguments: ["message_id": .int(1), "save_to": .string("/tmp/zoutside/x.eml")],
            meta: [
                "mail_accounts": .array([.string("Bob")]),
                "mail_mailboxes": .array([.string("INBOX")]),
                "file_dirs": .array([.string(".")])
            ]
        )
        XCTAssertEqual(result.isError, true)
        XCTAssertNil(result.meta?["scope_violation"], "an operator typo is not a probe")
    }

    /// Every entry is checked, not only the ones reached before a match, so a
    /// good entry cannot hide a bad one.
    func testOneBadEntryRefusesEvenWhenAnotherEntryWouldHaveMatched() throws {
        let root = try temporaryDirectory()
        let scope = MailScope.parse(["file_dirs": .array([.string(root.path), .string(".")])])
        guard case .misconfigured = scope.writeDestination(root.appendingPathComponent("f").path) else {
            return XCTFail("a scope with an unusable entry is unusable")
        }
    }

    // MARK: - `mail_get_source` is a parameter refusal, not a tool refusal

    /// `save_to` is optional and `mail_get_source` reads inline without it, so
    /// the field is deliberately out of `file_dirs`'s `applies_to` (relay must
    /// not deny the whole tool over a parameter most calls do not use) -- but
    /// a call that DOES pass `save_to` with no `file_dirs` in scope must still
    /// be refused, at the parameter, by macMCP itself. End to end through the
    /// registry, mirroring `testMailSendRefusesAnOutOfScopeAttachmentBeforeComposingAnything`:
    /// the refusal has to fire before `fetchSource` runs, since there is no
    /// Mail stub behind this call.
    func testMailGetSourceRefusesSaveToWithNoFileDirsBeforeFetchingAnything() {
        let registry = ToolRegistry()
        MailService.register(registry)
        let result = registry.call(
            name: "mail_get_source",
            arguments: [
                "message_id": .int(1),
                "save_to": .string("/tmp/zsec-exfil.eml")
            ],
            meta: Self.bobInboxScope
        )
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(result.meta?["scope_violation"], .bool(true))
        XCTAssertTrue(
            (result.content.first?.text ?? "").contains("may not write files"),
            result.content.first?.text ?? ""
        )
    }

    /// The tool-level half of the same claim, at the unit that actually makes
    /// it (`presenceRefusal`), which is what `testFileDirsDoesNotTakeAToolAwayTheWayAnOperatorFieldDoes`
    /// already pins directly without going through `fetchSource` -- a call
    /// with `save_to` omitted reaches Mail for real through the registry, so
    /// it is not repeated here.

    // MARK: - A3 / A5: the declaration is what says which tools a field governs

    /// `mail_list_mailboxes` called `scopeRefusal(..., mailboxKeys: [])`, so a
    /// mediated call carrying no `mail_mailboxes` checked nothing;
    /// `allowedList(.refuse)` then collapsed to `nil`, which every generated
    /// script reads as "no restriction". The discovery tool listed **every
    /// mailbox on the machine** -- the exact disclosure its own comment says
    /// it prevents. `mail_send`, `mail_create_draft` and `mail_list_accounts`
    /// never consulted `mail_mailboxes` either.
    func testEveryMailToolRefusesWhenAFieldItDeclaresIsAbsent() {
        let onlyAccounts = scoped(["mail_accounts": .array([.string("Bob")])])
        let onlyMailboxes = scoped(["mail_mailboxes": .array([.string("INBOX")])])
        let governed = [
            "mail_list_accounts", "mail_list_mailboxes", "mail_get_emails", "mail_get_email",
            "mail_search", "mail_send", "mail_create_draft", "mail_save_attachment",
            "mail_get_source", "mail_move", "mail_mark_read"
        ]
        for tool in governed {
            let missingMailboxes = MailService.presenceRefusal(tool: tool, call: onlyAccounts)
            XCTAssertNotNil(missingMailboxes, "\(tool) is governed by mail_mailboxes and did not require it")
            XCTAssertEqual(missingMailboxes?.meta?["scope_violation"], .bool(true), tool)
            XCTAssertTrue(
                (missingMailboxes?.content.first?.text ?? "").contains("mail_mailboxes"),
                "\(tool): \(missingMailboxes?.content.first?.text ?? "")"
            )
            XCTAssertNotNil(
                MailService.presenceRefusal(tool: tool, call: onlyMailboxes),
                "\(tool) is governed by mail_accounts and did not require it"
            )
            XCTAssertNil(
                MailService.presenceRefusal(tool: tool, call: scoped(Self.bobInboxScope)),
                "\(tool) must proceed when both fields carry a value"
            )
        }
    }

    /// The unmediated case is what must not move: `.unscoped` is not
    /// `.refuse`, and every call macmcp has ever served over a bare stdio pipe
    /// is that one.
    func testAnUnmediatedCallIsNotSubjectToThePresenceCheck() {
        XCTAssertNil(MailService.presenceRefusal(tool: "mail_list_mailboxes", call: MailCall(budget: 30)))
    }

    /// `file_dirs` is `source: "project_path"` and governs the *parameter*.
    /// A client with no directory keeps `mail_get_source` (it reads inline)
    /// and keeps `mail_send` (it sends without attachments); it loses
    /// `save_to`, `destination` and `attachments`. Applying the tool-level
    /// reading here would take a tool away that works perfectly well.
    func testFileDirsDoesNotTakeAToolAwayTheWayAnOperatorFieldDoes() {
        let noDirs = scoped(Self.bobInboxScope)
        XCTAssertNil(MailService.presenceRefusal(tool: "mail_get_source", call: noDirs))
        XCTAssertNil(MailService.presenceRefusal(tool: "mail_save_attachment", call: noDirs))
    }

    /// The declaration and the enforcement have to be the same list, or the
    /// derivation is decorative. `mail_*` is the glob both operator fields
    /// declare. `file_dirs` names only `mail_save_attachment` -- `destination`
    /// is required, so that tool cannot function without it -- and deliberately
    /// leaves `mail_get_source` out: `save_to` is optional, the tool reads
    /// inline without it, and denying the whole tool would be relay's
    /// tool-level `checkScopePresence` gutting a call that has nothing to do
    /// with a file. Both are still governed by the two operator fields.
    func testTheGovernedListComesFromTheDeclaredAppliesTo() {
        XCTAssertEqual(
            restrictFieldsGoverning(tool: "mail_search"),
            ["mail_accounts", "mail_mailboxes"]
        )
        XCTAssertEqual(
            restrictFieldsGoverning(tool: "mail_get_source"),
            ["mail_accounts", "mail_mailboxes"]
        )
        XCTAssertEqual(
            restrictFieldsGoverning(tool: "mail_save_attachment"),
            ["file_dirs", "mail_accounts", "mail_mailboxes"]
        )
        // `contacts_list` used to be the "a non-mail tool is governed by
        // nothing" case. It is governed now -- the calendar/contacts/reminders
        // fields declare their own tools -- so the original claim moves to a
        // tool no field names at all, and this line becomes the check that a
        // new service's `applies_to` reaches its own tools and stops there.
        //
        // Contacts is also the one service whose two fields do **not** share an
        // `applies_to`: a card need not be in a group, so `contact_groups`
        // governs only the four tools that act on a group, and a card tool is
        // bounded by its account alone. `ScopeDeclarationTests` is where that
        // is asserted tool by tool.
        XCTAssertEqual(
            restrictFieldsGoverning(tool: "contacts_list"),
            ["contact_accounts"]
        )
        XCTAssertEqual(
            restrictFieldsGoverning(tool: "contacts_add_to_group"),
            ["contact_accounts", "contact_groups"]
        )
        XCTAssertEqual(
            restrictFieldsGoverning(tool: "calendars_list_events"),
            ["calendar_accounts", "calendars"]
        )
        XCTAssertEqual(
            restrictFieldsGoverning(tool: "reminders_create"),
            ["reminder_accounts", "reminder_lists"]
        )
        XCTAssertEqual(restrictFieldsGoverning(tool: "web_fetch"), [])
        XCTAssertEqual(restrictFieldsGoverning(tool: "messages_send"), [])
        XCTAssertTrue(globMatches("mail_*", "mail_send"))
        XCTAssertFalse(globMatches("mail_*", "messages_send"))
        XCTAssertTrue(globMatches("mail_get_source", "mail_get_source"))
        XCTAssertFalse(globMatches("mail_get_source", "mail_get_sources"))
    }

    /// The second half of A3, and the belt to the braces above: a field with
    /// no value must reach a generated script as an **empty** allowed list,
    /// never as `null`. One forgotten check at one call site should not be
    /// able to widen a confinement into its opposite.
    func testAFieldWithNoValueReachesAScriptAsNothingAllowedRatherThanNoRestriction() {
        XCTAssertEqual(MailService.allowedList(.refuse) ?? ["NOT EMPTY"], [])
        XCTAssertEqual(MailService.scopeArrayJXA(MailService.allowedList(.refuse)), "[]")
        XCTAssertNil(MailService.allowedList(.unscoped))
        XCTAssertEqual(MailService.scopeArrayJXA(MailService.allowedList(.unscoped)), "null")
    }

    /// And what an empty list actually does when a script runs with it.
    func testAMailboxListingWithNothingAllowedListsNothing() throws {
        let payload = try JXA.run("""
        \(MailStubJS.source)
        var mail = makeMail({accounts: [
            {name: 'Bob', mailboxes: [{name: 'INBOX'}, {name: 'Archive'}, {name: 'Secret'}]}
        ]});
        \(MailService.listMailboxesScriptJXA(
            account: nil,
            scopeAccounts: MailService.allowedList(.refuse),
            scopeMailboxes: MailService.allowedList(.refuse)
        ))
        """)
        XCTAssertFalse(payload.contains("Secret"), payload)
        XCTAssertFalse(payload.contains("INBOX"), payload)
    }

    // MARK: - A6: a leaf name is not an identity, so it cannot answer a scope

    private func locate(scopeMailboxes: [String]?) throws -> [String: Any] {
        try JXA.runJSON("""
        \(MailStubJS.source)
        var mail = makeMail({accounts: [
            {name: 'Bob', mailboxes: [
                {name: 'Projects'},
                // The container walk raises, so `mbPathOf` gives up and only
                // the leaf name `Archive` is left -- which is also the name of
                // a top-level mailbox in the same account.
                {name: 'Archive', container: 'Projects', containerRaises: true,
                 messages: [{id: 102, messageId: 'nested@relaytest.local', subject: 'nested'}]}
            ]}
        ]});
        \(MailService.findMessageJXA(
            account: nil,
            mailbox: "INBOX",
            messageId: "102",
            scopeAccounts: ["Bob"],
            scopeMailboxes: scopeMailboxes
        ))
        JSON.stringify({
            bound: found === null ? null : ('' + foundMailbox),
            outOfScope: FM_OUT_OF_SCOPE,
            unlocated: FM_UNLOCATED,
            sentence: found === null ? \(MailService.fmNotFoundJXA(messageId: "102")) : null
        });
        """)
    }

    func testAMailboxWhosePathIsUnknownCannotSatisfyAMailboxScope() throws {
        // `Projects/Archive` under a scope of `["Archive"]`. The walk fails,
        // the leaf name is `Archive`, and checking the leaf against a scope of
        // paths admitted a mailbox the client may not reach.
        let payload = try locate(scopeMailboxes: ["Archive"])
        XCTAssertNil(payload["bound"] as? String, "an unlocatable mailbox must not pass a mailbox scope")
        XCTAssertEqual(payload["unlocated"] as? Bool, true)
        let sentence = try XCTUnwrap(payload["sentence"] as? String)
        // A race, not a probe: it must not be reported as a violation, and it
        // must tell the caller it is worth retrying.
        XCTAssertFalse(MailScopeRefusal.split(sentence).violation, sentence)
        XCTAssertTrue(sentence.contains("could not be identified"), sentence)
        XCTAssertTrue(sentence.contains("try again"), sentence)
    }

    /// With no mailbox scope there is nothing to check it against, so the leaf
    /// name goes on being the label it always was and the message is found.
    /// The fix must cost an unscoped call nothing.
    func testAnUnscopedCallStillFindsAMessageWhosePathCannotBeWalked() throws {
        let payload = try locate(scopeMailboxes: nil)
        XCTAssertEqual(payload["bound"] as? String, "Archive")
        XCTAssertEqual(payload["unlocated"] as? Bool, false)
    }

    // MARK: - W1: one normalisation, at one boundary

    /// Swift's `==` compares by canonical equivalence, JavaScript's `===` by
    /// UTF-16 code units. An accented account or mailbox spelled NFC in the
    /// profile and NFD by Mail (or the other way round) therefore passed the
    /// Swift front door and was rejected by every JS seam behind it: a
    /// *correct* scope silently reached nothing, with no violation logged
    /// because none had occurred.
    func testAnNFDSpellingAndAnNFCSpellingAreOneNameOnBothSides() throws {
        let nfc = "Arch\u{00E9}ives"          // é
        let nfd = "Arche\u{0301}ives"         // e + combining acute
        XCTAssertNotEqual(Array(nfc.utf16), Array(nfd.utf16), "the two spellings must really differ")

        // Swift half.
        XCTAssertTrue(MailScope.names(nfd, oneOf: [nfc]))
        XCTAssertEqual(MailScope.fold(nfc), MailScope.fold(nfd))

        // JavaScript half, through a real generated script: the scope is
        // written in one spelling and Mail reports the other.
        let listing = try JXA.run("""
        \(MailStubJS.source)
        var mail = makeMail({accounts: [
            {name: 'Bob', mailboxes: [{name: '\(nfd)'}, {name: 'Other'}]}
        ]});
        \(MailService.listMailboxesScriptJXA(
            account: nil,
            scopeAccounts: ["Bob"],
            scopeMailboxes: [nfc]
        ))
        """)
        XCTAssertTrue(listing.contains("Arch"), listing)
        XCTAssertFalse(listing.contains("Other"), "the scope still confines: \(listing)")
    }

    /// The same, for an account name, through the scan's own account filter --
    /// and with the Hebrew the fixture exercises, where the two spellings of a
    /// pointed letter are what a real mailbox name looks like.
    func testAnAccountNameMatchesAcrossNormalisationsInAGeneratedScript() throws {
        let nfc = "\u{FB2A}"                  // ‎שׁ  precomposed
        let nfd = "\u{05E9}\u{05C1}"          // ‎ש + shin dot
        XCTAssertTrue(MailScope.names(nfd, oneOf: [nfc]))
        let listing = try JXA.run("""
        \(MailStubJS.source)
        var mail = makeMail({accounts: [
            {name: '\(nfd)', mailboxes: [{name: 'INBOX'}]},
            {name: 'Other', mailboxes: [{name: 'INBOX'}]}
        ]});
        \(MailService.listMailboxesScriptJXA(
            account: nil,
            scopeAccounts: [nfc],
            scopeMailboxes: ["INBOX"]
        ))
        """)
        XCTAssertTrue(listing.contains("INBOX"), listing)
        XCTAssertFalse(listing.contains("Other"), listing)
    }

    // MARK: - W2: a fingerprint has to be unambiguous, not merely different

    /// `cacheFingerprint` joined values with `,`, so `["a,b"]` and
    /// `["a","b"]` spelled the same string. A mailbox path containing a comma
    /// could then let one process serve profile A bytes fetched under profile
    /// B -- a cache hit returns without running the script, and the script is
    /// where the scope is checked, so nothing anywhere would have decided it.
    func testTwoDifferentScopesCannotSpellTheSameFingerprint() {
        let joined = MailScope.parse(["mail_mailboxes": .array([.string("a,b")])])
        let separate = MailScope.parse(["mail_mailboxes": .array([.string("a"), .string("b")])])
        XCTAssertNotEqual(joined.cacheFingerprint, separate.cacheFingerprint)
        // And the same scope still fingerprints identically however it is
        // ordered or cased, or the key stops being a cache key at all.
        XCTAssertEqual(
            MailScope.parse(["mail_mailboxes": .array([.string("B"), .string("a")])]).cacheFingerprint,
            separate.cacheFingerprint
        )
        XCTAssertEqual(MailScope.none.cacheFingerprint, "u")
        XCTAssertNotEqual(MailScope.parse([:]).cacheFingerprint, MailScope.none.cacheFingerprint)
    }

    /// The fields must not be able to trade contents either.
    func testFieldsCannotBorrowEachOthersValues() {
        XCTAssertNotEqual(
            MailScope.parse(["mail_accounts": .array([.string("x")])]).cacheFingerprint,
            MailScope.parse(["mail_mailboxes": .array([.string("x")])]).cacheFingerprint
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macmcp-scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        // The temporary directory is itself behind a symlink on macOS
        // (/var -> /private/var), so the test's own expectations have to be
        // written against the resolved path or they measure the wrong thing.
        return URL(fileURLWithPath: url.resolvingSymlinksInPath().path)
    }
}
