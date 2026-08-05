import Foundation

enum MailService {
    /// Wall-clock ceiling for a single osascript invocation. Mail can wedge for
    /// minutes on an expensive Apple Event, and an unbounded wait would hang the
    /// whole server, so every run gets a deadline and a SIGKILL backstop.
    private static let defaultTimeout: TimeInterval = 120

    /// Runs a JXA script under a hard deadline.
    ///
    /// Output goes to temp files rather than pipes: a scan of a large mailbox
    /// easily exceeds the 64 KB pipe buffer, and reading a pipe only after
    /// `waitUntilExit()` deadlocks once the child fills it.
    private static func runJXA(
        _ script: String,
        retries: Int = 2,
        timeout: TimeInterval = defaultTimeout
    ) -> (output: String, error: String?) {
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
                return ("", "failed to open temp files for osascript output")
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
                return ("", "failed to run osascript: \(error.localizedDescription)")
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

            let output = (try? String(contentsOf: outURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errOutput = (try? String(contentsOf: errURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if timedOut {
                return ("", "Mail did not respond within \(Int(timeout))s — the request was cancelled. Narrow the scope (a specific account or mailbox, or a smaller limit) and try again.")
            }

            if process.terminationStatus != 0 {
                // -1712 is an Apple Event timeout inside Mail itself. Retrying
                // just spends the same wait again, so surface it instead.
                if errOutput.contains("-1712") {
                    return ("", "Mail timed out evaluating the request (-1712). Narrow the scope and try again.")
                }
                if attempt < retries && errOutput.contains("-1728") {
                    Thread.sleep(forTimeInterval: 0.5)
                    continue
                }
                return (output, errOutput.isEmpty ? "osascript exited with status \(process.terminationStatus)" : errOutput)
            }
            return (output, nil)
        }
        return ("", "max retries exceeded")
    }

    private static func escapeJSString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
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
    private static func accountNames() -> (names: [String], error: String?) {
        let script = """
        var mail = Application('Mail');
        var a = mail.accounts();
        var out = [];
        for (var i = 0; i < a.length; i++) out.push('' + a[i].name());
        JSON.stringify(out);
        """
        let (output, error) = runJXA(script, timeout: 30)
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
        let (names, error) = accountNames()
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
            let (output, error) = runJXA(script, timeout: timeout)
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
    private static func findMessageJXA(account: String?, mailbox: String, messageId: String) -> String {
        let escapedMailbox = escapeJSString(mailbox)
        let escapedId = escapeJSString(messageId)
        return """
    \(collectBoxesJXA(account: account, varName: "fmBoxes"))
    var found = null; var foundAccount = null; var foundMailbox = null;
    (function() {
        var targetLC = '\(escapedMailbox)'.toLowerCase();
        function searchIn(subset) {
            for (var i = 0; i < subset.length; i++) {
                var ids;
                try { ids = subset[i].mbox.messages.id(); } catch (e) { continue; }
                for (var k = 0; k < ids.length; k++) {
                    if ('' + ids[k] === '\(escapedId)') {
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

    /// JXA snippet resolving a mailbox by name, case-insensitively across all
    /// accounts (plus local On-My-Mac boxes) when no account given. Throws when
    /// not found.
    private static func mailboxJXA(account: String?, mailbox: String, varName: String = "mbox") -> String {
        let escapedMailbox = escapeJSString(mailbox)
        return """
    \(collectBoxesJXA(account: account, varName: "\(varName)Candidates"))
    var \(varName) = (function() {
        for (var i = 0; i < \(varName)Candidates.length; i++) {
            if (\(varName)Candidates[i].name.toLowerCase() === '\(escapedMailbox)'.toLowerCase()) return \(varName)Candidates[i].mbox;
        }
        throw new Error('mailbox not found: \(escapedMailbox)');
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
        let (names, error) = accountNames()
        if let error { return errorResult(error) }
        return jsonResult(names)
    }

    private static func listMailboxes(_ args: JSONObject?) -> MCPCallResult {
        let script: String
        if let account = args?["account"]?.stringValue {
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
        let (output, error) = runJXA(script)
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

        let script = """
        var mail = Application('Mail');
        \(findMessage)
        if (!found) {
            JSON.stringify({error: 'message not found with id: \(escapedId)'});
        } else {
            JSON.stringify({
                id: '' + found.id(),
                account: foundAccount,
                mailbox: foundMailbox,
                subject: found.subject(),
                sender: found.sender(),
                date_received: '' + found.dateReceived(),
                read: found.readStatus(),
                to: found.toRecipients().map(function(r) { return r.address(); }),
                cc: found.ccRecipients().map(function(r) { return r.address(); }),
                body: found.content()
            });
        }
        """
        let (output, error) = runJXA(script)
        if let error { return errorResult(error) }
        return textResult(output)
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

            let (output, error) = runJXA(script, retries: 0, timeout: budget)
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

    /// Shared email composition: validates params, builds JXA, runs it.
    /// `visible` controls whether a compose window opens. `finalAction` is the JXA after recipients are set.
    private static func composeEmail(_ args: JSONObject?, visible: Bool, finalAction: String, successMessage: String) -> MCPCallResult {
        guard let to = args?["to"]?.stringValue else {
            return errorResult("to is required")
        }
        guard let subject = args?["subject"]?.stringValue else {
            return errorResult("subject is required")
        }
        guard let body = args?["body"]?.stringValue else {
            return errorResult("body is required")
        }

        let escapedTo = escapeJSString(to)
        let escapedSubject = escapeJSString(subject)
        let escapedBody = escapeJSString(body)

        var recipientLines = """
        var toRecip = mail.Recipient({address: '\(escapedTo)'});
        msg.toRecipients.push(toRecip);
        """

        if let cc = args?["cc"]?.stringValue {
            let escapedCc = escapeJSString(cc)
            recipientLines += """

            var ccRecip = mail.CcRecipient({address: '\(escapedCc)'});
            msg.ccRecipients.push(ccRecip);
            """
        }

        if let bcc = args?["bcc"]?.stringValue {
            let escapedBcc = escapeJSString(bcc)
            recipientLines += """

            var bccRecip = mail.BccRecipient({address: '\(escapedBcc)'});
            msg.bccRecipients.push(bccRecip);
            """
        }

        let senderSnippet = senderJXA(from: args?["from"]?.stringValue, account: args?["account"]?.stringValue)
        let visibleProp = visible ? "" : ",\n    visible: false"

        let script = """
        var mail = Application('Mail');
        \(senderSnippet.lines)
        var msg = mail.OutgoingMessage({
            subject: '\(escapedSubject)',
            content: '\(escapedBody)'\(visibleProp)
        });
        mail.outgoingMessages.push(msg);
        \(recipientLines)
        \(senderSnippet.prop)
        \(finalAction)
        """
        let (output, error) = runJXA(script)
        if let error { return errorResult(error) }
        return textResult(output.isEmpty ? successMessage : output)
    }

    private static func sendEmail(_ args: JSONObject?) -> MCPCallResult {
        composeEmail(args, visible: true, finalAction: "msg.send();\n'sent';", successMessage: "email sent")
    }

    private static func createDraft(_ args: JSONObject?) -> MCPCallResult {
        composeEmail(args, visible: false, finalAction: "mail.save(msg);\n'draft created';", successMessage: "draft created")
    }

    private static func moveEmail(_ args: JSONObject?) -> MCPCallResult {
        guard let messageId = args?["message_id"]?.stringValue else {
            return errorResult("message_id is required")
        }
        guard let targetMailbox = args?["target_mailbox"]?.stringValue else {
            return errorResult("target_mailbox is required")
        }
        let sourceMailbox = args?["source_mailbox"]?.stringValue ?? "INBOX"

        let escapedId = escapeJSString(messageId)
        let account = args?["account"]?.stringValue
        let findMessage = findMessageJXA(account: account, mailbox: sourceMailbox, messageId: messageId)
        let targetAccess = mailboxJXA(account: account, mailbox: targetMailbox, varName: "destMbox")

        let script = """
        var mail = Application('Mail');
        \(findMessage)
        \(targetAccess)
        if (!found) {
            JSON.stringify({error: 'message not found with id: \(escapedId)'});
        } else {
            found.mailbox = destMbox;
            'moved';
        }
        """
        let (output, error) = runJXA(script)
        if let error { return errorResult(error) }
        if output.contains("\"error\"") { return errorResult(output) }
        return textResult(output.isEmpty ? "email moved" : output)
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
                description: "Get full email by message ID. Searches all accounts when account omitted",
                inputSchema: schema(
                    properties: [
                        "message_id": stringProp("Message ID from mail_get_emails or mail_search results"),
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
                description: "Send an email via Mail.app",
                inputSchema: schema(
                    properties: [
                        "to": stringProp("Recipient email address"),
                        "subject": stringProp("Email subject"),
                        "body": stringProp("Email body text"),
                        "cc": stringProp("CC recipient email address"),
                        "bcc": stringProp("BCC recipient email address"),
                        "from": stringProp("Sender email address (overrides account lookup)"),
                        "account": stringProp("Account name to send from (uses default account if omitted)")
                    ],
                    required: ["to", "subject", "body"]
                )
            ),
            category: cat,
            handler: sendEmail
        )

        registry.register(
            MCPTool(
                name: "mail_create_draft",
                description: "Create an email draft in Mail.app's Drafts folder. Does NOT send the email",
                inputSchema: schema(
                    properties: [
                        "to": stringProp("Recipient email address"),
                        "subject": stringProp("Email subject"),
                        "body": stringProp("Email body text"),
                        "cc": stringProp("CC recipient email address"),
                        "bcc": stringProp("BCC recipient email address"),
                        "from": stringProp("Sender email address (overrides account lookup)"),
                        "account": stringProp("Account name to save draft in (uses default account if omitted)")
                    ],
                    required: ["to", "subject", "body"]
                )
            ),
            category: cat,
            handler: createDraft
        )

        registry.register(
            MCPTool(
                name: "mail_move",
                description: "Move an email to a different mailbox. Searches all accounts when account omitted",
                inputSchema: schema(
                    properties: [
                        "message_id": stringProp("Message ID from mail_get_emails or mail_search results"),
                        "source_mailbox": stringProp("Source mailbox to check first (default: INBOX); automatically falls back to searching all mailboxes"),
                        "target_mailbox": stringProp("Destination mailbox name"),
                        "account": stringProp("Account name")
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
