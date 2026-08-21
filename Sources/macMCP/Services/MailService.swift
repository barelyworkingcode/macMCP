import Foundation

enum MailService {
    /// Wall-clock ceiling for a single osascript invocation. Mail can wedge for
    /// minutes on an expensive Apple Event, and an unbounded wait would hang the
    /// whole server, so every run gets a deadline and a SIGKILL backstop.
    private static let defaultTimeout: TimeInterval = 120

    /// The bundle every mail_* tool sends Apple Events to.
    private static let mailBundleID = "com.apple.mail"

    /// Builds the error returned when a script blows its deadline.
    ///
    /// Every overrun used to be attributed to Mail being slow and answered with
    /// the same "narrow the scope" advice. Two things were wrong with that. A
    /// blocked-on-consent `osascript` looks identical to a wedged Apple Event
    /// from the outside, and the one action that fixes it -- answer the prompt
    /// -- went unmentioned. And the advice is not expressible in every tool's
    /// schema: `mail_list_accounts` takes no arguments at all, so a caller
    /// following it has nothing to change and will retry forever.
    ///
    /// So the automation grant is checked before blaming Mail, and the scope
    /// advice is only offered to tools that actually have scope. Whatever
    /// `osascript` wrote to stderr is kept either way -- it is the only other
    /// evidence there is, and the timeout path used to discard it.
    static func jxaTimeoutMessage(
        timeout: TimeInterval,
        automation: AutomationStatus,
        scopable: Bool,
        stderr: String
    ) -> String {
        let seconds = Int(timeout)
        var message: String
        switch automation {
        case .pendingConsent:
            message = "Mail was never asked: macOS is waiting for permission to send Apple Events to Mail, and the request sat behind that prompt until it was cancelled after \(seconds)s. Approve the prompt on screen, or grant automation of Mail in System Settings > Privacy & Security > Automation, then try again."
        case .denied:
            message = "Mail was never asked: permission to send Apple Events to Mail is denied, so the request could not leave this process. Re-grant it in System Settings > Privacy & Security > Automation — in Relay, Settings > MCP Servers > macMCP > Reset Permissions — then try again."
        case .checkBlocked:
            message = "Mail did not respond within \(seconds)s, and macOS would not say whether this process may control Mail either — that check only blocks while a consent prompt is waiting to be answered. Look for a permission prompt on screen and approve it; if there is none, grant automation of Mail in System Settings > Privacy & Security > Automation. Then try again."
        case .targetNotRunning:
            message = "Mail did not respond within \(seconds)s and is not running, so the request was most likely waiting for it to launch, or for permission to control it. Start Mail, approve any permission prompt on screen, then try again."
        case .granted, .unknown:
            message = "Mail did not respond within \(seconds)s — the request was cancelled."
            message += scopable
                ? " Narrow the scope (a specific account or mailbox, or a smaller limit) and try again."
                : " This tool takes no scope arguments, so there is nothing to narrow: check that Mail is running and responsive, then try again."
        }
        if !stderr.isEmpty {
            message += " osascript wrote: \(stderr)"
        }
        return message
    }

    /// Runs a JXA script under a hard deadline, returning trimmed stdout.
    ///
    /// `scopable` says whether the calling tool has an argument the caller could
    /// narrow — an account, a mailbox, a limit. It is only used to decide what
    /// to suggest on a timeout, and it is false for the tools whose schemas
    /// offer nothing to narrow.
    private static func runJXA(
        _ script: String,
        retries: Int = 2,
        timeout: TimeInterval = defaultTimeout,
        scopable: Bool = true
    ) -> (output: String, error: String?) {
        let (data, error) = runJXAData(script, retries: retries, timeout: timeout, scopable: scopable)
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (output, error)
    }

