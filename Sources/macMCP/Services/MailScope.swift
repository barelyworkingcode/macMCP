import Foundation

/// The mail resource scope a caller's `_meta` carries, per ADR-011
/// ("A Client Is an Identity, an Access Profile, and a Resource Scope").
///
/// **`MailScope` is `ResourceScope`.** It was the first and for one release
/// the only scoping service, so the general mechanism was written inside it:
/// the three-state `Access` answer, `isScoped` meaning "`_meta` was present at
/// all", `Decision` with its `misconfigured` outcome, `fold`, the
/// component-by-component path walk, the length-prefixed cache fingerprint and
/// the presence check driven by `applies_to`. None of that is about mail, and
/// three more services would each have reinvented it -- four copies of a rule
/// whose failure direction is fail-open. It now lives in `ResourceScope.swift`
/// and this file holds only what a *mail* scope means: which `_meta` keys it
/// reads, and how the reconciliation rule applies to a mail argument.
///
/// A typealias rather than a wrapper struct on purpose. There is one
/// `contextSchema`, so a call carries one scope; a `MailScope` that *held* a
/// `ResourceScope` would have to forward `isScoped`, `parse`, `Access`,
/// `Decision`, `fold`, `names`, `cacheFingerprint` and `.none` through by
/// hand, which is more mail-shaped code than there was before the extraction
/// and would make every one of those a second place the rule could drift. The
/// three field names and shapes are ADR-011's worked `contextSchema` (see
/// `ContextSchema.swift`, declared in `main.swift`'s `initialize` handler):
/// `mail_accounts` and `mail_mailboxes` are operator-set and apply to
/// `mail_*`; `file_dirs` is derived by relay from a project's own path
/// (`source: "project_path"`).
///
/// **`file_dirs` is ADR-011's `write_dirs`, renamed because it was only ever
/// half the axis.** It governed `mail_save_attachment`'s `destination` and
/// `mail_get_source`'s `save_to` -- the two places macMCP writes a file --
/// while `mail_send` and `mail_create_draft` took `attachments: [absolute
/// POSIX paths]` and *read* whatever was named straight off the host into an
/// outbound message, scoped by nothing at all. That is ADR-011 finding 1 on
/// the read side and worse: finding 1 was an arbitrary host write, this was an
/// arbitrary host read wired directly to a channel that leaves the machine. A
/// write mail profile could mail out any file Mail could open, and did:
/// `mail_send {"attachments": ["/tmp/zsec-secret.txt"]}` through the live
/// `hermes-alice` profile arrived base64'd in Alice's Sent Maildir.
///
/// One axis rather than two (ADR-011 constraint 3): the field is the client's
/// **filesystem foothold on this host**, in both directions, and an operator
/// who has decided which directories a client may touch has answered both
/// questions at once. Two lists would be two chances to get it wrong for one
/// decision, and no one has named a case wanting read here and write there.
typealias MailScope = ResourceScope

extension ResourceScope {
    // MARK: - The three keys a mail scope reads

    /// `nil` means the request's `_meta` had no `mail_accounts` key at all (or
    /// carried one whose value was not a string or an array of strings). A
    /// present-but-empty array (`[]`) is a distinct, equally-refusing state,
    /// kept apart from `nil` because "an operator wrote an empty list" and
    /// "the key was never sent" are different facts worth telling apart later
    /// (diagnostics, audit), even though decision 4 treats them identically
    /// for the purpose of the call.
    var mailAccounts: [String]? { values(of: "mail_accounts") }

    /// Same contract as `mailAccounts`, for `mail_mailboxes`.
    var mailMailboxes: [String]? { values(of: "mail_mailboxes") }

    /// Same contract as `mailAccounts`, for `file_dirs`.
    var fileDirs: [String]? { values(of: "file_dirs") }

    /// The three questions an enforcer asks, named. Distinct from one another
    /// on purpose: a call can be scoped by `file_dirs` alone (a local
    /// project's project-path bound, auto-derived with no operator action)
    /// while carrying no `mail_accounts` -- and whether that combination
    /// should refuse `mail_search` is a per-tool `applies_to` question for the
    /// presence check, not something a single collapsed flag should decide.
    var accountsAccess: Access { access("mail_accounts") }
    var mailboxesAccess: Access { access("mail_mailboxes") }
    var fileDirsAccess: Access { access("file_dirs") }

