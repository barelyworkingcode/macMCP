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
/// A mailbox takes two optional descriptions of it changing under the script,
/// both keyed on how many times its `messages` specifier has been read (one
/// read is one Apple Event):
///
/// * `arrival: {after, at, message, repeat}` splices a message in. The
///   collection gets longer, which a column-count check can see.
/// A mailbox marked `byNameHidden: true` is enumerated and named but cannot be
/// reached through `byName`, which is what a nested mailbox does in Mail.
///
/// * `departure: {after, at, repeat}` takes a message back out. Paired with an
///   `arrival` it models a change that is over before the scan looks again,
///   which the id re-read cannot see and only the column lengths can.
/// * `mutation: {after, removeAt, insertAt, message, repeat}` takes one message
///   out and puts another in. The collection is the **same length** before and
///   after, so counting columns cannot see it and only re-reading the id column
///   can.
///
/// `mail.takeOut(account, mailbox, index)` removes one message on demand, so a
/// test can change a mailbox *between* two reads of a specifier a script has
/// already bound -- which is what tells a binding by id from a binding by
/// position.
///
/// Messages resolve by id across every mailbox (`mail.inbox.messages.byId(n)`,
/// and the same accessor off any mailbox), because that is what Mail does; the
/// message's own `mailbox` reports where it really is, and a local On My Mac
/// mailbox raises on `.account`. Collections are callable and carry `name()`
/// and `byName()`, as Mail's do. What the stub does **not** model is a mailbox
/// specifier re-resolving: `byName` hands back the element itself, so only the
/// message-level binding can be pinned here.
///
/// Every mutation is recorded on `mail.log` so a test can assert on what the
/// script did rather than only on what it returned.
enum MailStubJS {
    static let source = """
    function makeMail(spec) {
        var log = {moves: [], created: [], sent: [], saved: [], bodies: [], sourceReads: []};

        // Mail's element collections are callable *and* carry `name()` (one
        // bulk Apple Event for every name) and `byName()`. `Function.name` is
        // read-only on a plain assignment, hence defineProperty.
        function collectionOf(itemsFn, nameOf) {
            var fn = function() { return itemsFn(); };
            Object.defineProperty(fn, 'name', {
                value: function() { return itemsFn().map(nameOf); },
                writable: true, configurable: true
            });
            // Mail matches `byName` at the top level only. It flattens an
            // account's mailbox tree and reports leaf names, so a mailbox it
            // enumerates and names can still be unreachable by that name --
            // `byNameHidden` models one.
            fn.byName = function(n) {
                var items = itemsFn();
                for (var i = 0; i < items.length; i++) {
                    if (items[i]._byNameHidden) continue;
                    if (nameOf(items[i]) === ('' + n)) return items[i];
                }
                return missingElement();
            };
            return fn;
        }

        // What a specifier that resolves to nothing behaves like: `exists()` is
        // false and every other access raises, rather than the call failing on
        // the spot.
        function missingElement() {
            function raise() { throw new Error("Can't get object."); }
            var gone = {name: raise, exists: function() { return false; }, mailboxes: raise, account: raise};
            Object.defineProperty(gone, 'messages', {get: raise});
            return gone;
        }

        function makeMessage(m, box) {
            var msg = {
                _id: m.id,
                _messageId: m.messageId == null ? null : m.messageId,
                _subject: m.subject == null ? '' : m.subject,
                _box: box,
                // `sources` models a message arriving: each call to source()
                // returns the next entry, and the last one repeats. One entry is
                // a message Mail already has in full. `size` is Mail's
                // messageSize -- the wire size, CRLFs included -- and is left
                // undefined to model the property raising, which it does for
                // some messages.
                _sources: m.sources == null ? [m.source == null ? '' : m.source] : m.sources,
                _sourceReads: 0,
                _content: m.content == null ? '' : m.content,
                content: function() { return this._content; },
                _sender: m.sender == null ? '' : m.sender,
                _date: m.date == null ? 0 : m.date,
                _read: m.read ? true : false,
                id: function() { return this._id; },
                messageId: function() { return this._messageId; },
                subject: function() { return this._subject; },
                sender: function() { return this._sender; },
                dateReceived: function() { return new Date(this._date); },
                readStatus: function() { return this._read; },
                source: function() {
                    var at = Math.min(this._sourceReads, this._sources.length - 1);
                    this._sourceReads++;
                    log.sourceReads.push({id: this._id, index: at});
                    return this._sources[at];
                },
                messageSize: function() {
                    if (m.size == null) throw new Error('AppleEvent handler failed.');
                    return m.size;
                }
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
                _reads: 0,
                name: function() { return b.name; }
            };
            // `mb.messages.id()` is a bulk column fetch; `mb.messages[k]` is an
            // element. Mail exposes both off the same specifier, and re-evaluates
            // it on each access, so the stub rebuilds it from the live array
            // rather than snapshotting once.
            Object.defineProperty(box, 'messages', {
                get: function() {
                    // Every access to this specifier is one bulk column fetch,
                    // which is one Apple Event. `arrivals` models a mailbox
                    // that changes between two of them: {after: n, at: i,
                    // message: {...}, repeat: true} splices a message in once
                    // the nth fetch has been served, at index i -- which is
                    // where Mail puts an arriving message, since the collection
                    // is ordered by date received rather than appended to.
                    box._reads++;
                    var arrival = b.arrival;
                    if (arrival && (box._reads === arrival.after
                            || (arrival.repeat && box._reads > arrival.after))) {
                        box._msgs.splice(
                            arrival.at == null ? 0 : arrival.at,
                            0,
                            makeMessage({
                                id: arrival.message.id + '-' + box._reads,
                                subject: arrival.message.subject,
                                sender: arrival.message.sender,
                                date: arrival.message.date
                            }, box)
                        );
                    }
                    // `departure` takes a message back out. Paired with an
                    // `arrival` it models the change that is over before the
                    // scan looks again -- a message spliced in between two
                    // columns and filed away again before the id column is
                    // re-read -- which the id re-read cannot see and only the
                    // column lengths can.
                    var departure = b.departure;
                    if (departure && (box._reads === departure.after
                            || (departure.repeat && box._reads > departure.after))) {
                        var leftAt = departure.at == null ? 0 : departure.at;
                        if (leftAt >= 0 && leftAt < box._msgs.length) box._msgs.splice(leftAt, 1);
                    }
                    // `mutation` is the change an arrival cannot model: one
                    // message leaves as another arrives, so the collection is
                    // the same length before and after. Counting the columns
                    // cannot see it -- only re-reading the id column can, which
                    // is the half of the #48 guard that arrivals leave untested.
                    // {after: n, removeAt: i, insertAt: j, message: {...},
                    //  repeat: true} applies it once the nth fetch is served.
                    var mutation = b.mutation;
                    if (mutation && (box._reads === mutation.after
                            || (mutation.repeat && box._reads > mutation.after))) {
                        var goneAt = mutation.removeAt == null ? 0 : mutation.removeAt;
                        if (goneAt >= 0 && goneAt < box._msgs.length) box._msgs.splice(goneAt, 1);
                        box._msgs.splice(
                            mutation.insertAt == null ? 0 : mutation.insertAt,
                            0,
                            makeMessage({
                                id: mutation.message.id + '-' + box._reads,
                                subject: mutation.message.subject,
                                sender: mutation.message.sender,
                                date: mutation.message.date
                            }, box)
                        );
                    }
                    var m = box._msgs;
                    var spec = {
                        // Mail resolves a message id across *every* mailbox,
                        // not just the collection the specifier hangs off: an
                        // id from Bob's INBOX resolves through Alice's, and the
                        // message's own `mailbox` reports where it really is.
                        // Measured against Mail 16 on the fixture, and the
                        // reason the by-id lookup needs no mailbox to search.
                        byId: function(n) { return byIdSpecifier(n); },
                        id: function() { return m.map(function(x) { return x._id; }); },
                        messageId: function() { return m.map(function(x) { return x._messageId; }); },
                        subject: function() { return m.map(function(x) { return x._subject; }); },
                        sender: function() { return m.map(function(x) { return x._sender; }); },
                        dateReceived: function() { return m.map(function(x) { return new Date(x._date); }); },
                        readStatus: function() { return m.map(function(x) { return x._read; }); },
                        length: m.length
                    };
                    for (var i = 0; i < m.length; i++) spec[i] = positionalSpecifier(box, i);
                    return spec;
                }
            });
            // A mailbox owned by an account answers `account`; a local
            // On My Mac mailbox raises, which is how the real thing behaves and
            // how a by-id lookup tells the two apart.
            Object.defineProperty(box, 'account', {
                get: function() {
                    if (acctName === 'On My Mac') throw new Error("Can't get object.");
                    return {name: function() { return acctName; }};
                }
            });
            box.exists = function() { return true; };
            box._byNameHidden = b.byNameHidden ? true : false;
            (b.messages || []).forEach(function(m) { box._msgs.push(makeMessage(m, box)); });
            return box;
        }

        var accounts = (spec.accounts || []).map(function(a) {
            var boxes = (a.mailboxes || []).map(function(b) { return makeMailbox(b, a.name); });
            return {
                name: function() { return a.name; },
                exists: function() { return true; },
                emailAddresses: function() { return a.emailAddresses || []; },
                mailboxes: collectionOf(function() { return boxes; }, function(b) { return '' + b.name(); })
            };
        });
        var localBoxes = (spec.local || []).map(function(b) { return makeMailbox(b, 'On My Mac'); });

        function everyMessage() {
            var out = [];
            accounts.forEach(function(a) {
                a.mailboxes().forEach(function(b) { b._msgs.forEach(function(m) { out.push(m); }); });
            });
            localBoxes.forEach(function(b) { b._msgs.forEach(function(m) { out.push(m); }); });
            return out;
        }
        function messageById(id) {
            var all = everyMessage();
            for (var i = 0; i < all.length; i++) if (('' + all[i]._id) === ('' + id)) return all[i];
            return null;
        }

        // **A specifier is not the object it resolves to.** JXA re-evaluates it
        // on every property access, so two reads off the same variable can
        // answer for two different messages. Modelling that is the difference
        // between a test that can catch #50 and one that cannot: snapshot the
        // message instead and a positional binding looks as sound as a by-id
        // one.
        var FORWARDED = ['id', 'messageId', 'subject', 'sender', 'dateReceived', 'dateSent',
                         'messageSize', 'source', 'content', 'mailAttachments',
                         'toRecipients', 'ccRecipients'];
        function specifier(resolve, present) {
            function live() {
                var m = resolve();
                if (m == null) throw new Error("Can't get object.");
                return m;
            }
            var spec = {exists: present};
            FORWARDED.forEach(function(k) {
                spec[k] = function() {
                    var m = live();
                    // Mail's own answer for a property it will not produce.
                    if (typeof m[k] !== 'function') throw new Error('AppleEvent handler failed.');
                    return m[k]();
                };
            });
            Object.defineProperty(spec, 'mailbox', {
                get: function() { return live().mailbox; },
                set: function(dest) { live().mailbox = dest; }
            });
            // JXA reaches a property either way round, so `readStatus()` reads
            // and `readStatus = true` writes, off the same name.
            Object.defineProperty(spec, 'readStatus', {
                get: function() { return function() { return live().readStatus(); }; },
                set: function(v) { live()._read = v ? true : false; }
            });
            return spec;
        }

        // Bound by id: re-resolves to the same message every time, or raises.
        function byIdSpecifier(id) {
            return specifier(
                function() { return messageById(id); },
                function() { return messageById(id) !== null; }
            );
        }

        // Bound by position: re-resolves to whatever is at that index now, which
        // after a message leaves is a different message -- silently, with no
        // error. This is what `mb.messages[k]` was.
        function positionalSpecifier(box, index) {
            return specifier(
                function() { return box._msgs[index]; },
                function() { return box._msgs[index] != null; }
            );
        }

        // Mail's unified inbox. Only ever used as somewhere to hang a global
        // `messages.byId()` off, which is all the real one is used for.
        var inbox = {name: function() { return 'All Inboxes'; }, exists: function() { return true; }};
        Object.defineProperty(inbox, 'messages', {
            get: function() { return {byId: function(n) { return byIdSpecifier(n); }}; }
        });

        // Changes a mailbox from the test, *between* two reads of a specifier the
        // script has already bound. That is the condition a loopback fixture
        // cannot be made to hold still for, and it is the one that tells a
        // specifier bound by id from one bound by position: after a message
        // leaves, `messages[k]` is a different message and `messages.byId(n)`
        // is not. Returns the id removed, or null.
        function takeOut(acctName, boxName, at) {
            var boxes = ('' + acctName).toLowerCase() === 'on my mac'
                ? localBoxes
                : (function() {
                    for (var a = 0; a < accounts.length; a++) {
                        if (('' + accounts[a].name()) === ('' + acctName)) return accounts[a].mailboxes();
                    }
                    return [];
                })();
            for (var b = 0; b < boxes.length; b++) {
                if (('' + boxes[b].name()) !== ('' + boxName)) continue;
                var index = at == null ? 0 : at;
                if (index < 0 || index >= boxes[b]._msgs.length) return null;
                return boxes[b]._msgs.splice(index, 1)[0]._id;
            }
            return null;
        }

        return {
            log: log,
            inbox: inbox,
            takeOut: takeOut,
            accounts: collectionOf(function() { return accounts; }, function(a) { return '' + a.name(); }),
            mailboxes: collectionOf(function() { return localBoxes; }, function(b) { return '' + b.name(); })
        };
    }
    """
}