    /// Runs a JXA script under a hard deadline, returning stdout as raw bytes.
    ///
    /// Message sources run to megabytes and are handed straight to the MIME
    /// reader, so they must not be round-tripped through a trimmed `String`.
    ///
    /// Output goes to temp files rather than pipes: a scan of a large mailbox
    /// easily exceeds the 64 KB pipe buffer, and reading a pipe only after
    /// `waitUntilExit()` deadlocks once the child fills it.
    private static func runJXAData(
        _ script: String,
        retries: Int = 2,
        timeout: TimeInterval = defaultTimeout,
        scopable: Bool = true
    ) -> (output: Data, error: String?) {
        // Ask TCC where the automation grant stands *before* running anything.
        // Asking afterwards, on the error path, is too late: while a consent
        // prompt is on screen the check itself blocks -- 12s in one measurement,
        // and still blocked 20s after the script that raised the prompt had been
        // killed -- so the answer has to be taken while nothing is waiting on
        // the user. It costs about 10ms then, against a spawn that costs an
        // order of magnitude more, and it is the difference between reporting
        // "Mail was slow" and reporting the thing that is actually wrong.
        let automation = PermissionsService.automationStatus(bundleID: mailBundleID)

        for attempt in 0...retries {
            let tmpDir = FileManager.default.temporaryDirectory
            let stem = "macmcp-jxa-\(UUID().uuidString)"
            let outURL = tmpDir.appendingPathComponent(stem + ".out")
            let errURL = tmpDir.appendingPathComponent(stem + ".err")
            defer {
                try? FileManager.default.removeItem(at: outURL)
                try? FileManager.default.removeItem(at: errURL)
            }

            FileManager.default.createFile(atPath: outURL.path, contents: nil)
            FileManager.default.createFile(atPath: errURL.path, contents: nil)
            guard let outHandle = try? FileHandle(forWritingTo: outURL),
                  let errHandle = try? FileHandle(forWritingTo: errURL) else {
                return (Data(), "failed to open temp files for osascript output")
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", "-e", script]
            process.standardOutput = outHandle
            process.standardError = errHandle

            do {
                try process.run()
            } catch {
                try? outHandle.close()
                try? errHandle.close()
                return (Data(), "failed to run osascript: \(error.localizedDescription)")
            }

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }

            var timedOut = false
            if process.isRunning {
                timedOut = true
                process.terminate()
                let killDeadline = Date().addingTimeInterval(2)
                while process.isRunning && Date() < killDeadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            try? outHandle.close()
            try? errHandle.close()

            let output = (try? Data(contentsOf: outURL)) ?? Data()
            let errOutput = (try? String(contentsOf: errURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if timedOut {
                return (Data(), jxaTimeoutMessage(
                    timeout: timeout,
                    automation: automation,
                    scopable: scopable,
                    stderr: errOutput
                ))
            }

            if process.terminationStatus != 0 {
                // -1712 is an Apple Event timeout inside Mail itself. Retrying
                // just spends the same wait again, so surface it instead.
                if errOutput.contains("-1712") {
                    return (Data(), "Mail timed out evaluating the request (-1712). Narrow the scope and try again.")
                }
                if attempt < retries && errOutput.contains("-1728") {
                    Thread.sleep(forTimeInterval: 0.5)
                    continue
                }
                return (output, errOutput.isEmpty ? "osascript exited with status \(process.terminationStatus)" : errOutput)
            }
            return (output, nil)
        }
        return (Data(), "max retries exceeded")
    }

    /// Renders a Swift string as the body of a single-quoted JS string literal.
    ///
    /// Everything outside printable ASCII becomes `\uXXXX`. The script reaches
    /// osascript as an `-e` argument, which is decoded using the process
    /// locale, and the MCP server is launched by a host that need not set one:
    /// an em dash or a Hebrew transliteration passed through as raw UTF-8 comes
    /// out mangled. Escaping keeps the whole script in the ASCII subset every
    /// locale agrees on. U+2028/U+2029 also have to go — they terminate a JS
    /// string literal even though they are not newlines to Swift.
    private static func escapeJSString(_ s: String) -> String {
        var out = String()
        out.reserveCapacity(s.utf16.count)
        for unit in s.utf16 {
            switch unit {
            case 0x5C: out += "\\\\"      // backslash
            case 0x27: out += "\\'"       // single quote
            case 0x22: out += "\\\""      // double quote, so either literal style is safe
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x20...0x7E: out.append(Character(UnicodeScalar(unit)!))
            default: out += String(format: "\\u%04X", unit)
            }
        }
        return out
    }

    /// Which mailboxes a generated collection snippet should gather.
    private enum BoxScope {
        /// Every mailbox of the named account. The JXA throws when it is missing.
        case account(String)
        /// Mail's app-level "On My Mac" mailboxes only.
        case local
        /// Every account's mailboxes plus the local On-My-Mac boxes.
        case everything
    }

    /// JXA that builds `var <varName> = [{mbox, acctName, name}]` for `scope`.
    /// Note: Mail returns account.mailboxes() already flattened (nested folders
    /// included), so no recursion is needed.
    private static func collectBoxesJXA(_ scope: BoxScope, varName: String) -> String {
        let pushAccountBoxes = """
                var acctName = accts[ai].name();
                var mboxes = accts[ai].mailboxes();
                for (var mj = 0; mj < mboxes.length; mj++) {
                    sink.push({mbox: mboxes[mj], acctName: acctName, name: '' + mboxes[mj].name()});
                }
        """
        let pushLocalBoxes = """
            var localBoxes = mail.mailboxes();
            for (var lj = 0; lj < localBoxes.length; lj++) {
                sink.push({mbox: localBoxes[lj], acctName: 'On My Mac', name: '' + localBoxes[lj].name()});
            }
        """

        let body: String
        switch scope {
        case .account(let account):
            let escapedAccount = escapeJSString(account)
            body = """
            var accts = mail.accounts();
            for (var ai = 0; ai < accts.length; ai++) {
                if (accts[ai].name().toLowerCase() === '\(escapedAccount)'.toLowerCase()) {
        \(pushAccountBoxes)
                    return sink;
                }
            }
            throw new Error('account not found: \(escapedAccount)');
        """
        case .local:
            body = """
        \(pushLocalBoxes)
            return sink;
        """
        case .everything:
            body = """
            var accts = mail.accounts();
            for (var ai = 0; ai < accts.length; ai++) {
        \(pushAccountBoxes)
            }
        \(pushLocalBoxes)
            return sink;
        """
        }

        return """
        var \(varName) = (function() {
            var sink = [];
        \(body)
        })();
        """
    }

    /// Convenience for the by-id helpers, where a nil account means "look
    /// everywhere" rather than "look at the local boxes".
    private static func collectBoxesJXA(account: String?, varName: String) -> String {
        collectBoxesJXA(account.map { BoxScope.account($0) } ?? .everything, varName: varName)
    }

    /// Builds the JXA for one bulk mailbox scan, covering a single account
    /// (`account: nil` scans Mail's local On-My-Mac boxes).
    ///
    /// Every field is read with a bulk column fetch -- `mbox.messages.subject()`
    /// and friends -- which costs one Apple Event per column per mailbox no
    /// matter how many messages it holds: 14,000 subjects come back in about a
    /// second. Three things are deliberately absent, all measured against a
    /// 14,004-message mailbox:
    ///
    /// * Individual `messages[i].prop()` access. Resolving one element walks the
    ///   collection, so a single property read costs ~13ms on a small mailbox and
    ///   ~150ms on a large one, versus 0.07ms/message in bulk.
    /// * Specifier `slice()`. It looks like the bounded fetch you want, but it
    ///   resolves element by element -- 200 ids took 22s while all 14,004 took 1s.
    /// * `whose()`. Mail evaluates it with an internal linear scan, ~10x slower
    ///   than fetching the column and filtering here; and `whose({content: ...})`
    ///   decodes every message body, which times out on a few hundred messages.
    ///
    /// Filtering and per-mailbox trimming therefore happen in JS, on plain
    /// arrays that have already been fetched. The `slice` below is `Array.slice`
    /// on those results, not a specifier slice -- cheap, and not to be confused
    /// with the case above.
    private static func scanScriptJXA(
        account: String?,
        mailbox: String,
        query: String?,
        searchRecipients: Bool,
        limit: Int
    ) -> String {
        let collect = collectBoxesJXA(account.map { BoxScope.account($0) } ?? .local, varName: "allBoxes")

        let filter: String
        if mailbox.lowercased() == "all" {
            // Object.create(null) rather than {}: a mailbox named "constructor"
            // or "toString" would otherwise inherit a truthy Object.prototype
            // value and be silently dropped from the scan.
            filter = """
        var SKIP = Object.create(null);
        ['trash','junk','spam','junk email','deleted items','deleted messages','drafts','outbox']
            .forEach(function(n) { SKIP[n] = 1; });
        var entries = allBoxes.filter(function(b) { return !SKIP[b.name.toLowerCase()]; });
        """
        } else {
            let escaped = escapeJSString(mailbox)
            // A miss here is normal -- the caller scans each account separately
            // and only reports "no such mailbox" if every account came up empty.
            filter = """
        var entries = allBoxes.filter(function(b) { return b.name.toLowerCase() === '\(escaped)'.toLowerCase(); });
        """
        }

        let queryLine = query.map { "var QUERY = '\(escapeJSString($0))'.toLowerCase();" } ?? "var QUERY = null;"
        let recipientFetch = !searchRecipients ? "" : """
                tos = mb.messages.toRecipients.address();
                ccs = mb.messages.ccRecipients.address();
                tns = mb.messages.toRecipients.name();
                cns = mb.messages.ccRecipients.name();
        """
        let recipientMatch = !searchRecipients ? "" : """
                        hay += ' ' + (tos[i] || []).join(' ') + ' ' + (ccs[i] || []).join(' ')
                             + ' ' + (tns[i] || []).join(' ') + ' ' + (cns[i] || []).join(' ');
        """

        return """
        var mail = Application('Mail');
        \(queryLine)
        var LIMIT = \(max(limit, 1));
        \(collect)
        \(filter)

        var rows = [], scanned = [], skipped = [], total = 0, messagesScanned = 0;
        // Gmail-style accounts file every message in both INBOX and "All Mail",
        // so ids are deduplicated across this account's mailboxes. Without it
        // `total` counts each message once per mailbox it appears in.
        var seen = Object.create(null);
        for (var e = 0; e < entries.length; e++) {
            var label = entries[e].acctName + ':' + entries[e].name;
            try {
                var mb = entries[e].mbox;
                var ids = mb.messages.id();
                if (ids.length > 0) {
                    var su = mb.messages.subject();
                    var se = mb.messages.sender();
                    var dt = mb.messages.dateReceived();
                    var rd = mb.messages.readStatus();
                    var tos = null, ccs = null, tns = null, cns = null;
        \(recipientFetch)
                    messagesScanned += ids.length;
                    var local = [];
                    for (var i = 0; i < ids.length; i++) {
                        var id = '' + ids[i];
                        if (seen[id]) continue;
                        seen[id] = true;
                        if (QUERY !== null) {
                            var hay = (su[i] == null ? '' : '' + su[i]) + ' ' + (se[i] == null ? '' : '' + se[i]);
        \(recipientMatch)
                            if (hay.toLowerCase().indexOf(QUERY) === -1) continue;
                        }
                        local.push({
                            id: id,
                            account: entries[e].acctName,
                            mailbox: entries[e].name,
                            subject: su[i] == null ? '' : '' + su[i],
                            sender: se[i] == null ? '' : '' + se[i],
                            date_received: dt[i] ? '' + dt[i] : '',
                            read: rd[i] ? true : false,
                            t: dt[i] ? dt[i].getTime() : 0
                        });
                    }
                    total += local.length;
                    local.sort(function(x, y) { return y.t - x.t; });
                    if (local.length > LIMIT) local = local.slice(0, LIMIT);
                    for (var q = 0; q < local.length; q++) rows.push(local[q]);
                }
                scanned.push(label);
            } catch (err) {
                skipped.push(label);
            }
        }
        JSON.stringify({rows: rows, total: total, scanned: scanned, skipped: skipped, matched: entries.length, messages_scanned: messagesScanned});
        """
    }

    /// Wall-clock allowance per message body. Mail needs ~1.2s to read and
    /// decode one off disk; the rest is headroom for slow disks and spawn cost.
    private static let bodyFetchBudget: TimeInterval = 3

    /// Hard ceiling on `body_scan_limit`, so the body pass cannot be talked into
    /// an arbitrarily long blocking run.
    private static let maxBodyScanLimit = 200

    /// Identifies one mailbox within one account.
    private struct MailboxKey: Hashable {
        let account: String
        let mailbox: String
    }

    /// Result of scanning every account, already merged and sorted newest-first.
    private struct ScanOutcome {
        var rows: [[String: Any]] = []
        var total = 0
        var messagesScanned = 0
        var scanned: [String] = []
        var skipped: [String] = []
        var failed: [String] = []
        var matchedMailbox = false
    }

    /// Fetches the configured account names in one cheap call (~0.2s).
    /// `scopable` is passed straight through to the timeout message. Listing
    /// accounts has nothing to narrow when it is the whole request; when it is
    /// the first step of a scan, passing an `account` would skip it entirely.
    private static func accountNames(scopable: Bool) -> (names: [String], error: String?) {
        let script = """
        var mail = Application('Mail');
        var a = mail.accounts();
        var out = [];
        for (var i = 0; i < a.length; i++) out.push('' + a[i].name());
        JSON.stringify(out);
        """
        let (output, error) = runJXA(script, timeout: 30, scopable: scopable)
        if let error { return ([], error) }
        guard let data = output.data(using: .utf8),
              let names = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return ([], "could not parse account list from Mail")
        }
        return (names, nil)
    }

    /// Expands the `account` argument into scan targets. A named account scans
    /// only that account; omitting it scans every account plus the local
    /// On-My-Mac mailboxes.
    private static func resolveTargets(account: String?) -> (targets: [String?], error: String?) {
        if let account { return ([account], nil) }
        let (names, error) = accountNames(scopable: true)
        if let error { return ([], error) }
        return (names.map { Optional($0) } + [nil], nil)
    }

    /// Runs one scan per account in its own osascript process, then merges.
    ///
    /// Per-account processes keep a wedged account from taking down the whole
    /// request: it lands in `failed` and the other accounts still return. Going
    /// finer than this (one process per mailbox) is counterproductive -- process
    /// startup is ~150ms, which across 90 mailboxes costs more than the scan.
    private static func scanAllAccounts(
        targets: [String?],
        mailbox: String,
        query: String?,
        searchRecipients: Bool,
        limit: Int,
        timeout: TimeInterval
    ) -> ScanOutcome {
        var outcome = ScanOutcome()
        // A `nil` target is Mail's local On-My-Mac mailboxes.
        for account in targets {
            let label = account ?? "On My Mac"
            let script = scanScriptJXA(
                account: account,
                mailbox: mailbox,
                query: query,
                searchRecipients: searchRecipients,
                limit: limit
            )
            let (output, error) = runJXA(script, timeout: timeout, scopable: true)
            if let error {
                outcome.failed.append("\(label): \(error)")
                continue
            }
            guard let data = output.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                outcome.failed.append("\(label): could not parse scan result")
                continue
            }
            outcome.rows.append(contentsOf: obj["rows"] as? [[String: Any]] ?? [])
            outcome.total += obj["total"] as? Int ?? 0
            outcome.messagesScanned += obj["messages_scanned"] as? Int ?? 0
            outcome.scanned.append(contentsOf: obj["scanned"] as? [String] ?? [])
            outcome.skipped.append(contentsOf: obj["skipped"] as? [String] ?? [])
            if (obj["matched"] as? Int ?? 0) > 0 { outcome.matchedMailbox = true }
        }
        sortNewestFirst(&outcome.rows)
        return outcome
    }

    /// Sorts rows newest-first. `Array.sort` is not stable, so id breaks ties:
    /// without it the mailbox a duplicated message is attributed to changes
    /// between otherwise identical calls.
    private static func sortNewestFirst(_ rows: inout [[String: Any]]) {
        rows.sort { a, b in
            let ta = a["t"] as? Double ?? 0
            let tb = b["t"] as? Double ?? 0
            if ta != tb { return ta > tb }
            return (a["id"] as? String ?? "") < (b["id"] as? String ?? "")
        }
    }

    /// Drops the internal sort key, removes ids seen in an earlier mailbox, and
    /// applies the caller's limit. Rows arrive newest-first, so the copy kept is
    /// the newest one.
    private static func presentRows(_ rows: [[String: Any]], limit: Int) -> [[String: Any]] {
        let cap = max(limit, 0)
        var seen = Set<String>()
        var out: [[String: Any]] = []
        out.reserveCapacity(min(rows.count, cap))
        for row in rows {
            if out.count >= cap { break }
            if let id = row["id"] as? String, !seen.insert(id).inserted { continue }
            var copy = row
            copy.removeValue(forKey: "t")
            out.append(copy)
        }
        return out
    }

    /// The two error paths every scan-backed handler shares. Returns nil when
    /// the scan produced something worth reporting.
    private static func scanFailure(_ outcome: ScanOutcome, targets: [String?], mailbox: String) -> MCPCallResult? {
        if outcome.failed.count == targets.count {
            return errorResult("scan failed for every account — \(outcome.failed.joined(separator: "; "))")
        }
        if !outcome.matchedMailbox && mailbox.lowercased() != "all" {
            return errorResult("no mailbox named \"\(mailbox)\" found — use mail_list_mailboxes to see available names, or pass mailbox \"all\"")
        }
        return nil
    }

    /// JXA snippet that finds a message by ID. Looks in mailboxes matching the
    /// requested name first, then falls back to every other mailbox so messages
    /// surfaced by all-mailbox search can still be fetched by id. Defines
    /// `found` (message or null), `foundAccount`, and `foundMailbox`.
    ///
    /// An identifier containing `@` is treated as an RFC 5322 Message-ID and
    /// matched against the `message id` column instead of Mail's numeric one.
    /// That matters for drafts on IMAP accounts: saving a draft uploads it, the
    /// server hands back its own copy, and Mail's numeric id for the local one
    /// is dead within seconds — while the Message-ID header survives the round
    /// trip. Angle brackets are optional on either side of the comparison.
    private static func findMessageJXA(account: String?, mailbox: String, messageId: String) -> String {
        let escapedMailbox = escapeJSString(mailbox)
        let escapedId = escapeJSString(messageId)
        return """
    \(collectBoxesJXA(account: account, varName: "fmBoxes"))
    var found = null; var foundAccount = null; var foundMailbox = null;
    (function() {
        var targetLC = '\(escapedMailbox)'.toLowerCase();
        var TARGET = '\(escapedId)'.replace(/^</, '').replace(/>$/, '');
        var BY_RFC = TARGET.indexOf('@') !== -1;
        function searchIn(subset) {
            for (var i = 0; i < subset.length; i++) {
                var ids;
                try {
                    ids = BY_RFC ? subset[i].mbox.messages.messageId() : subset[i].mbox.messages.id();
                } catch (e) { continue; }
                for (var k = 0; k < ids.length; k++) {
                    if (ids[k] == null) continue;
                    var candidate = ('' + ids[k]).replace(/^</, '').replace(/>$/, '');
                    if (candidate === TARGET) {
                        found = subset[i].mbox.messages[k];
                        foundAccount = subset[i].acctName;
                        foundMailbox = subset[i].name;
                        return true;
                    }
                }
            }
            return false;
        }
        var named = []; var rest = [];
        for (var i = 0; i < fmBoxes.length; i++) {
            if (fmBoxes[i].name.toLowerCase() === targetLC) named.push(fmBoxes[i]); else rest.push(fmBoxes[i]);
        }
        if (!searchIn(named)) searchIn(rest);
    })();
    """
    }

    /// JXA snippet resolving a mailbox by name *inside one account*, named by a
    /// JavaScript expression evaluated at run time.
    ///
    /// The run-time expression is the whole point. A destination mailbox has to
    /// be resolved relative to the account the message was actually found in,
    /// and that is only known once `findMessageJXA` has run — it comes back in
    /// `foundAccount`. Resolving by name across every account instead picks
    /// whichever account Mail happens to list first, which is how a message in
    /// Bob's INBOX ended up in *Alice's* Archive with the source copy gone:
    /// every account has an `Archive`, a `Sent`, a `Trash` and a `Drafts`, so
    /// the collision is the normal case rather than an unlucky one.
    ///
    /// Sets `<varName>` to the mailbox and `<varName>Account` to the name of the
    /// account it came from, so the caller can report where the message went.
    /// Throws when the account has no mailbox of that name — deliberately,
    /// rather than falling back to another account's copy.
    private static func mailboxInAccountJXA(
        mailbox: String,
        accountExpr: String,
        varName: String = "mbox"
    ) -> String {
        let escapedMailbox = escapeJSString(mailbox)
        return """
    var \(varName)Account = null;
    var \(varName) = (function() {
        var wantName = '\(escapedMailbox)'.toLowerCase();
        var wantAcct = \(accountExpr);
        function pick(boxes) {
            for (var i = 0; i < boxes.length; i++) {
                if (('' + boxes[i].name()).toLowerCase() === wantName) return boxes[i];
            }
            return null;
        }
        if (wantAcct !== null && ('' + wantAcct).toLowerCase() !== 'on my mac') {
            var accts = mail.accounts();
            for (var a = 0; a < accts.length; a++) {
                if (('' + accts[a].name()).toLowerCase() === ('' + wantAcct).toLowerCase()) {
                    var hit = pick(accts[a].mailboxes());
                    if (hit) { \(varName)Account = '' + accts[a].name(); return hit; }
                    throw new Error('account "' + accts[a].name() + '" has no mailbox named "\(escapedMailbox)"');
                }
            }
            throw new Error('account not found: ' + wantAcct);
        }
        var localHit = pick(mail.mailboxes());
        if (localHit) { \(varName)Account = 'On My Mac'; return localHit; }
        throw new Error('no mailbox named "\(escapedMailbox)" in On My Mac');
    })();
    """
    }

    /// Returns JXA snippets to set the sender address. `from` takes precedence over `account` lookup.
    private static func senderJXA(from: String?, account: String?) -> (lines: String, prop: String) {
        if let from = from {
            let escapedFrom = escapeJSString(from)
            return ("var senderAddr = '\(escapedFrom)';", "msg.sender = senderAddr;")
        }
        if let account = account {
            let escapedAccount = escapeJSString(account)
            let lines = """
            var senderAddr = (function() {
                var accts = mail.accounts();
                for (var i = 0; i < accts.length; i++) {
                    if (accts[i].name().toLowerCase() === '\(escapedAccount)'.toLowerCase()) {
                        var addrs = accts[i].emailAddresses();
                        if (addrs.length > 0) return addrs[0];
                        throw new Error('account has no email addresses: \(escapedAccount)');
                    }
                }
                throw new Error('account not found: \(escapedAccount)');
            })();
            """
            return (lines, "msg.sender = senderAddr;")
        }
        return ("", "")
    }

    // MARK: - Tool Handlers

    private static func listAccounts(_ args: JSONObject?) -> MCPCallResult {
        // Empty input schema: there is no account, no mailbox and no limit to
        // pass, so "narrow the scope" would be advice the caller cannot follow.
        let (names, error) = accountNames(scopable: false)
        if let error { return errorResult(error) }
        return jsonResult(names)
    }

    private static func listMailboxes(_ args: JSONObject?) -> MCPCallResult {
        let account = args?["account"]?.stringValue
        let script: String
        if let account {
            let escaped = escapeJSString(account)
            script = """
            var mail = Application('Mail');
            var accts = mail.accounts();
            var acct = null;
            for (var i = 0; i < accts.length; i++) {
                if (accts[i].name().toLowerCase() === '\(escaped)'.toLowerCase()) { acct = accts[i]; break; }
            }
            if (!acct) throw new Error('account not found: \(escaped)');
            var mailboxes = acct.mailboxes();
            var names = [];
            for (var i = 0; i < mailboxes.length; i++) {
                names.push(mailboxes[i].name());
            }
            JSON.stringify(names);
            """
        } else {
            script = """
            var mail = Application('Mail');
            var accts = mail.accounts();
            var results = [];
            for (var i = 0; i < accts.length; i++) {
                var mboxes = accts[i].mailboxes();
                var names = [];
                for (var j = 0; j < mboxes.length; j++) {
                    names.push(mboxes[j].name());
                }
                results.push({account: accts[i].name(), mailboxes: names});
            }
            JSON.stringify(results);
            """
        }
        // Naming an account is the only narrowing this tool offers, so once one
        // has been given there is nothing left to suggest.
        let (output, error) = runJXA(script, scopable: account == nil)
        if let error { return errorResult(error) }
        return textResult(output)
    }

    private static func getEmails(_ args: JSONObject?) -> MCPCallResult {
        let mailbox = args?["mailbox"]?.stringValue ?? "INBOX"
        let limit = max(args?["limit"]?.intValue ?? 10, 0)
        let account = args?["account"]?.stringValue

        let (targets, targetError) = resolveTargets(account: account)
        if let targetError { return errorResult(targetError) }

        let outcome = scanAllAccounts(
            targets: targets,
            mailbox: mailbox,
            query: nil,
            searchRecipients: false,
            limit: limit,
            timeout: defaultTimeout
        )

        if let failure = scanFailure(outcome, targets: targets, mailbox: mailbox) { return failure }

        var payload: [String: Any] = [
            "messages": presentRows(outcome.rows, limit: limit),
            "total_messages": outcome.total,
            "truncated": outcome.total > limit,
            "messages_scanned": outcome.messagesScanned,
            "scanned_mailboxes": outcome.scanned,
            "skipped_mailboxes": outcome.skipped
        ]
        if !outcome.failed.isEmpty { payload["failed_accounts"] = outcome.failed }
        return jsonResult(payload)
    }

    private static func getEmail(_ args: JSONObject?) -> MCPCallResult {
        guard let messageId = args?["message_id"]?.stringValue else {
            return errorResult("message_id is required")
        }
        let mailbox = args?["mailbox"]?.stringValue ?? "INBOX"
        let findMessage = findMessageJXA(account: args?["account"]?.stringValue, mailbox: mailbox, messageId: messageId)

        let escapedId = escapeJSString(messageId)

        // Every property is read behind `safe`: a message carrying attachments
        // makes several of them raise "AppleEvent handler failed" (Mail's own
        // bug), and one bad property must not cost the caller the whole
        // message. `MIME type` on an attachment is not read at all -- it raises
        // on every message that has one -- so the type is inferred below from
        // the filename.
        let script = """
        var mail = Application('Mail');
        \(findMessage)
        function safe(fn, dflt) { try { var v = fn(); return v == null ? dflt : v; } catch (e) { return dflt; } }
        if (!found) {
            JSON.stringify({error: 'message not found with id: \(escapedId)'});
        } else {
            var atts = safe(function() {
                return found.mailAttachments().map(function(a) {
                    return {
                        name: safe(function() { return '' + a.name(); }, ''),
                        size: safe(function() { return a.fileSize(); }, 0),
                        downloaded: safe(function() { return a.downloaded(); }, false),
                        id: safe(function() { return '' + a.id(); }, '')
                    };
                });
            }, []);
            JSON.stringify({
                id: '' + safe(function() { return found.id(); }, ''),
                account: foundAccount,
                mailbox: foundMailbox,
                subject: safe(function() { return found.subject(); }, ''),
                sender: safe(function() { return found.sender(); }, ''),
                rfc_message_id: '' + safe(function() { return found.messageId(); }, ''),
                date_received: '' + safe(function() { return found.dateReceived(); }, ''),
                date_sent: '' + safe(function() { return found.dateSent(); }, ''),
                message_size: safe(function() { return found.messageSize(); }, 0),
                read: safe(function() { return found.readStatus(); }, false),
                to: safe(function() { return found.toRecipients().map(function(r) { return r.address(); }); }, []),
                cc: safe(function() { return found.ccRecipients().map(function(r) { return r.address(); }); }, []),
                attachments: atts,
                body: safe(function() { return found.content(); }, '')
            });
        }
        """
        let (output, error) = runJXA(script)
        if let error { return errorResult(error) }
        guard let data = output.data(using: .utf8),
              var payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return textResult(output)
        }
        if let message = payload["error"] as? String { return errorResult(message) }
        if var attachments = payload["attachments"] as? [[String: Any]] {
            for i in attachments.indices {
                attachments[i]["mime_type"] = MIME.mimeType(forFilename: attachments[i]["name"] as? String ?? "")
            }
            payload["attachments"] = attachments
            payload["has_attachments"] = !attachments.isEmpty
        }
        return jsonResult(payload)
    }

