import Foundation

/// ADR-011's `file_dirs` rule for the services whose tools open a file on this
/// host and have nothing to do with mail.
///
/// `MailScope`'s `writeDestination` / `readableAttachment` are the same bound
/// for the same field; what differs is only the sentence a caller is owed, and
/// "this client may not attach files from this host" is useless advice to one
/// that was trying to take a screenshot. The *walk* is shared
/// (`ResourceScope.bound` / `realPath`), the two misconfiguration sentences are
/// shared (`ResourceScope.fileDirsNotAbsolute` / `fileDirsBoundsNothing` --
/// they are about `file_dirs` itself and say nothing about any service), and
/// what lives here is which words these three tools use and what an **absent**
/// path resolves to.
///
/// **Why these three tools had no bound at all.** `file_dirs` was introduced
/// with the mail work and `grep -rn file_dirs Sources/` outside
/// `ContextSchema.swift` hit `MailScope.swift` and `MailService.swift` and
/// nothing else. Meanwhile `capture_screenshot` and `capture_audio` took an
/// unbounded absolute `path` and wrote to it, and `utilities_play_sound` took
/// an unbounded absolute `path` and read from it. A profile granted `capture_*`
/// therefore held the arbitrary host **write** ADR-011 finding 1 named as
/// escalation rather than exfiltration and closed for `mail_save_attachment` --
/// the identical hole, in the identical shape, one service over. The
/// validator's live attempt passed every relay and macMCP layer and died on the
/// tool's backend (Screen Recording ungranted, `afrecord` absent on that
/// build), which is to say on nothing that was deciding anything.
///
/// **All three are in `file_dirs`'s `applies_to`, and the rule that puts them
/// there is the one `mail_get_source` established:** name a tool only if it
/// cannot function at all without the field; a tool that merely has a
/// *parameter* needing it keeps working and the parameter refuses. `save_to` is
/// optional and `mail_get_source` reads a message inline without it, so that
/// tool stays out. These three have no such fallback. `utilities_play_sound`
/// requires `path`. And a capture tool's `path` is *optional in the schema and
/// unavoidable in fact*: every call writes a file somewhere, so there is no
/// call it could serve with no directory it may write into -- which is
/// `mail_save_attachment`'s position exactly, and `mail_save_attachment` is
/// already named.
enum HostFileScope {
    /// What a handler should do with the path it is about to open.
    ///
    /// `ResourceScope.Decision` is deliberately not reused, for the reason
    /// `ScopedRows.RowMatch` gives: its `.refuse` means "always a scope
    /// violation", and the answer to "you may write in two directories and
    /// named neither" is not a violation -- nothing was probed, the caller
    /// simply did not say where. Folding it into `.refuse` would tag it
    /// `scope_violation: true` and fill the signal an operator watches with
    /// callers who omitted an argument.
    enum Outcome: Equatable {
        /// Open this path. Tilde-expanded, never symlink-resolved: the
        /// resolved form is for comparing, not for opening.
        case use(String)
        /// A scope violation -- `scopeViolationResult`.
        case refuse(String)
        /// An error that is not a violation -- `errorResult`. Either the scope
        /// itself cannot be applied, or the caller has to name a directory.
        case error(String)
    }

    /// Which direction the path is being opened in. It changes the sentence
    /// and nothing else; the bound is one list.
    enum Use {
        case write
        case read
    }

    // MARK: - A path the caller named

    /// The bound applied to a path a caller actually wrote.
    static func resolve(
        _ path: String,
        scope: ResourceScope,
        use: Use,
        what: String
    ) -> Outcome {
        switch scope.fileDirsAccess {
        case .unscoped:
            // Nobody mediated the call: macmcp on a bare stdio pipe, which is
            // same-user local access equivalent to running `screencapture`.
            // Every existing caller is this one and must be unaffected.
            return .use((path as NSString).expandingTildeInPath)
        // `file_dirs` is `source: "project_path"`, never operator-picked, so
        // neither `.unrestricted` nor `.confirmedEmpty` reads as a reviewed
        // grant the way it would for an operator-set field -- there is no
        // operator here to have reviewed anything. Both refuse exactly as
        // `.refuse` does: fsMCP finding 8 ("an empty list quietly became no
        // restriction") is the shape this must never grow, and a
        // project-path field is where that bug would be a real filesystem
        // escape rather than a lost tool.
        case .unrestricted, .confirmedEmpty, .refuse:
            return .refuse(noFileDirs(use: use, what: what))
        case .allowed(let dirs):
            return verdict(ResourceScope.bound(path, within: dirs), path: path, dirs: dirs, use: use)
        }
    }