    // MARK: - The reconciliation rule

    /// ADR-011, "The reconciliation rule the MCP implements", applied to an
    /// `account` argument:
    ///
    /// * an **absent or default-valued** scope-relevant argument resolves
    ///   **to the scope**, not to everything;
    /// * a **tool-level wildcard** (`mailbox: "all"`) means "everything I am
    ///   allowed to see" and resolves to the scope -- it does not error;
    /// * an **explicit** argument outside the scope is an **error**, never a
    ///   silent narrowing, because silent narrowing lets an agent build a
    ///   false model of what it can reach and burn calls discovering the
    ///   truth;
    /// * **enumerators are scoped too**, since listing the machine's real
    ///   account names to a confined client is a disclosure and is how that
    ///   client learns what to try next.
    ///
    /// `.use` carries account **names**, with `On My Mac` among them when the
    /// scope allows it -- it is an account name every mail tool accepts (#54),
    /// and relay cannot scope what the enumeration does not name, so it has to
    /// be nameable here too. The caller maps it onto the local pass.
    func accountTargets(requested: String?) -> Decision<[String]> {
        switch accountsAccess {
        case .unscoped:
            return .unscoped
        case .refuse:
            return .refuse(MailScope.refusalNoValue(field: "mail_accounts", noun: "mail account"))
        // "Every account, resolved fresh" is exactly what `resolveTargets`'s
        // own `.unscoped` branch already does -- an absent `account` reads
        // `accountNames(scopable: true, ...)` live, and an explicit one is
        // passed straight through with no list to check it against. Reusing
        // `.unscoped` here is not a shortcut: it is what "there is nothing to
        // resolve" cashes out to, since building a concrete list first and
        // then not restricting to it would be enumerating for no reason.
        case .unrestricted:
            return .unscoped
        // Confirmed-empty accounts means zero accounts in scope. An omitted
        // `account` resolves to that empty scope -- `.use([])`, not
        // `.refuse` -- so a scan proceeds and reports `total_messages: 0` as
        // the true, reviewed answer rather than erroring: `resolveTargets`'s
        // `.use` branch already treats an empty allowed list as "no
        // targets", and `scanFailure` already treats zero targets as "the
        // scope really was empty" rather than a failure. An **explicit**
        // `account` is a different question -- ADR-011's rule that an
        // explicit argument outside the scope is an error, never a silent
        // narrowing, does not stop applying just because the scope is
        // empty rather than merely not containing this one value.
        case .confirmedEmpty:
            guard let requested else { return .use([]) }
            return .refuse(
                "account \"\(requested)\" is outside the mail accounts this client may reach. "
                + "This client's mail_accounts is confirmed empty — it may reach no account at all. "
                + "Omit `account` to read every account it may reach (none)."
            )
        case .allowed(let allowed):
            guard let requested else { return .use(allowed) }
            guard MailScope.names(requested, oneOf: allowed) else {
                return .refuse(
                    "account \"\(requested)\" is outside the mail accounts this client may reach. "
                    + "It may reach: \(allowed.joined(separator: ", ")). "
                    + "Omit `account` to read every account it may reach."
                )
            }
            return .use([requested])
        }
    }