    /// Fetches message bodies for a bounded candidate set and returns the ones
    /// matching `query`.
    ///
    /// Body text is the one thing Apple Events cannot serve at scale: a body
    /// costs ~1.2s whether fetched individually or as a bulk `content()` column,
    /// because Mail has to read and decode the message off disk each time. Both
    /// `whose({content: ...})` and a bulk `content()` fetch time out on a few
    /// hundred messages. So body matching is a deliberately capped second pass
    /// over the newest candidates, and the caller is told the coverage.
    private static func matchBodies(
        candidates: [[String: Any]],
        query: String,
        deadline: Date
    ) -> (matches: [[String: Any]], scanned: Int, complete: Bool) {
        // Group by mailbox so each one costs a single bulk id fetch.
        var byMailbox: [MailboxKey: [[String: Any]]] = [:]
        for row in candidates {
            let key = MailboxKey(
                account: row["account"] as? String ?? "",
                mailbox: row["mailbox"] as? String ?? ""
            )
            byMailbox[key, default: []].append(row)
        }

        let needle = query.lowercased()
        var matches: [[String: Any]] = []
        var scanned = 0
        var complete = true

        for (key, rows) in byMailbox {
            let wanted = rows.compactMap { $0["id"] as? String }
            guard !wanted.isEmpty else { continue }

            // Budget per mailbox, not per request: the caller's deadline covers
            // the whole pass, and a group of two must not be given the whole of it.
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { complete = false; break }
            let budget = min(remaining, Double(rows.count) * bodyFetchBudget + 30)

            let escapedAccount = escapeJSString(key.account)
            let escapedMailbox = escapeJSString(key.mailbox)
            let wantedLiteral = wanted.map { "'\(escapeJSString($0))'" }.joined(separator: ",")
            // Locate by id rather than by stored index: messages arriving between
            // the metadata scan and this call would shift positions.
            let script = """
            var mail = Application('Mail');
            var WANT = Object.create(null);
            [\(wantedLiteral)].forEach(function(k) { WANT[k] = 1; });
            var mb = (function() {
                var boxes = [];
                var accts = mail.accounts();
                for (var i = 0; i < accts.length; i++) {
                    if (accts[i].name() === '\(escapedAccount)') { boxes = accts[i].mailboxes(); break; }
                }
                if (boxes.length === 0 && '\(escapedAccount)' === 'On My Mac') boxes = mail.mailboxes();
                for (var j = 0; j < boxes.length; j++) {
                    if ('' + boxes[j].name() === '\(escapedMailbox)') return boxes[j];
                }
                return null;
            })();
            var out = [];
            if (mb) {
                var ids = mb.messages.id();
                for (var i = 0; i < ids.length; i++) {
                    if (!WANT['' + ids[i]]) continue;
                    try { out.push({id: '' + ids[i], body: '' + mb.messages[i].content()}); } catch (e) {}
                }
            }
            JSON.stringify(out);
            """

            let (output, error) = runJXA(script, retries: 0, timeout: budget, scopable: true)
            if error != nil { complete = false; continue }
            guard let data = output.data(using: .utf8),
                  let fetched = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                complete = false
                continue
            }

            // uniquingKeysWith, not uniqueKeysWithValues: a mailbox holding the
            // same id twice would trap the server on the latter.
            let bodies = Dictionary(
                fetched.compactMap { entry -> (String, String)? in
                    guard let id = entry["id"] as? String, let body = entry["body"] as? String else { return nil }
                    return (id, body)
                },
                uniquingKeysWith: { first, _ in first }
            )
            scanned += bodies.count
            if bodies.count < rows.count { complete = false }
            for row in rows {
                guard let id = row["id"] as? String, let body = bodies[id] else { continue }
                if body.lowercased().contains(needle) { matches.append(row) }
            }
        }
        return (matches, scanned, complete)
    }

    private static func searchEmails(_ args: JSONObject?) -> MCPCallResult {
        guard let query = args?["query"]?.stringValue else {
            return errorResult("query is required")
        }
        let limit = max(args?["limit"]?.intValue ?? 10, 0)
        let mailbox = args?["mailbox"]?.stringValue ?? "all"
        let account = args?["account"]?.stringValue
        let searchRecipients = args?["search_recipients"]?.boolValue ?? false
        let searchBody = args?["search_body"]?.boolValue ?? false
        // Each body costs ~1.2s, so this stays small by default and is clamped at
        // both ends -- a negative value would trap in `prefix` below.
        let bodyScanLimit = min(max(args?["body_scan_limit"]?.intValue ?? 25, 0), maxBodyScanLimit)

        let (targets, targetError) = resolveTargets(account: account)
        if let targetError { return errorResult(targetError) }

        let outcome = scanAllAccounts(
            targets: targets,
            mailbox: mailbox,
            query: query,
            searchRecipients: searchRecipients,
            limit: limit,
            timeout: defaultTimeout
        )

        if let failure = scanFailure(outcome, targets: targets, mailbox: mailbox) { return failure }

        var rows = outcome.rows
        var total = outcome.total
        var bodyInfo: [String: Any]? = nil

        if searchBody {
            // Second pass: the newest messages in scope, regardless of whether
            // their metadata matched, so body-only hits can still surface.
            let sweep = scanAllAccounts(
                targets: targets,
                mailbox: mailbox,
                query: nil,
                searchRecipients: false,
                limit: bodyScanLimit,
                timeout: defaultTimeout
            )
            // The sweep re-reads the same messages the metadata pass did, so it
            // adds nothing to `messages_scanned` -- that field is documented as
            // scan coverage, not as work performed.

            // Skip anything the metadata pass already counted. Testing the row's
            // own subject/sender catches matches that `outcome.total` counted but
            // that the per-mailbox limit trimmed out of `rows` -- counting those
            // again here would inflate total_matches.
            let needle = query.lowercased()
            let returned = Set(rows.compactMap { $0["id"] as? String })
            let eligible = sweep.rows.filter { row in
                guard let id = row["id"] as? String, !returned.contains(id) else { return false }
                let meta = "\(row["subject"] as? String ?? "") \(row["sender"] as? String ?? "")"
                return !meta.lowercased().contains(needle)
            }
            let candidates = Array(eligible.prefix(bodyScanLimit))

            let (bodyMatches, bodiesRead, bodiesComplete) = matchBodies(
                candidates: candidates,
                query: query,
                // One deadline for the whole pass, sized to the candidates we
                // actually have rather than to the cap the caller asked for.
                deadline: Date().addingTimeInterval(Double(candidates.count) * bodyFetchBudget + 30)
            )
            rows.append(contentsOf: bodyMatches)
            sortNewestFirst(&rows)
            total += bodyMatches.count
            bodyInfo = [
                "bodies_read": bodiesRead,
                "body_matches": bodyMatches.count,
                "body_scan_limit": bodyScanLimit,
                // Complete only if every body was read AND nothing was dropped
                // on the way there: not by the candidate cap, and not by the
                // per-mailbox trim inside the sweep itself.
                "body_scan_complete": bodiesComplete
                    && candidates.count == eligible.count
                    && sweep.rows.count >= sweep.total
            ]
        }

        var payload: [String: Any] = [
            "messages": presentRows(rows, limit: limit),
            "total_matches": total,
            "truncated": total > limit,
            "messages_scanned": outcome.messagesScanned,
            "scanned_mailboxes": outcome.scanned,
            "skipped_mailboxes": outcome.skipped
        ]
        if let bodyInfo { payload["body_search"] = bodyInfo }
        if !outcome.failed.isEmpty { payload["failed_accounts"] = outcome.failed }
        return jsonResult(payload)
    }

    // MARK: - Composition

    /// Splits a recipient field into individual addresses.
    ///
    /// Accepts an array or a single string. A string is split on commas that
    /// sit outside quotes and angle brackets, so a display name like
    /// `"Cross, Susan" <s@example.org>` survives intact — the comma-joined form
    /// was already the only way to reach more than one recipient, so it keeps
    /// working, it just is no longer undefined behaviour.
    private static func recipientList(_ value: JSONValue?) -> [String] {
        guard let strings = value?.stringsValue else { return [] }
        return strings.flatMap(splitAddresses)
    }

    private static func splitAddresses(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inQuotes = false
        var angleDepth = 0
        for ch in s {
            switch ch {
            case "\"":
                inQuotes.toggle()
                current.append(ch)
            case "<" where !inQuotes:
                angleDepth += 1
                current.append(ch)
            case ">" where !inQuotes:
                angleDepth = max(0, angleDepth - 1)
                current.append(ch)
            case "," where !inQuotes && angleDepth == 0:
                out.append(current)
                current = ""
            default:
                current.append(ch)
            }
        }
        out.append(current)
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Splits `Display Name <addr@host>` apart. Mail keeps name and address in
    /// separate properties; handed the combined form it files the whole string
    /// as the address.
    private static func parseAddress(_ s: String) -> (name: String?, address: String) {
        guard let open = s.lastIndex(of: "<"),
              let close = s.lastIndex(of: ">"),
              open < close else {
            return (nil, s)
        }
        let address = String(s[s.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
        var name = String(s[s.startIndex..<open]).trimmingCharacters(in: .whitespaces)
        if name.count >= 2 && name.hasPrefix("\"") && name.hasSuffix("\"") {
            name = String(name.dropFirst().dropLast())
        }
        return (name.isEmpty ? nil : name, address.isEmpty ? s : address)
    }

    private static func recipientLinesJXA(_ addresses: [String], className: String, collection: String) -> String {
        addresses.map { entry in
            let parsed = parseAddress(entry)
            let nameProp = parsed.name.map { ", name: '\(escapeJSString($0))'" } ?? ""
            return "msg.\(collection).push(mail.\(className)({address: '\(escapeJSString(parsed.address))'\(nameProp)}));"
        }.joined(separator: "\n")
    }

    /// Rough count of the visible characters in an HTML fragment, used only to
    /// decide whether an empty rendered body means Mail rejected the HTML.
    private static func visibleTextLength(inHTML html: String) -> Int {
        var count = 0
        var inTag = false
        for ch in html {
            if ch == "<" { inTag = true; continue }
            if ch == ">" { inTag = false; continue }
            if !inTag && !ch.isWhitespace { count += 1 }
        }
        return count
    }

    /// Turns the `attachments` argument into verified absolute paths.
    private static func attachmentPaths(_ value: JSONValue?) -> (paths: [String], error: String?) {
        guard let raw = value?.stringsValue, !raw.isEmpty else { return ([], nil) }
        var paths: [String] = []
        var missing: [String] = []
        for entry in raw {
            let expanded = (entry as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), !isDirectory.boolValue {
                paths.append(expanded)
            } else {
                missing.append(entry)
            }
        }
        if !missing.isEmpty {
            return ([], "attachment not found: \(missing.joined(separator: ", "))")
        }
        return (paths, nil)
    }

    /// JXA that attaches each file after the body.
    ///
    /// `attachments.push` puts the file at the *start* of the message — the
    /// paperclip lands above the text — so the attachment is made at a position
    /// after the last paragraph instead, which is the AppleScript idiom. The
    /// paragraph count is re-read each time because attaching changes it, and
    /// an empty body has no paragraph to insert after, so that case falls back
    /// to push. The settle delay before saving or sending is Mail's long-
    /// standing quirk: a large attachment is still being copied in when the
    /// save command arrives, and the draft is written without it.
    private static func attachmentsJXA(_ paths: [String]) -> String {
        guard !paths.isEmpty else { return "" }
        let literals = paths.map { "'\(escapeJSString($0))'" }.joined(separator: ", ")
        var totalBytes = 0
        for path in paths {
            totalBytes += (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int)
                .flatMap { $0 } ?? 0
        }
        let settle = min(0.5 + Double(totalBytes) / 5_000_000, 8.0)
        return """
        var ATTACHMENTS = [\(literals)];
        for (var ai = 0; ai < ATTACHMENTS.length; ai++) {
            var paras = msg.content.paragraphs;
            var pcount = paras.length;
            if (pcount > 0) {
                mail.make({new: 'attachment', at: paras.at(pcount - 1).after, withProperties: {fileName: Path(ATTACHMENTS[ai])}});
            } else {
                msg.content.attachments.push(mail.Attachment({fileName: Path(ATTACHMENTS[ai])}));
            }
        }
        $.NSThread.sleepForTimeInterval(\(String(format: "%.2f", settle)));
        """
    }

    /// JXA that refuses to hand the message on unless it is addressed to
    /// exactly who the caller asked for.
    ///
    /// This is the last line of defence against sending to the wrong person.
    /// It has already happened once: with several compose windows open, the
    /// reference returned by `OutgoingMessage()` bound to a pre-existing window
    /// instead of the new message, and `send()` delivered that window's
    /// recipient. `resolveOutgoingJXA` should make that impossible, but the
    /// cost of being wrong is mail leaving the machine, so what Mail actually
    /// holds is read back and compared before anything is sent or saved.
    private static func recipientGuardJXA(to: [String], cc: [String], bcc: [String], subject: String) -> String {
        let expected = (to + cc + bcc)
            .map { parseAddress($0).address.lowercased() }
            .map { "'\(escapeJSString($0))'" }
            .joined(separator: ", ")
        return """
        (function() {
            function addressesOf(list) {
                var out = [];
                for (var i = 0; i < list.length; i++) {
                    var a = null;
                    try { a = list[i].address(); } catch (e) {}
                    if (a) out.push(('' + a).toLowerCase());
                }
                return out;
            }
            var actual = addressesOf(msg.toRecipients())
                .concat(addressesOf(msg.ccRecipients()))
                .concat(addressesOf(msg.bccRecipients()));
            var expected = [\(expected)];
            var missing = expected.filter(function(a) { return actual.indexOf(a) === -1; });
            var extra = actual.filter(function(a) { return expected.indexOf(a) === -1; });
            var wrongSubject = ('' + msg.subject()) !== '\(escapeJSString(subject))';
            if (missing.length || extra.length || wrongSubject) {
                try { msg.close({saving: 'no'}); } catch (e) {}
                throw new Error('aborted before sending: Mail has this message addressed to ['
                    + actual.join(', ') + '] with subject "' + msg.subject() + '", not ['
                    + expected.join(', ') + ']. Nothing was sent or saved.');
            }
        })();
        """
    }

    /// JXA that pins `msg` to the outgoing message just created.
    ///
    /// The reference `OutgoingMessage()` hands back is not reliably the message
    /// that `push` added — with other compose windows open it can resolve to
    /// one of those instead, which is how a test send once went to a stranger's
    /// address that appeared nowhere in the request. `id` is assigned on
    /// creation and read-only, so re-finding the message by id in the live
    /// collection gives an unambiguous reference to mutate and send.
    private static let resolveOutgoingJXA = """
    var newMessageId = draft.id();
    var msg = (function() {
        var open = mail.outgoingMessages();
        for (var i = 0; i < open.length; i++) {
            var candidate = null;
            try { candidate = open[i].id(); } catch (e) { continue; }
            if (candidate === newMessageId) return open[i];
        }
        return null;
    })();
    if (!msg) { throw new Error('could not identify the newly created message in Mail; nothing was sent or saved'); }
    """

    /// Shared email composition: validates params, builds JXA, runs it.
    /// `visible` controls whether a compose window opens. `finalAction` is the
    /// JXA run once the message is fully built, and must leave a `result`
    /// object in scope for the caller to return.
    private static func composeEmail(
        _ args: JSONObject?,
        visible: Bool,
        finalAction: String
    ) -> MCPCallResult {
        let to = recipientList(args?["to"])
        guard !to.isEmpty else {
            return errorResult("to is required")
        }
        guard let subject = args?["subject"]?.stringValue else {
            return errorResult("subject is required")
        }
        let body = args?["body"]?.stringValue
        let htmlBody = args?["html_body"]?.stringValue
        guard body != nil || htmlBody != nil else {
            return errorResult("body or html_body is required")
        }

        let (attachments, attachmentError) = attachmentPaths(args?["attachments"])
        if let attachmentError { return errorResult(attachmentError) }

        // `html content` and `content` are the same underlying body, and the
        // HTML wins when both are set, so only one is sent. Mail generates the
        // plain-text alternative part itself.
        let contentProp: String
        if let htmlBody {
            contentProp = "htmlContent: '\(escapeJSString(htmlBody))'"
        } else {
            contentProp = "content: '\(escapeJSString(body ?? ""))'"
        }

        var recipientLines = recipientLinesJXA(to, className: "Recipient", collection: "toRecipients")
        let cc = recipientList(args?["cc"])
        if !cc.isEmpty {
            recipientLines += "\n" + recipientLinesJXA(cc, className: "CcRecipient", collection: "ccRecipients")
        }
        let bcc = recipientList(args?["bcc"])
        if !bcc.isEmpty {
            recipientLines += "\n" + recipientLinesJXA(bcc, className: "BccRecipient", collection: "bccRecipients")
        }

        let senderSnippet = senderJXA(from: args?["from"]?.stringValue, account: args?["account"]?.stringValue)
        let visibleProp = visible ? "" : ",\n    visible: false"

        // `html content` is marked deprecated in Mail's dictionary ("does
        // nothing at all") but in fact still renders when set at creation. If a
        // future Mail makes good on the deprecation the body would silently
        // come out empty, so it is checked rather than assumed.
        let htmlGuard = htmlBody.map { html in
            visibleTextLength(inHTML: html) == 0 ? "" : """
            if (renderedChars === 0) {
                try { msg.close({saving: 'no'}); } catch (e) {}
                throw new Error('Mail produced an empty body from html_body — this build of Mail no longer accepts HTML. Resend using body instead.');
            }
            """
        } ?? ""

        let script = """
        ObjC.import('Foundation');
        var mail = Application('Mail');
        \(senderSnippet.lines)
        var draft = mail.OutgoingMessage({
            subject: '\(escapeJSString(subject))',
            \(contentProp)\(visibleProp)
        });
        mail.outgoingMessages.push(draft);
        \(resolveOutgoingJXA)
        \(recipientLines)
        \(senderSnippet.prop)
        \(attachmentsJXA(attachments))
        var renderedChars = 0;
        try { renderedChars = ('' + msg.content()).replace(/\\s+/g, '').length; } catch (e) {}
        \(htmlGuard)
        \(recipientGuardJXA(to: to, cc: cc, bcc: bcc, subject: subject))
        var result = {
            recipients: {to: \(to.count), cc: \(cc.count), bcc: \(bcc.count)},
            attachments: \(attachments.count),
            content_type: '\(htmlBody != nil ? "html" : "text")',
            rendered_chars: renderedChars
        };
        \(finalAction)
        JSON.stringify(result);
        """
        // Composing has no scope: the message is the message.
        let (output, error) = runJXA(script, retries: 0, scopable: false)
        if let error { return errorResult(error) }
        guard let data = output.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return textResult(output)
        }
        return jsonResult(payload)
    }

    /// Composed invisibly on purpose. Composing with `visible: true` puts a real
    /// window on screen, and a frontmost compose window is something Mail can
    /// act on in place of the message the script is holding — which is how a
    /// send once went out to the recipient of an unrelated window the user had
    /// open, rather than the address that was passed in. Nothing is gained by
    /// the window: `send` needs no UI.
    private static func sendEmail(_ args: JSONObject?) -> MCPCallResult {
        composeEmail(args, visible: false, finalAction: """
        msg.send();
        result.status = 'sent';
        """)
    }

    /// After saving, the draft is looked up and its identifiers returned.
    ///
    /// This is what makes a draft verifiable. Mail's numeric id for a freshly
    /// saved IMAP draft is short-lived — the server takes the upload and hands
    /// back its own copy, and the local one is gone — so the RFC Message-ID
    /// goes back too, and `mail_get_email` accepts either.
    private static func createDraft(_ args: JSONObject?) -> MCPCallResult {
        let account = args?["account"]?.stringValue
        let from = args?["from"]?.stringValue
        let subject = args?["subject"]?.stringValue ?? ""

        let acctExpr = account.map { "'\(escapeJSString($0))'.toLowerCase()" } ?? "null"
        let fromExpr = from.map { "'\(escapeJSString($0))'.toLowerCase()" } ?? "null"

        let finalAction = """
        mail.save(msg);
        result.status = 'draft created';
        // Let the account file the saved draft before looking for it.
        $.NSThread.sleepForTimeInterval(1.5);
        result.draft = (function() {
            var wantAcct = \(acctExpr);
            var wantFrom = \(fromExpr);
            var SUBJECT = '\(escapeJSString(subject))';
            try {
                var accts = mail.accounts();
                for (var i = 0; i < accts.length; i++) {
                    var name = '' + accts[i].name();
                    var match = wantAcct !== null && name.toLowerCase() === wantAcct;
                    if (!match && wantFrom !== null) {
                        var addrs = accts[i].emailAddresses();
                        for (var a = 0; a < addrs.length; a++) {
                            if (('' + addrs[a]).toLowerCase() === wantFrom) { match = true; break; }
                        }
                    }
                    if (!match) continue;
                    var mbs = accts[i].mailboxes();
                    for (var j = 0; j < mbs.length; j++) {
                        if (('' + mbs[j].name()).toLowerCase() !== 'drafts') continue;
                        var ids = mbs[j].messages.id();
                        var subs = mbs[j].messages.subject();
                        var rfcs = mbs[j].messages.messageId();
                        var best = -1;
                        for (var k = 0; k < ids.length; k++) {
                            if (('' + subs[k]) !== SUBJECT) continue;
                            if (best < 0 || ids[k] > ids[best]) best = k;
                        }
                        if (best >= 0) {
                            return {
                                account: name,
                                mailbox: '' + mbs[j].name(),
                                message_id: '' + ids[best],
                                rfc_message_id: rfcs[best] == null ? '' : '' + rfcs[best]
                            };
                        }
                    }
                }
            } catch (e) { return {lookup_error: '' + e}; }
            return null;
        })();
        """
        return composeEmail(args, visible: false, finalAction: finalAction)
    }

    // MARK: - Attachments and raw source

    /// Wall-clock allowance for a `source` fetch. A 5.9 MB message takes a few
    /// seconds; the ceiling is generous because the alternative to waiting is
    /// having no way to reach the attachment at all.
    private static let sourceFetchTimeout: TimeInterval = 180

    /// Fetches one message's raw RFC 822 source.
    ///
    /// The source goes to stdout, which `runJXAData` has already pointed at a
    /// file, so multi-megabyte messages are fine. A miss throws inside the
    /// script rather than printing a marker, because any marker printed on
    /// stdout could also be a legitimate first line of a message.
    /// Recovers a message's real bytes from what osascript wrote to stdout.
    ///
    /// `found.source()` is a JavaScript string, and Mail builds it by decoding
    /// the message's raw bytes as ISO-8859-1. osascript then writes that string
    /// out as UTF-8. The bytes that arrive are therefore one encoding layer
    /// removed from the message: every byte above 0x7F comes through UTF-8
    /// double-encoded, so `Content-Transfer-Encoding: 8bit` mail arrives as
    /// mojibake and a non-base64 attachment is written to disk as something
    /// that is not the attachment. (Base64 is pure ASCII, which is why the
    /// corruption goes unnoticed in ordinary use.)
    ///
    /// The transform is exactly invertible, so undoing it is one step: decode
    /// the stdout bytes as UTF-8, then re-encode as ISO-8859-1. Both halves are
    /// guarded. If stdout is not valid UTF-8, or if the string holds a scalar
    /// above U+00FF -- which is what a future Mail that decoded the source
    /// correctly would produce -- the bytes are handed back untouched rather
    /// than mangled a second time.
    ///
    /// osascript also appends a newline after the script's result, and that
    /// newline is not part of the message. It is dropped: exactly one is added,
    /// unconditionally, whether or not the value already ended in one.
    ///
    /// Known limit: a NUL byte in the message does not survive the text channel
    /// at all -- it reaches stdout as U+0080 -- so a message carrying one
    /// cannot be recovered byte-for-byte by this or any other decoding here.
    static func decodeSourceBytes(_ raw: Data) -> Data {
        var data = raw
        if data.last == 0x0A { data = data.dropLast() }
        guard let text = String(data: data, encoding: .utf8),
              let recovered = text.data(using: .isoLatin1) else {
            return data
        }
        return recovered
    }

    private static func fetchSource(
        account: String?,
        mailbox: String,
        messageId: String
    ) -> (data: Data, error: String?) {
        let script = """
        var mail = Application('Mail');
        \(findMessageJXA(account: account, mailbox: mailbox, messageId: messageId))
        if (!found) { throw new Error('message not found with id: \(escapeJSString(messageId))'); }
        '' + found.source();
        """
        let (data, error) = runJXAData(script, retries: 0, timeout: sourceFetchTimeout, scopable: true)
        if let error {
            if error.contains("message not found") {
                return (Data(), "message not found with id: \(messageId)")
            }
            return (Data(), error)
        }
        return (decodeSourceBytes(data), nil)
    }

    /// Strips anything that could steer a filename out of the destination
    /// directory. Mail filenames come from the sender and are not trustworthy.
    private static func safeFilename(_ name: String) -> String {
        var cleaned = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\u{0}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.isEmpty ? "attachment" : cleaned
    }

    /// Returns a path that does not already exist, by suffixing " (2)", " (3)"…
    private static func uniquePath(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        var n = 2
        while n < 1000 {
            let candidate = dir.appendingPathComponent(
                ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            )
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
        return url
    }

    private static func saveAttachment(_ args: JSONObject?) -> MCPCallResult {
        guard let messageId = args?["message_id"]?.stringValue else {
            return errorResult("message_id is required")
        }
        guard let destinationArg = args?["destination"]?.stringValue else {
            return errorResult("destination is required")
        }
        let mailbox = args?["mailbox"]?.stringValue ?? "INBOX"
        let overwrite = args?["overwrite"]?.boolValue ?? false

        let (data, fetchError) = fetchSource(
            account: args?["account"]?.stringValue,
            mailbox: mailbox,
            messageId: messageId
        )
        if let fetchError { return errorResult(fetchError) }

        let all = MIME.attachments(of: MIME.parse(data))
        guard !all.isEmpty else {
            return errorResult("message \(messageId) has no attachments")
        }

        var selected = all
        if let index = args?["index"]?.intValue {
            guard index >= 0 && index < all.count else {
                return errorResult("index \(index) out of range — message has \(all.count) attachment(s)")
            }
            selected = [all[index]]
        } else if let wanted = args?["attachment_name"]?.stringValue {
            let needle = wanted.lowercased()
            selected = all.filter { $0.name.lowercased() == needle }
            if selected.isEmpty { selected = all.filter { $0.name.lowercased().contains(needle) } }
            guard !selected.isEmpty else {
                return errorResult("no attachment matching \"\(wanted)\" — message has: \(all.map(\.name).joined(separator: ", "))")
            }
        }

        // A destination that exists as a directory, or that carries no file
        // extension, is a folder to drop files into. Anything else is a full
        // path, which only makes sense for a single attachment.
        let destination = URL(fileURLWithPath: (destinationArg as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory)
        let treatAsDirectory = (exists && isDirectory.boolValue)
            || (!exists && destination.pathExtension.isEmpty)
        if !treatAsDirectory && selected.count > 1 {
            return errorResult("destination \"\(destinationArg)\" is a file path but \(selected.count) attachments were selected — pass a directory, or narrow with attachment_name or index")
        }

        let directory = treatAsDirectory ? destination : destination.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return errorResult("could not create \(directory.path): \(error.localizedDescription)")
        }

        var saved: [[String: Any]] = []
        for attachment in selected {
            var target = treatAsDirectory
                ? directory.appendingPathComponent(safeFilename(attachment.name))
                : destination
            if !overwrite { target = uniquePath(target) }
            do {
                try attachment.data.write(to: target)
            } catch {
                return errorResult("could not write \(target.path): \(error.localizedDescription)")
            }
            saved.append([
                "name": attachment.name,
                "path": target.path,
                "bytes": attachment.data.count,
                "mime_type": attachment.mimeType,
                "inline": attachment.inline
            ])
        }

        return jsonResult([
            "saved": saved,
            "attachments_in_message": all.count,
            "message_id": messageId
        ])
    }

    private static func getSource(_ args: JSONObject?) -> MCPCallResult {
        guard let messageId = args?["message_id"]?.stringValue else {
            return errorResult("message_id is required")
        }
        let mailbox = args?["mailbox"]?.stringValue ?? "INBOX"
        let (data, fetchError) = fetchSource(
            account: args?["account"]?.stringValue,
            mailbox: mailbox,
            messageId: messageId
        )
        if let fetchError { return errorResult(fetchError) }

        if let saveTo = args?["save_to"]?.stringValue {
            let url = URL(fileURLWithPath: (saveTo as NSString).expandingTildeInPath)
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url)
            } catch {
                return errorResult("could not write \(url.path): \(error.localizedDescription)")
            }
            return jsonResult(["path": url.path, "bytes": data.count, "message_id": messageId])
        }

        // Sources run to megabytes, so an unbounded return would bury the
        // caller. The cap is on bytes taken from the front, which is where the
        // headers and the structure are.
        let slice = sourceSlice(data, maxBytes: clampMaxBytes(args?["max_bytes"]?.intValue))
        return jsonResult([
            "source": slice.text,
            "bytes_total": data.count,
            "bytes_returned": slice.bytesReturned,
            "source_encoding": slice.encoding,
            "truncated": data.count > slice.bytesReturned,
            "message_id": messageId
        ])
    }

    /// Clamps `max_bytes` to the range the schema advertises.
    ///
    /// The old lower bound was 1000, so `max_bytes: 10` silently returned a
    /// kilobyte. Nothing documented a floor, and a caller asking for ten bytes
    /// has a reason. Only the ceiling and "at least one byte" are enforced.
    static func clampMaxBytes(_ requested: Int?) -> Int {
        min(max(requested ?? 100_000, 1), 2_000_000)
    }

    /// What `mail_get_source` hands back inline, and an honest description of it.
    struct SourceSlice {
        let text: String
        /// How many bytes of the message `text` represents, in the encoding
        /// named below. Derived from what is returned, never from what was asked
        /// for.
        let bytesReturned: Int
        let encoding: String
    }

    /// Drops a partial UTF-8 sequence from the end of a truncated slice.
    ///
    /// At most three bytes come off: enough to complete the longest sequence,
    /// and bounded so that data which is not UTF-8 at all is left alone rather
    /// than eaten a byte at a time.
    static func trimPartialUTF8(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return data }
        var lead = bytes.count - 1
        var continuations = 0
        while lead >= 0 && bytes[lead] & 0xC0 == 0x80 && continuations < 3 {
            lead -= 1
            continuations += 1
        }
        guard lead >= 0 else { return data }

        let expected: Int
        switch bytes[lead] {
        case 0x00...0x7F: expected = 1
        case 0xC0...0xDF: expected = 2
        case 0xE0...0xEF: expected = 3
        case 0xF0...0xF7: expected = 4
        // Not a lead byte: this is not UTF-8, so there is no boundary to find.
        default: return data
        }
        return bytes.count - lead < expected ? Data(bytes[0..<lead]) : data
    }

    /// Takes the first `maxBytes` of a source and decodes them for return.
    ///
    /// A cut landing inside a multi-byte sequence used to make the `.utf8`
    /// initialiser fail for the *whole* slice, and the `.isoLatin1` fallback
    /// then reinterpreted every non-ASCII byte in it -- so one split character
    /// corrupted the entire response, and `bytes_returned` (which described the
    /// slice, not the string) stopped matching what was actually returned.
    ///
    /// The slice is trimmed back to a character boundary first, so the fallback
    /// now fires only for a source that genuinely is not UTF-8 -- and when it
    /// does, the caller is told, because `bytes_returned` can only be read
    /// correctly alongside the encoding it was measured in.
    static func sourceSlice(_ data: Data, maxBytes: Int) -> SourceSlice {
        var slice = Data(data.prefix(maxBytes))
        if slice.count < data.count { slice = trimPartialUTF8(slice) }
        if let text = String(data: slice, encoding: .utf8) {
            return SourceSlice(text: text, bytesReturned: slice.count, encoding: "utf-8")
        }
        return SourceSlice(
            text: String(data: slice, encoding: .isoLatin1) ?? "",
            bytesReturned: slice.count,
            encoding: "iso-8859-1"
        )
    }

    /// How long the post-move read-back is allowed to wait for the message to
    /// appear in its destination, and how often it looks.
    private static let moveVerifyAttempts = 12
    private static let moveVerifyInterval = 0.25

    /// The move script, minus the `var mail = Application('Mail');` line.
    ///
    /// Not private, and split from the handler, so the tests can run it with
    /// `mail` bound to a stub: the thing worth testing here is which mailbox
    /// object the generated JavaScript picks, and that is not visible from
    /// Swift.
    static func moveScriptJXA(
        messageId: String,
        sourceMailbox: String,
        targetMailbox: String,
        account: String?,
        targetAccount: String?
    ) -> String {
        let escapedId = escapeJSString(messageId)
        let targetAccountExpr = targetAccount.map { "'\(escapeJSString($0))'" } ?? "null"
        // Default the destination account to the one the message was found in.
        // An explicit `target_account` is the only way to move across an account
        // boundary, so doing it is a decision the caller made rather than an
        // artefact of which account Mail lists first.
        let destination = mailboxInAccountJXA(
            mailbox: targetMailbox,
            accountExpr: "(TARGET_ACCOUNT !== null ? TARGET_ACCOUNT : foundAccount)",
            varName: "destMbox"
        )
        return """
    var TARGET_ACCOUNT = \(targetAccountExpr);
    \(findMessageJXA(account: account, mailbox: sourceMailbox, messageId: messageId))
    var moveResult;
    if (!found) {
        moveResult = {error: 'message not found with id: \(escapedId)'};
    } else {
        var sourceAccount = foundAccount;
        var sourceMailboxName = foundMailbox;
        // Read the identifiers before the move: assigning `mailbox` invalidates
        // the reference, and every property read on it afterwards raises
        // "Invalid index". The RFC Message-ID is what the read-back matches on,
        // because an IMAP move re-files the message server-side and Mail's
        // numeric id for it does not survive.
        var rfcId = null;
        try { rfcId = found.messageId(); } catch (e) {}
        rfcId = (rfcId == null) ? null : ('' + rfcId).replace(/^</, '').replace(/>$/, '');
        var numericId = null;
        try { numericId = '' + found.id(); } catch (e) {}
    \(destination)
        var destName = '' + destMbox.name();
        found.mailbox = destMbox;
        // Read back where the message actually landed. `moved` on its own said
        // nothing about the destination, which is exactly why a cross-account
        // move went unnoticed.
        var verified = false;
        for (var attempt = 0; attempt < \(moveVerifyAttempts) && !verified; attempt++) {
            try {
                if (rfcId !== null) {
                    var rids = destMbox.messages.messageId();
                    for (var i = 0; i < rids.length; i++) {
                        if (rids[i] == null) continue;
                        if (('' + rids[i]).replace(/^</, '').replace(/>$/, '') === rfcId) { verified = true; break; }
                    }
                } else if (numericId !== null) {
                    var nids = destMbox.messages.id();
                    for (var j = 0; j < nids.length; j++) {
                        if (('' + nids[j]) === numericId) { verified = true; break; }
                    }
                }
            } catch (e) {}
            if (!verified) delay(\(moveVerifyInterval));
        }
        moveResult = {
            status: 'moved',
            account: destMboxAccount,
            mailbox: destName,
            moved_from: {account: sourceAccount, mailbox: sourceMailboxName},
            cross_account: destMboxAccount !== sourceAccount,
            verified: verified
        };
    }
    JSON.stringify(moveResult);
    """
    }

    private static func moveEmail(_ args: JSONObject?) -> MCPCallResult {
        guard let messageId = args?["message_id"]?.stringValue else {
            return errorResult("message_id is required")
        }
        guard let targetMailbox = args?["target_mailbox"]?.stringValue else {
            return errorResult("target_mailbox is required")
        }
        let sourceMailbox = args?["source_mailbox"]?.stringValue ?? "INBOX"

        let script = """
        var mail = Application('Mail');
        \(moveScriptJXA(
            messageId: messageId,
            sourceMailbox: sourceMailbox,
            targetMailbox: targetMailbox,
            account: args?["account"]?.stringValue,
            targetAccount: args?["target_account"]?.stringValue
        ))
        """
        let (output, error) = runJXA(script)
        if let error { return errorResult(error) }
        if output.contains("\"error\"") { return errorResult(output) }
        guard let data = output.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return textResult(output.isEmpty ? "email moved" : output)
        }
        return jsonResult(payload)
    }

    private static func markRead(_ args: JSONObject?) -> MCPCallResult {
        guard let messageId = args?["message_id"]?.stringValue else {
            return errorResult("message_id is required")
        }
        guard let read = args?["read"]?.boolValue else {
            return errorResult("read is required")
        }

        let mailbox = args?["mailbox"]?.stringValue ?? "INBOX"
        let escapedId = escapeJSString(messageId)
        let findMessage = findMessageJXA(account: args?["account"]?.stringValue, mailbox: mailbox, messageId: messageId)

        let script = """
        var mail = Application('Mail');
        \(findMessage)
        if (!found) {
            JSON.stringify({error: 'message not found with id: \(escapedId)'});
        } else {
            found.readStatus = \(read);
            'done';
        }
        """
        let (output, error) = runJXA(script)
        if let error { return errorResult(error) }
        if output.contains("\"error\"") { return errorResult(output) }
        return textResult("marked \(read ? "read" : "unread")")
    }

    // MARK: - Registration

    /// `mail_send` and `mail_create_draft` take the same message, so they take
    /// the same schema.
    private static func composeSchema(action: String) -> JSONValue {
        schema(
            properties: [
                "to": stringOrStringArrayProp("Recipient address(es). One string, an array of strings, or a comma-separated list. Display names are allowed: \"Susan Cross\" <s@example.org>"),
                "subject": stringProp("Email subject"),
                "body": stringProp("Plain-text email body. Required unless html_body is given"),
                "html_body": stringProp("HTML email body. Sent as a real text/html message, so tables, headings and links render. Takes precedence over body when both are given (Mail generates its own plain-text alternative)"),
                "cc": stringOrStringArrayProp("CC recipient address(es), same forms as `to`"),
                "bcc": stringOrStringArrayProp("BCC recipient address(es), same forms as `to`"),
                "attachments": stringArrayProp("Absolute POSIX paths of files to attach, e.g. [\"/Users/me/Budget.pdf\"]. Attached after the body so they appear at the end of the message"),
                "from": stringProp("Sender email address (overrides account lookup)"),
                "account": stringProp("Account name to \(action) (uses default account if omitted)")
            ],
            required: ["to", "subject"]
        )
    }

    static func register(_ registry: ToolRegistry) {
        let cat = "Mail"

        registry.register(
            MCPTool(
                name: "mail_list_accounts",
                description: "List all mail accounts configured in Mail.app",
                inputSchema: emptySchema(),
                annotations: MCPAnnotations(readOnlyHint: true)
            ),
            category: cat,
            handler: listAccounts
        )

        registry.register(
            MCPTool(
                name: "mail_list_mailboxes",
                description: "List mailboxes. Groups by account when no account specified",
                inputSchema: schema(
                    properties: [
                        "account": stringProp("Account name (lists all mailboxes if omitted)")
                    ]
                ),
                annotations: MCPAnnotations(readOnlyHint: true)
            ),
            category: cat,
            handler: listMailboxes
        )

        registry.register(
            MCPTool(
                name: "mail_get_emails",
                description: "Get the most recent emails (newest first) from matching mailboxes across accounts. Returns messages plus scan-coverage metadata (total_messages, truncated, messages_scanned, scanned/skipped mailboxes)",
                inputSchema: schema(
                    properties: [
                        "account": stringProp("Account name"),
                        "mailbox": stringProp("Mailbox name, matched case-insensitively in every account and local On-My-Mac boxes (default: INBOX). Pass 'all' to scan every mailbox except junk/trash/drafts"),
                        "limit": intProp("Maximum number of emails to return (default: 10)")
                    ]
                ),
                annotations: MCPAnnotations(readOnlyHint: true)
            ),
            category: cat,
            handler: getEmails
        )

        registry.register(
            MCPTool(
                name: "mail_get_email",
                description: "Get full email by message ID, including the list of attachments (name, size, mime_type). Searches all accounts when account omitted. Use mail_save_attachment to retrieve attachment contents",
                inputSchema: schema(
                    properties: [
                        "message_id": stringProp("Numeric message ID from mail_get_emails or mail_search, or an RFC Message-ID such as <abc@example.org> (use the RFC form for drafts, whose numeric id goes stale once the server syncs them)"),
                        "account": stringProp("Account name from results (optional, speeds up lookup)"),
                        "mailbox": stringProp("Mailbox to check first (default: INBOX); automatically falls back to searching all mailboxes")
                    ],
                    required: ["message_id"]
                ),
                annotations: MCPAnnotations(readOnlyHint: true)
            ),
            category: cat,
            handler: getEmail
        )

        registry.register(
            MCPTool(
                name: "mail_search",
                description: "Search emails by subject and sender, optionally recipients and body (case-insensitive). Scans every mailbox in every account by default, newest first. Returns matches plus scan-coverage metadata (total_matches, truncated, messages_scanned, scanned/skipped mailboxes)",
                inputSchema: schema(
                    properties: [
                        "query": stringProp("Search query"),
                        "account": stringProp("Account name"),
                        "mailbox": stringProp("Mailbox name to search (default: 'all' — every mailbox except junk/trash/drafts)"),
                        "limit": intProp("Maximum number of results, newest first (default: 10)"),
                        "search_recipients": boolProp("Also match To/CC recipient names and addresses (adds roughly 1s per 1000 messages scanned)"),
                        "search_body": boolProp("Also match body text. Mail can only supply bodies one at a time (~1.2s each), so this is a capped second pass over the newest messages in scope — it does NOT search every body. Coverage is reported in the body_search field of the result"),
                        "body_scan_limit": intProp("How many bodies the search_body pass may read (default: 25, max: 200). Expect ~1.2s per body")
                    ],
                    required: ["query"]
                ),
                annotations: MCPAnnotations(readOnlyHint: true)
            ),
            category: cat,
            handler: searchEmails
        )

        registry.register(
            MCPTool(
                name: "mail_send",
                description: "Send an email via Mail.app, optionally as HTML and with file attachments",
                inputSchema: composeSchema(action: "send from"),
                annotations: MCPAnnotations(readOnlyHint: false)
            ),
            category: cat,
            handler: sendEmail
        )

        registry.register(
            MCPTool(
                name: "mail_create_draft",
                description: "Create an email draft in Mail.app's Drafts folder, optionally as HTML and with file attachments. Does NOT send the email. Returns the saved draft's numeric and RFC message IDs so it can be read back with mail_get_email",
                inputSchema: composeSchema(action: "save the draft in"),
                annotations: MCPAnnotations(readOnlyHint: false)
            ),
            category: cat,
            handler: createDraft
        )

        registry.register(
            MCPTool(
                name: "mail_save_attachment",
                description: "Save attachments from a received message to disk. Writes the files directly (Mail's own save is blocked by its sandbox). Saves every attachment when neither attachment_name nor index is given",
                inputSchema: schema(
                    properties: [
                        "message_id": stringProp("Numeric message ID from mail_get_emails or mail_search, or an RFC Message-ID"),
                        "destination": stringProp("Absolute POSIX path: a directory to save into (created if missing), or a full file path when saving a single attachment"),
                        "attachment_name": stringProp("Name of the attachment to save, as reported by mail_get_email (exact match preferred, substring accepted)"),
                        "index": intProp("Zero-based index of the attachment to save, as an alternative to attachment_name"),
                        "account": stringProp("Account name (optional, speeds up lookup)"),
                        "mailbox": stringProp("Mailbox to check first (default: INBOX); automatically falls back to searching all mailboxes"),
                        "overwrite": boolProp("Overwrite an existing file instead of saving alongside it as \"name (2).ext\" (default: false)")
                    ],
                    required: ["message_id", "destination"]
                )
            ),
            category: cat,
            handler: saveAttachment
        )

        registry.register(
            MCPTool(
                name: "mail_get_source",
                description: "Get a message's raw RFC 822 source. Returns the first max_bytes by default, or writes the whole thing to save_to. An inline result reports source_encoding (utf-8, or iso-8859-1 for a source that is not valid UTF-8) and bytes_returned, which counts the bytes actually returned in that encoding — a truncation is moved back to a character boundary rather than cutting one in half. Use mail_save_attachment instead when the goal is just to extract attachments",
                inputSchema: schema(
                    properties: [
                        "message_id": stringProp("Numeric message ID from mail_get_emails or mail_search, or an RFC Message-ID"),
                        "account": stringProp("Account name (optional, speeds up lookup)"),
                        "mailbox": stringProp("Mailbox to check first (default: INBOX); automatically falls back to searching all mailboxes"),
                        "save_to": stringProp("Absolute POSIX path to write the full source to. Prefer this for large messages"),
                        "max_bytes": intProp("How much source to return inline when save_to is omitted (default: 100000, max: 2000000). The cut is moved back to the nearest character boundary, so bytes_returned can be up to 3 less than this")
                    ],
                    required: ["message_id"]
                ),
                annotations: MCPAnnotations(readOnlyHint: true)
            ),
            category: cat,
            handler: getSource
        )

        registry.register(
            MCPTool(
                name: "mail_move",
                description: "Move an email to a different mailbox of the same account. Searches all accounts when account omitted, and the destination is resolved inside whichever account the message was found in — pass target_account to move it to a different account instead. Returns where the message landed and whether that was confirmed by reading it back",
                inputSchema: schema(
                    properties: [
                        "message_id": stringProp("Message ID from mail_get_emails or mail_search results"),
                        "source_mailbox": stringProp("Source mailbox to check first (default: INBOX); automatically falls back to searching all mailboxes"),
                        "target_mailbox": stringProp("Destination mailbox name, resolved within the message's own account"),
                        "account": stringProp("Account name to search for the message (optional, speeds up lookup)"),
                        "target_account": stringProp("Account to move the message INTO. Omit to keep it in its own account — which is almost always what you want, since every account has an Archive, Sent, Trash and Drafts. Setting this to another account uploads the message to that account and removes it from this one")
                    ],
                    required: ["message_id", "target_mailbox"]
                )
            ),
            category: cat,
            handler: moveEmail
        )

        registry.register(
            MCPTool(
                name: "mail_mark_read",
                description: "Mark an email as read or unread. Searches all accounts when account omitted",
                inputSchema: schema(
                    properties: [
                        "message_id": stringProp("Message ID from mail_get_emails or mail_search results"),
                        "read": boolProp("true to mark as read, false to mark as unread"),
                        "account": stringProp("Account name"),
                        "mailbox": stringProp("Mailbox to check first (default: INBOX); automatically falls back to searching all mailboxes")
                    ],
                    required: ["message_id", "read"]
                )
            ),
            category: cat,
            handler: markRead
        )
    }
}
