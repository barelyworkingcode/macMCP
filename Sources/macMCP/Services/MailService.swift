import Foundation

enum MailService {
    private static func runJXA(_ script: String) -> (output: String, error: String?) {
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
            return (output, errOutput.isEmpty ? "osascript exited with status \(process.terminationStatus)" : errOutput)
        }
        return (output, nil)
    }

    private static func escapeJSString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
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
        let accountFilter: String
        if let account = args?["account"]?.stringValue {
            let escaped = escapeJSString(account)
            accountFilter = """
            var acct = mail.accounts.byName('\(escaped)');
            var mailboxes = acct.mailboxes();
            """
        } else {
            accountFilter = """
            var mailboxes = mail.mailboxes();
            """
        }

        let script = """
        var mail = Application('Mail');
        \(accountFilter)
        var names = [];
        for (var i = 0; i < mailboxes.length; i++) {
            names.push(mailboxes[i].name());
        }
        JSON.stringify(names);
        """
        let (output, error) = runJXA(script)
        if let error { return errorResult(error) }
        return textResult(output)
    }

    private static func getEmails(_ args: JSONObject?) -> MCPCallResult {
        let mailbox = args?["mailbox"]?.stringValue ?? "INBOX"
        let limit = args?["limit"]?.intValue ?? 10
        let escapedMailbox = escapeJSString(mailbox)

        let mailboxAccess: String
        if let account = args?["account"]?.stringValue {
            let escapedAccount = escapeJSString(account)
            mailboxAccess = "var mbox = mail.accounts.byName('\(escapedAccount)').mailboxes.byName('\(escapedMailbox)');"
        } else {
            mailboxAccess = "var mbox = mail.mailboxes.byName('\(escapedMailbox)');"
        }

        let script = """
        var mail = Application('Mail');
        \(mailboxAccess)
        var msgs = mbox.messages();
        var count = Math.min(msgs.length, \(limit));
        var results = [];
        for (var i = 0; i < count; i++) {
            var m = msgs[i];
            results.push({
                id: '' + m.id(),
                subject: m.subject(),
                sender: m.sender(),
                date_received: '' + m.dateReceived(),
                read: m.readStatus()
            });
        }
        JSON.stringify(results);
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
        let escapedMailbox = escapeJSString(mailbox)

        let mailboxAccess: String
        if let account = args?["account"]?.stringValue {
            let escapedAccount = escapeJSString(account)
            mailboxAccess = "var mbox = mail.accounts.byName('\(escapedAccount)').mailboxes.byName('\(escapedMailbox)');"
        } else {
            mailboxAccess = "var mbox = mail.mailboxes.byName('\(escapedMailbox)');"
        }

        let escapedId = escapeJSString(messageId)

        let script = """
        var mail = Application('Mail');
        \(mailboxAccess)
        var msgs = mbox.messages();
        var found = null;
        for (var i = 0; i < msgs.length; i++) {
            if ('' + msgs[i].id() === '\(escapedId)') {
                found = msgs[i];
                break;
            }
        }
        if (!found) {
            JSON.stringify({error: 'message not found with id: \(escapedId)'});
        } else {
            JSON.stringify({
                id: '' + found.id(),
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
        let escapedQuery = escapeJSString(query).lowercased()

        let mailboxAccess: String
        if let account = args?["account"]?.stringValue {
            let escapedAccount = escapeJSString(account)
            if let mailbox = args?["mailbox"]?.stringValue {
                let escapedMailbox = escapeJSString(mailbox)
                mailboxAccess = "var mbox = mail.accounts.byName('\(escapedAccount)').mailboxes.byName('\(escapedMailbox)'); var msgs = mbox.messages();"
            } else {
                mailboxAccess = "var mbox = mail.accounts.byName('\(escapedAccount)').mailboxes.byName('INBOX'); var msgs = mbox.messages();"
            }
        } else if let mailbox = args?["mailbox"]?.stringValue {
            let escapedMailbox = escapeJSString(mailbox)
            mailboxAccess = "var mbox = mail.mailboxes.byName('\(escapedMailbox)'); var msgs = mbox.messages();"
        } else {
            mailboxAccess = "var mbox = mail.mailboxes.byName('INBOX'); var msgs = mbox.messages();"
        }

        let script = """
        var mail = Application('Mail');
        \(mailboxAccess)
        var query = '\(escapedQuery)';
        var results = [];
        for (var i = 0; i < msgs.length && results.length < \(limit); i++) {
            var m = msgs[i];
            var subj = (m.subject() || '').toLowerCase();
            var sender = (m.sender() || '').toLowerCase();
            if (subj.indexOf(query) !== -1 || sender.indexOf(query) !== -1) {
                results.push({
                    id: '' + m.id(),
                    subject: m.subject(),
                    sender: m.sender(),
                    date_received: '' + m.dateReceived(),
                    read: m.readStatus()
                });
            }
        }
        JSON.stringify(results);
        """
        let (output, error) = runJXA(script)
        if let error { return errorResult(error) }
        return textResult(output)
    }

    private static func sendEmail(_ args: JSONObject?) -> MCPCallResult {
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

        let script = """
        var mail = Application('Mail');
        var msg = mail.OutgoingMessage({
            subject: '\(escapedSubject)',
            content: '\(escapedBody)'
        });
        mail.outgoingMessages.push(msg);
        \(recipientLines)
        msg.send();
        'sent';
        """
        let (output, error) = runJXA(script)
        if let error { return errorResult(error) }
        return textResult(output.isEmpty ? "email sent" : output)
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
        let escapedSource = escapeJSString(sourceMailbox)
        let escapedTarget = escapeJSString(targetMailbox)

        let mailboxAccess: String
        let targetAccess: String
        if let account = args?["account"]?.stringValue {
            let escapedAccount = escapeJSString(account)
            mailboxAccess = "var acct = mail.accounts.byName('\(escapedAccount)'); var srcMbox = acct.mailboxes.byName('\(escapedSource)');"
            targetAccess = "var destMbox = acct.mailboxes.byName('\(escapedTarget)');"
        } else {
            mailboxAccess = "var srcMbox = mail.mailboxes.byName('\(escapedSource)');"
            targetAccess = "var destMbox = mail.mailboxes.byName('\(escapedTarget)');"
        }

        let script = """
        var mail = Application('Mail');
        \(mailboxAccess)
        \(targetAccess)
        var msgs = srcMbox.messages();
        var found = null;
        for (var i = 0; i < msgs.length; i++) {
            if ('' + msgs[i].id() === '\(escapedId)') {
                found = msgs[i];
                break;
            }
        }
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
        let escapedMailbox = escapeJSString(mailbox)

        let mailboxAccess: String
        if let account = args?["account"]?.stringValue {
            let escapedAccount = escapeJSString(account)
            mailboxAccess = "var mbox = mail.accounts.byName('\(escapedAccount)').mailboxes.byName('\(escapedMailbox)');"
        } else {
            mailboxAccess = "var mbox = mail.mailboxes.byName('\(escapedMailbox)');"
        }

        let script = """
        var mail = Application('Mail');
        \(mailboxAccess)
        var msgs = mbox.messages();
        var found = null;
        for (var i = 0; i < msgs.length; i++) {
            if ('' + msgs[i].id() === '\(escapedId)') {
                found = msgs[i];
                break;
            }
        }
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
                description: "List mailboxes for a mail account",
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
                description: "Get a list of emails from a mailbox",
                inputSchema: schema(
                    properties: [
                        "account": stringProp("Account name"),
                        "mailbox": stringProp("Mailbox name (default: INBOX)"),
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
                description: "Get a single email by message ID, including full body content",
                inputSchema: schema(
                    properties: [
                        "message_id": stringProp("Message ID"),
                        "account": stringProp("Account name"),
                        "mailbox": stringProp("Mailbox name (default: INBOX)")
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
                description: "Search emails by subject or sender",
                inputSchema: schema(
                    properties: [
                        "query": stringProp("Search query to match against subject and sender"),
                        "account": stringProp("Account name"),
                        "mailbox": stringProp("Mailbox name to search in"),
                        "limit": intProp("Maximum number of results (default: 10)")
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
                        "bcc": stringProp("BCC recipient email address")
                    ],
                    required: ["to", "subject", "body"]
                )
            ),
            category: cat,
            handler: sendEmail
        )

        registry.register(
            MCPTool(
                name: "mail_move",
                description: "Move an email to a different mailbox",
                inputSchema: schema(
                    properties: [
                        "message_id": stringProp("Message ID of the email to move"),
                        "source_mailbox": stringProp("Source mailbox name (default: INBOX)"),
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
                description: "Mark an email as read or unread",
                inputSchema: schema(
                    properties: [
                        "message_id": stringProp("Message ID of the email"),
                        "read": boolProp("true to mark as read, false to mark as unread"),
                        "account": stringProp("Account name"),
                        "mailbox": stringProp("Mailbox name (default: INBOX)")
                    ],
                    required: ["message_id", "read"]
                )
            ),
            category: cat,
            handler: markRead
        )
    }
}