    /// The mailbox paths a scan may read, for a `mailbox` argument.
    ///
    /// `requested` is the argument **as the caller wrote it** -- `nil` for
    /// absent, which resolves to the scope rather than to the tool's own
    /// default, because a default-valued argument is not a choice the caller
    /// made. `wildcard` is the tool-level "everything" value, which also
    /// resolves to the scope.
    ///
    /// An explicit argument is matched against the allowed paths first, then
    /// against their leaf names, which is the same two-step every mailbox
    /// argument is resolved by (a bare name is a path with one component; a
    /// leaf name is a fallback). The *result* is still the whole allowed list:
    /// the intersection with what Mail actually holds happens inside the scan,
    /// against paths read off Mail rather than against strings.
    func mailboxTargets(requested: String?, wildcard: String = "all") -> Decision<[String]> {
        switch mailboxesAccess {
        case .unscoped:
            return .unscoped
        case .refuse:
            return .refuse(MailScope.refusalNoValue(field: "mail_mailboxes", noun: "mailbox"))
        // Nothing to resolve: every mailbox in every account is reachable,
        // which is exactly what `.unscoped` already means to every caller of
        // this function (`allowedList` feeds it into the generated scan as
        // `SCOPE_MAILBOXES = null`, "no restriction"; `scopedMailboxArgument`
        // reads it as "scoped" for the same reason `.allowed` is).
        case .unrestricted:
            return .unscoped
        // Zero mailboxes in scope. Absent or the tool's own "all" wildcard
        // resolves to that empty scope; an explicit mailbox name is still an
        // explicit argument outside the scope, and stays a refusal rather
        // than a silent empty scan -- the same split `accountTargets` makes.
        case .confirmedEmpty:
            guard let requested, requested.lowercased() != wildcard.lowercased() else {
                return .use([])
            }
            return .refuse(
                "mailbox \"\(requested)\" is outside the mailboxes this client may reach. "
                + "This client's mail_mailboxes is confirmed empty — it may reach no mailbox at all."
            )
        case .allowed(let allowed):
            guard let requested, requested.lowercased() != wildcard.lowercased() else {
                return .use(allowed)
            }
            let leaves = allowed.map { $0.split(separator: "/").last.map(String.init) ?? $0 }
            guard MailScope.names(requested, oneOf: allowed)
                    || MailScope.names(requested, oneOf: leaves) else {
                return .refuse(
                    "mailbox \"\(requested)\" is outside the mailboxes this client may reach. "
                    + "It may reach: \(allowed.joined(separator: ", ")). "
                    + "Pass mailbox \"\(wildcard)\", or omit it, to read every mailbox it may reach."
                )
            }
            return .use(allowed)
        }
    }

    // MARK: - The filesystem foothold

    /// Which direction a path is being confined in. The bound is one list
    /// (`file_dirs`); only the sentence a refusal is written in differs, and
    /// it has to, because "this client may not write files" is useless advice
    /// to a caller that was trying to attach one.
    enum FileUse {
        /// `mail_save_attachment`'s `destination`, `mail_get_source`'s
        /// `save_to`: macMCP creates a file here.
        case write
        /// `mail_send` / `mail_create_draft`'s `attachments`: macMCP opens a
        /// file here and puts its bytes into a message.
        case read
    }

    /// Whether a filesystem path is one this call may write to
    /// (`mail_save_attachment`'s `destination`, `mail_get_source`'s
    /// `save_to`).
    func writeDestination(_ path: String) -> Decision<String> {
        confine(path, for: .write)
    }

    /// Whether a filesystem path is one this call may read a file out of
    /// (`mail_send` / `mail_create_draft`'s `attachments`).
    ///
    /// **A client with no `file_dirs` may attach nothing at all.** This is
    /// ADR-011's own reasoning for finding 1, run in the other direction: an
    /// access profile has no host directory, relay derives nothing, so every
    /// use of the field refuses -- and that is the intended outcome, not a
    /// gap. Reading a file to mail it away is a filesystem foothold whether
    /// the bytes end on disk or in a message.
    func readableAttachment(_ path: String) -> Decision<String> {
        confine(path, for: .read)
    }