    // MARK: - The path the caller did not name

    /// Where a capture writes when the caller named no `path`.
    ///
    /// **A tool's own default is not a choice the caller made**, which is
    /// ADR-011's first reconciliation rule, and `~/Desktop` is a tool default
    /// that a confined client has almost certainly not been granted. Refusing
    /// outright would mean no scoped client could ever take a screenshot
    /// without first knowing its own `file_dirs`, so an absent path resolves
    /// **to the scope**, in exactly the three steps `ScopedRows.defaultTarget`
    /// resolves an absent `calendar_name` in:
    ///
    /// * the tool's own default, when the scope already contains it -- an
    ///   operator who granted the directory the user's screenshots go to gets
    ///   what they meant;
    /// * the one directory in scope, when there is only one, because there is
    ///   no other answer;
    /// * otherwise the caller is asked, with the directories named. Picking
    ///   one of several would be choosing where a client's file lands out of
    ///   several the operator listed for different reasons, and a refusal the
    ///   caller can answer in one call is better than a file in a surprising
    ///   place.
    ///
    /// The filename is passed separately from the default directory so the
    /// second and third steps have something to build a name out of; a scope
    /// entry is a directory, never a file.
    static func resolveDefault(
        directory: String,
        filename: String,
        scope: ResourceScope,
        what: String
    ) -> Outcome {
        let toolDefault = ((directory as NSString).expandingTildeInPath as NSString)
            .appendingPathComponent(filename)
        switch scope.fileDirsAccess {
        case .unscoped:
            return .use(toolDefault)
        case .unrestricted, .confirmedEmpty, .refuse:
            return .refuse(noFileDirs(use: .write, what: what))
        case .allowed(let dirs):
            switch ResourceScope.bound(toolDefault, within: dirs) {
            case .inside(let expanded):
                return .use(expanded)
            case .rootNotAbsolute(let dir):
                return .error(ResourceScope.fileDirsNotAbsolute(dir))
            case .rootIsFilesystemRoot(let dir):
                return .error(ResourceScope.fileDirsBoundsNothing(dir))
            case .notAbsolute, .outside:
                break
            }
            // Every entry has been walked by `bound` above, so a bad one has
            // already been reported and the entries below are absolute.
            if dirs.count == 1 {
                return .use(((dirs[0] as NSString).expandingTildeInPath as NSString)
                    .appendingPathComponent(filename))
            }
            return .error(
                "this client may write into \(dirs.count) directories — \(quoted(dirs)) — and this "
                + "Mac's default location for a \(what) is not one of them, so there is nowhere to "
                + "write by default. Pass `path` naming a file inside one of them. macMCP will not "
                + "pick one for you: a file written somewhere the access profile listed for another "
                + "purpose is worse than a refusal the caller can answer."
            )
        }
    }

    // MARK: - Sentences

    private static func verdict(
        _ bound: ResourceScope.PathBound,
        path: String,
        dirs: [String],
        use: Use
    ) -> Outcome {
        switch bound {
        case .inside(let expanded):
            return .use(expanded)
        case .notAbsolute:
            return .refuse("path \"\(path)\" must be absolute")
        case .rootNotAbsolute(let dir):
            return .error(ResourceScope.fileDirsNotAbsolute(dir))
        case .rootIsFilesystemRoot(let dir):
            return .error(ResourceScope.fileDirsBoundsNothing(dir))
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

    /// The refusal for a mediated call carrying no `file_dirs` at all.
    ///
    /// It says the tool is unavailable rather than naming a parameter to omit,
    /// which is what mail's equivalent says, because there is nothing to omit:
    /// these three tools cannot run without opening a file. That is the same
    /// reason they are in `applies_to`, so relay denies them outright too --
    /// this sentence is what a caller sees when macMCP is asked directly,
    /// which decision 4 requires be an independent check rather than a
    /// restatement of relay's.
    private static func noFileDirs(use: Use, what: String) -> String {
        let verb = use == .write ? "write files" : "read files from this host"
        return "this client may not \(verb): its access profile carries no `file_dirs`, and an "
            + "absent or empty scope is a refusal rather than \"anywhere\". An access profile has "
            + "no project directory to derive one from, so this tool is unavailable to it — every "
            + "call opens a \(what) on this host, so there is no form of the call that needs no "
            + "directory."
    }

    private static func quoted(_ values: [String]) -> String {
        values.map { "\"\($0)\"" }.joined(separator: ", ")
    }
}
