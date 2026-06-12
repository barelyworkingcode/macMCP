import Foundation

enum MailService {
    private static func runJXA(_ script: String, retries: Int = 2) -> (output: String, error: String?) {
        for attempt in 0...retries {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", "-e", script]

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return ("", "failed to run osascript: \(error.localizedDescription)")
            }

            let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if process.terminationStatus != 0 {
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

    /// JXA that builds `var <varName> = [{mbox, acctName, name}]` covering every
    /// mailbox of the named account (throws if missing), or of all accounts plus
    /// Mail's app-level local "On My Mac" mailboxes when account is nil.
    /// Note: Mail returns account.mailboxes() already flattened (nested folders
    /// included), so no recursion is needed.
    private static func collectBoxesJXA(account: String?, varName: String) -> String {
        if let account = account {
            let escapedAccount = escapeJSString(account)
            return """
        var \(varName) = (function() {
            var sink = [];
            var accts = mail.accounts();
            for (var ai = 0; ai < accts.length; ai++) {
                if (accts[ai].name().toLowerCase() === '\(escapedAccount)'.toLowerCase()) {
                    var acctName = accts[ai].name();
                    var mboxes = accts[ai].mailboxes();
                    for (var mj = 0; mj < mboxes.length; mj++) {
                        sink.push({mbox: mboxes[mj], acctName: acctName, name: '' + mboxes[mj].name()});
                    }
                    return sink;
                }
            }
            throw new Error('account not found: \(escapedAccount)');
        })();
        """
        } else {
            return """
        var \(varName) = (function() {
            var sink = [];
            var accts = mail.accounts();
            for (var ai = 0; ai < accts.length; ai++) {
                var acctName = accts[ai].name();
                var mboxes = accts[ai].mailboxes();
                for (var mj = 0; mj < mboxes.length; mj++) {
                    sink.push({mbox: mboxes[mj], acctName: acctName, name: '' + mboxes[mj].name()});
                }
            }
            var localBoxes = mail.mailboxes();
            for (var lj = 0; lj < localBoxes.length; lj++) {
                sink.push({mbox: localBoxes[lj], acctName: 'On My Mac', name: '' + localBoxes[lj].name()});
            }
            return sink;
        })();
        """
        }
    }

    /// JXA that filters allBoxes down to `var allEntries`. mailbox "all" keeps
    /// everything except junk/trash/drafts/outbox; otherwise matches the mailbox
    /// name case-insensitively. Throws when nothing matches so callers get an
    /// error instead of a silently empty scan.
    private static func collectEntriesJXA(account: String?, mailbox: String) -> String {
        let boxes = collectBoxesJXA(account: account, varName: "allBoxes")
        let filter: String
        if mailbox.lowercased() == "all" {
            filter = """
        var SKIP = {'trash':1,'junk':1,'spam':1,'junk email':1,'deleted items':1,'deleted messages':1,'drafts':1,'outbox':1};
        var allEntries = allBoxes.filter(function(b) { return !SKIP[b.name.toLowerCase()]; });
        """
        } else {
            let escapedMailbox = escapeJSString(mailbox)
            filter = """
        var allEntries = allBoxes.filter(function(b) { return b.name.toLowerCase() === '\(escapedMailbox)'.toLowerCase(); });
        if (allEntries.length === 0) throw new Error('no mailbox named "\(escapedMailbox)" found — use mail_list_mailboxes to see available names, or pass mailbox "all"');
        """
        }
        return boxes + "\n" + filter
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
        let script = """
        var mail = Application('Mail');
        var accounts = mail.accounts();
        var names = [];
        for (var i = 0; i < accounts.length; i++) {
            names.push(accounts[i].name());
        }
        JSON.stringify(names);
        """
        let (output, error) = runJXA(script)
        if let error { return errorResult(error) }
        return textResult(output)
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
        let limit = args?["limit"]?.intValue ?? 10
        let account = args?["account"]?.stringValue

        let script = """
        var mail = Application('Mail');
        \(collectEntriesJXA(account: account, mailbox: mailbox))
        var candidates = [];
        var scanned = [];
        var skipped = [];
        var seen = {};
        for (var mi = 0; mi < allEntries.length; mi++) {
            var entry = allEntries[mi];
            var boxLabel = entry.acctName + ':' + entry.name;
            try {
                var ids = entry.mbox.messages.id();
                var dates = entry.mbox.messages.dateReceived();
                for (var i = 0; i < ids.length; i++) {
                    var id = '' + ids[i];
                    if (seen[id]) continue;
                    seen[id] = true;
                    candidates.push({mi: mi, idx: i, id: id, t: dates[i] ? dates[i].getTime() : 0, d: dates[i] ? '' + dates[i] : ''});
                }
                scanned.push(boxLabel);
            } catch (e) {
                skipped.push(boxLabel);
            }
        }
        candidates.sort(function(a, b) { return b.t - a.t; });
        var top = candidates.slice(0, \(limit));
        var results = [];
        for (var i = 0; i < top.length; i++) {
            var c = top[i];
            var entry = allEntries[c.mi];
            var m = entry.mbox.messages[c.idx];
            results.push({
                id: c.id,
                account: entry.acctName,
                mailbox: entry.name,
                subject: m.subject(),
                sender: m.sender(),
                date_received: c.d,
                read: m.readStatus()
            });
        }
        JSON.stringify({messages: results, total_messages: candidates.length, truncated: candidates.length > \(limit), scanned_mailboxes: scanned, skipped_mailboxes: skipped});
        """
        let (output, error) = runJXA(script)
        if let error { return errorResult(error) }
        return textResult(output)
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

    private static func searchEmails(_ args: JSONObject?) -> MCPCallResult {
        guard let query = args?["query"]?.stringValue else {
            return errorResult("query is required")
        }
        let limit = args?["limit"]?.intValue ?? 10
        let escapedQuery = escapeJSString(query)
        let mailbox = args?["mailbox"]?.stringValue ?? "all"
        let account = args?["account"]?.stringValue
        let searchRecipients = args?["search_recipients"]?.boolValue ?? false
        let searchBody = args?["search_body"]?.boolValue ?? false

        // Mail evaluates `whose` internally; _contains is case-insensitive.
        var terms = [
            "{subject: {_contains: '\(escapedQuery)'}}",
            "{sender: {_contains: '\(escapedQuery)'}}"
        ]
        if searchBody {
            terms.append("{content: {_contains: '\(escapedQuery)'}}")
        }
        let whoseClause = "{_or: [\(terms.joined(separator: ", "))]}"

        // Recipients are element collections, which `whose` cannot reach — when
        // requested, bulk-fetch the recipient columns and match in JS.
        let recipientsPass = !searchRecipients ? "" : """
    var allIds = entry.mbox.messages.id();
    var tos = entry.mbox.messages.toRecipients.address();
    var ccs = entry.mbox.messages.ccRecipients.address();
    var toNames = entry.mbox.messages.toRecipients.name();
    var ccNames = entry.mbox.messages.ccRecipients.name();
    for (var ri = 0; ri < allIds.length; ri++) {
        var rid = '' + allIds[ri];
        if (seen[rid]) continue;
        var hay = ((tos[ri] || []).join(' ') + ' ' + (ccs[ri] || []).join(' ') + ' ' + (toNames[ri] || []).join(' ') + ' ' + (ccNames[ri] || []).join(' ')).toLowerCase();
        if (hay.indexOf(queryLC) !== -1) {
            seen[rid] = true;
            var rm = entry.mbox.messages[ri];
            var rd = rm.dateReceived();
            candidates.push({id: rid, account: entry.acctName, mailbox: entry.name, subject: rm.subject(), sender: rm.sender(), t: rd ? rd.getTime() : 0, date_received: rd ? '' + rd : '', read: rm.readStatus()});
        }
    }
    """

        let script = """
        var mail = Application('Mail');
        \(collectEntriesJXA(account: account, mailbox: mailbox))
        var queryLC = '\(escapedQuery)'.toLowerCase();
        var candidates = [];
        var scanned = [];
        var skipped = [];
        var seen = {};
        for (var mi = 0; mi < allEntries.length; mi++) {
            var entry = allEntries[mi];
            var boxLabel = entry.acctName + ':' + entry.name;
            try {
                var matched = entry.mbox.messages.whose(\(whoseClause));
                var ids = matched.id();
                if (ids.length > 0) {
                    var subjects = matched.subject();
                    var senders = matched.sender();
                    var dates = matched.dateReceived();
                    var reads = matched.readStatus();
                    for (var i = 0; i < ids.length; i++) {
                        var id = '' + ids[i];
                        if (seen[id]) continue;
                        seen[id] = true;
                        candidates.push({id: id, account: entry.acctName, mailbox: entry.name, subject: subjects[i], sender: senders[i], t: dates[i] ? dates[i].getTime() : 0, date_received: dates[i] ? '' + dates[i] : '', read: reads[i]});
                    }
                }
                \(recipientsPass)
                scanned.push(boxLabel);
            } catch (e) {
                skipped.push(boxLabel);
            }
        }
        candidates.sort(function(a, b) { return b.t - a.t; });
        var top = candidates.slice(0, \(limit));
        var results = [];
        for (var i = 0; i < top.length; i++) {
            var c = top[i];
            results.push({id: c.id, account: c.account, mailbox: c.mailbox, subject: c.subject, sender: c.sender, date_received: c.date_received, read: c.read});
        }
        JSON.stringify({messages: results, total_matches: candidates.length, truncated: candidates.length > \(limit), scanned_mailboxes: scanned, skipped_mailboxes: skipped});
        """
        let (output, error) = runJXA(script)
        if let error { return errorResult(error) }
        return textResult(output)
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
                description: "Get the most recent emails (newest first) from matching mailboxes across accounts. Returns messages plus scan-coverage metadata (total_messages, truncated, scanned/skipped mailboxes)",
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
                description: "Search emails by subject and sender, optionally recipients and body (case-insensitive). Scans every mailbox in every account by default, newest first. Returns matches plus scan-coverage metadata (total_matches, truncated, scanned/skipped mailboxes)",
                inputSchema: schema(
                    properties: [
                        "query": stringProp("Search query"),
                        "account": stringProp("Account name"),
                        "mailbox": stringProp("Mailbox name to search (default: 'all' — every mailbox except junk/trash/drafts)"),
                        "limit": intProp("Maximum number of results, newest first (default: 10)"),
                        "search_recipients": boolProp("Also match To/CC recipient names and addresses (slower: full scan of each mailbox)"),
                        "search_body": boolProp("Also match message body text (uses Mail's native filter)")
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