    /// The mail sentences for `ResourceScope.bound`'s verdicts.
    ///
    /// The *walk* is shared (`bound` / `realPath`, and see those for why it is
    /// component-by-component and why a non-absolute bound is refused rather
    /// than resolved); what stays here is which words a mail caller is owed,
    /// and the `.misconfigured` / `.refuse` split -- ADR-011 decision 11 keeps
    /// an operator's typo out of the security signal a client's probe belongs
    /// in.
    private func confine(_ path: String, for use: FileUse) -> Decision<String> {
        switch fileDirsAccess {
        case .unscoped:
            return .unscoped
        // `file_dirs` is `source: "project_path"`: relay derives it, an
        // operator never picks it, and there is no picker to click "select
        // all" or "confirm empty" in. `.unrestricted` and `.confirmedEmpty`
        // both exist for a field an operator reviews; there is no operator
        // here to have reviewed anything, so neither reads as a considered
        // grant. Refused exactly as `.refuse` is, and by the same words --
        // fsMCP's finding 8 is precisely "an empty list quietly became no
        // restriction", and a project-path field is the one place that bug
        // would be a real filesystem escape rather than a lost tool, so this
        // stays maximally conservative rather than trying to be helpful
        // about which of the three absent-ish spellings it saw.
        case .unrestricted, .confirmedEmpty, .refuse:
            switch use {
            case .write:
                return .refuse(
                    "this client may not write files: its access profile carries no `file_dirs`, "
                    + "and an absent or empty scope is a refusal rather than \"anywhere\". "
                    + "An access profile has no project directory to derive one from, so "
                    + "mail_save_attachment is unavailable to it and mail_get_source works "
                    + "without save_to."
                )
            case .read:
                return .refuse(
                    "this client may not attach files from this host: its access profile carries "
                    + "no `file_dirs`, and an absent or empty scope is a refusal rather than "
                    + "\"anywhere\". An access profile has no project directory to derive one from, "
                    + "so it may compose and send mail but may not read a file off this machine to "
                    + "put in it. Omit `attachments`."
                )
            }
        case .allowed(let dirs):
            switch MailScope.bound(path, within: dirs) {
            case .inside(let expanded):
                return .use(expanded)
            case .notAbsolute:
                return .refuse("path \"\(path)\" must be absolute")
            // Both sentences are about `file_dirs` itself rather than about
            // mail, so they are `ResourceScope`'s and `HostFileScope` reads
            // the same two -- an operator meeting this mistake through
            // `capture_screenshot` and through `mail_save_attachment` must
            // not be told two different things about one bad entry.
            case .rootNotAbsolute(let dir):
                return .misconfigured(MailScope.fileDirsNotAbsolute(dir))
            case .rootIsFilesystemRoot(let dir):
                return .misconfigured(MailScope.fileDirsBoundsNothing(dir))
            case .outside:
                switch use {
                case .write:
                    return .refuse(
                        "path \"\(path)\" is outside the directories this client may write into: "
                        + dirs.joined(separator: ", ")
                    )
                case .read:
                    return .refuse(
                        "path \"\(path)\" is outside the directories this client may read files from: "
                        + dirs.joined(separator: ", ")
                    )
                }
            }
        }
    }
}

// MARK: - Carrying a scope refusal out of generated JavaScript

/// How a refusal raised *inside* a generated script says that it was a scope
/// violation rather than any other kind of no.
///
/// Most of what `MailService` does is generated JavaScript, and several scope
/// checks can only happen there: `messages.byId` resolves globally, so where a
/// message really is comes off the message; a destination mailbox is only
/// known once it has been resolved; and which account owns a `from` address is
/// something only Mail can answer. Those refusals reach Swift as prose -- a
/// thrown sentence unwrapped by `scriptErrorMessage`, or an `{error: ...}`
/// field -- and prose is exactly what ADR-011 decision 7 says relay must not
/// have to parse.
///
/// So a script-side scope refusal prefixes its sentence with a sentinel, and
/// `MailService.mailError` strips it back off and tags the result's `_meta`
/// instead. U+0001 cannot occur in a mailbox path, an account name or an email
/// address, and is not something a caller can smuggle in through an argument
/// that gets echoed back: the match is on the *prefix*, so an argument would
/// have to begin the sentence, and every sentence here begins with text this
/// file wrote.
///
/// Not generalised alongside the rest: EventKit and Contacts run no script, so
/// there is nothing for a refusal to travel through. A second service that
/// generates code would share this; none does.
enum MailScopeRefusal {
    static let sentinel = "\u{1}scope_violation\u{1}"

    /// Wraps a message for a script to throw or return.
    static func mark(_ message: String) -> String { sentinel + message }

    /// Splits the sentinel back off. `violation` is false for every message
    /// that never carried one, which is every message written before this
    /// existed.
    static func split(_ message: String) -> (message: String, violation: Bool) {
        guard message.hasPrefix(sentinel) else { return (message, false) }
        return (String(message.dropFirst(sentinel.count)), true)
    }
}
