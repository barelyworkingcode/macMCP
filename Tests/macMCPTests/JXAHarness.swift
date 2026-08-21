import Foundation
import XCTest

/// Runs a plain-JavaScript snippet through `osascript -l JavaScript` and
/// returns its stdout.
///
/// The Mail service builds most of its behaviour as generated JavaScript, so
/// testing the Swift that builds it proves very little on its own. This runs
/// the generated script for real, with `mail` bound to a stub instead of
/// `Application('Mail')`. Nothing in a harnessed script ever calls
/// `Application(...)`, so no Apple Event leaves the process, no TCC prompt can
/// appear, and Mail.app does not need to be running — osascript is being used
/// purely as a JavaScript engine.
///
/// The stubs live in `MailStubJS` and model just enough of Mail's object
/// graph — accounts, mailboxes, bulk `messages.id()` columns, settable
/// `message.mailbox` — for the scripts under test to run unmodified.
enum JXA {
    struct Failure: Error, CustomStringConvertible {
        let status: Int32
        let stderr: String
        var description: String { "osascript exited \(status): \(stderr)" }
    }

    static func run(_ script: String) throws -> String {
        let stdout = String(data: try runRaw(script), encoding: .utf8) ?? ""
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs `script` and returns stdout exactly as osascript wrote it: nothing
    /// trimmed, nothing decoded.
    ///
    /// The byte-level tests need this. `run` hands back a trimmed `String`,
    /// which is fine for JSON but destroys the two things those tests are about
    /// -- the trailing newline osascript appends, and any byte that is not
    /// valid UTF-8 on its own.
    static func runRaw(_ script: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Drain before waiting: a script that prints more than the pipe buffer
        // would otherwise deadlock, which is the same trap runJXAData avoids.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(
                status: process.terminationStatus,
                stderr: String(data: errData, encoding: .utf8) ?? ""
            )
        }
        return outData
    }

    /// Runs `script` and decodes its stdout as a JSON object.
    static func runJSON(_ script: String) throws -> [String: Any] {
        let output = try run(script)
        guard let data = output.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(status: 0, stderr: "not a JSON object: \(output)")
        }
        return obj
    }
}

/// A stub of Mail's scripting object graph, as JavaScript source.
///
/// `makeMail(spec)` takes a plain description of accounts, mailboxes and
/// messages and returns something the generated scripts can drive:
///
/// ```js
/// var mail = makeMail({
///     accounts: [
///         {name: 'Alice', mailboxes: [{name: 'INBOX', messages: [{id: 1}]}, {name: 'Archive'}]},
///         {name: 'Bob',   mailboxes: [{name: 'INBOX', messages: [{id: 2}]}, {name: 'Archive'}]}
///     ]
/// });
/// ```
///
/// Every mutation is recorded on `mail.log` so a test can assert on what the
/// script did rather than only on what it returned.
enum MailStubJS {
    static let source = """
    function makeMail(spec) {
        var log = {moves: [], created: [], sent: [], saved: [], bodies: []};

        function makeMessage(m, box) {
            var msg = {
                _id: m.id,
                _messageId: m.messageId == null ? null : m.messageId,
                _subject: m.subject == null ? '' : m.subject,
                _box: box,
                id: function() { return this._id; },
                messageId: function() { return this._messageId; },
                subject: function() { return this._subject; }
            };
            // `found.mailbox = destMbox` is a property assignment in JXA, so the
            // stub records it through a setter rather than a method. The message
            // really is re-filed, so a read-back of the destination sees it --
            // which is what lets the post-move verification be tested.
            Object.defineProperty(msg, 'mailbox', {
                get: function() { return msg._box; },
                set: function(dest) {
                    log.moves.push({
                        id: msg._id,
                        from: {account: msg._box.acctName, mailbox: msg._box.name()},
                        to: {account: dest.acctName, mailbox: dest.name()}
                    });
                    var at = msg._box._msgs.indexOf(msg);
                    if (at >= 0) msg._box._msgs.splice(at, 1);
                    dest._msgs.push(msg);
                    msg._box = dest;
                }
            });
            return msg;
        }

        function makeMailbox(b, acctName) {
            var box = {
                acctName: acctName,
                _msgs: [],
                name: function() { return b.name; }
            };
            // `mb.messages.id()` is a bulk column fetch; `mb.messages[k]` is an
            // element. Mail exposes both off the same specifier, and re-evaluates
            // it on each access, so the stub rebuilds it from the live array
            // rather than snapshotting once.
            Object.defineProperty(box, 'messages', {
                get: function() {
                    var m = box._msgs;
                    var spec = {
                        id: function() { return m.map(function(x) { return x._id; }); },
                        messageId: function() { return m.map(function(x) { return x._messageId; }); },
                        subject: function() { return m.map(function(x) { return x._subject; }); },
                        length: m.length
                    };
                    for (var i = 0; i < m.length; i++) spec[i] = m[i];
                    return spec;
                }
            });
            (b.messages || []).forEach(function(m) { box._msgs.push(makeMessage(m, box)); });
            return box;
        }

        var accounts = (spec.accounts || []).map(function(a) {
            var boxes = (a.mailboxes || []).map(function(b) { return makeMailbox(b, a.name); });
            return {
                name: function() { return a.name; },
                emailAddresses: function() { return a.emailAddresses || []; },
                mailboxes: function() { return boxes; }
            };
        });
        var localBoxes = (spec.local || []).map(function(b) { return makeMailbox(b, 'On My Mac'); });

        return {
            log: log,
            accounts: function() { return accounts; },
            mailboxes: function() { return localBoxes; }
        };
    }
    """
}
