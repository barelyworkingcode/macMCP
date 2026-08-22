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
/// * `departure: {after, at, repeat}` takes a message back out. Paired with an
///   `arrival` it models a change that is over before the scan looks again,
///   which the id re-read cannot see and only the column lengths can.
/// * `mutation: {after, removeAt, insertAt, message, repeat}` takes one message
///   out and puts another in. The collection is the **same length** before and
///   after, so counting columns cannot see it and only re-reading the id column
///   can.
///
/// A mailbox may also carry `containerRaises: true`, which makes every read of
/// its `container.name()` throw -- the shape of an ancestor that went away
/// mid-walk, and the only way to get a mailbox whose full path cannot be
/// determined.
///
/// A mailbox nests with `container`, which is the **path** of its parent:
/// `{name: 'Sub', container: 'Archive'}` is the fixture's `Archive/Sub`. Mail
/// reports only the leaf name for it, so an account can enumerate two mailboxes
/// called `Archive`, and `mailboxes.byName('Sub')` cannot reach a nested one --
/// both modelled here. What does reach it is its path, which is also what
/// `mailboxes.container.name()` (a bulk column, chainable) is used to build.
/// A mailbox marked `byNameHidden: true` cannot be reached through `byName` at
/// all, which is what drives the fallback to positional specifiers.
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
/// `mail.delete(x)` models Mail's delete command: the message leaves the
/// mailbox it is in and lands on `mail.log.deleted`. A message can also carry
/// `autoSaved: true` (or a whole `headers` string), which is what
/// `allHeaders()` answers with -- the one thing that tells a draft Mail wrote
/// by itself from one that was saved on purpose.
///
/// Every mutation is recorded on `mail.log` so a test can assert on what the
/// script did rather than only on what it returned.
enum MailStubJS {
    static let source = """
    function makeMail(spec) {
        var log = {moves: [], created: [], sent: [], saved: [], bodies: [], sourceReads: [], deleted: []};

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

        // A mailbox collection carries everything the one above does plus the
        // container chain, because a mailbox is identified by its **path** and
        // not by the leaf name Mail reports for it.
        //
        // `mailboxes.container.name()` is one bulk Apple Event giving each
        // mailbox's parent name, null at the top level, and the chain extends:
        // `.container.container.name()`, until a level is entirely null. That
        // is how a path is built, and it is why a path costs a fixed handful of
        // Apple Events for a whole account rather than one per mailbox.
        //
        // `byName` takes a path (`'Projects/Archive'`) and resolves it exactly.
        // A bare name reaches a **top-level** mailbox only, which is what Mail
        // does and why a nested mailbox is unreachable by its leaf name --
        // `mailboxes.byName('Sub')` for `Archive/Sub` is `exists()` false while
        // position 2 reads fine. `byNameHidden: true` models a mailbox that
        // cannot be reached by `byName` at all, which is what drives the
        // fallback to positional specifiers.
        function mailboxCollectionOf(itemsFn) {
            function level(pick) {
                var fn = function() { return pick(); };
                Object.defineProperty(fn, 'name', {
                    value: function() {
                        return pick().map(function(b) { return b == null ? null : '' + b.name(); });
                    },
                    writable: true, configurable: true
                });
                Object.defineProperty(fn, 'container', {
                    get: function() {
                        return level(function() {
                            return pick().map(function(b) { return b == null ? null : b._parent; });
                        });
                    },
                    configurable: true
                });
                return fn;
            }
            var fn = level(itemsFn);
            fn.byName = function(n) {
                var want = '' + n;
                var items = itemsFn();
                for (var i = 0; i < items.length; i++) {
                    if (items[i]._byNameHidden) continue;
                    if (items[i]._path === want) return items[i];
                }
                return missingElement();
            };
            return fn;
        }

        // Resolves each mailbox's `container` (given as the parent's path) to
        // the mailbox object it names, once every mailbox in the collection
        // exists.
        function linkContainers(boxes) {
            var byPath = Object.create(null);
            boxes.forEach(function(b) { byPath[b._path] = b; });
            boxes.forEach(function(b) {
                b._parent = b._containerPath === null ? null : (byPath[b._containerPath] || null);
            });
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
                },
                // Mail's `all headers`, which is how an autosaved draft is
                // told from one somebody saved on purpose: Mail stamps its own
                // with `X-Apple-Auto-Saved: 1`. `autoSaved: true` is the
                // shorthand; `headers` sets the block outright, and a message
                // with neither answers with just its subject, which is what a
                // message whose headers say nothing interesting looks like.
                allHeaders: function() {
                    if (m.headers != null) return '' + m.headers;
                    return 'Subject: ' + this._subject + '\\n'
                        + (m.autoSaved ? 'X-Apple-Auto-Saved: 1\\n' : '');
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
                // `container` is the parent's **path**, so the fixture's
                // `Archive/Sub` is `{name: 'Sub', container: 'Archive'}` and
                // `R4-PROBE-Deep/L2/L3/L4` is
                // `{name: 'L4', container: 'R4-PROBE-Deep/L2/L3'}`. Mail
                // reports only the leaf name, which is the whole problem.
                _containerPath: b.container == null ? null : ('' + b.container),
                _parent: null,
                name: function() { return b.name; }
            };
            box._path = box._containerPath === null ? ('' + b.name) : (box._containerPath + '/' + b.name);
            // Mail answers `container` with an object either way; a top-level
            // mailbox's container simply has no name, which is the stop
            // condition for walking the chain upwards.
            Object.defineProperty(box, 'container', {
                get: function() {
                    // `containerRaises: true` models an ancestor renamed or
                    // deleted while the chain was being walked: Mail answers
                    // the `container` reference and then raises on `name()`.
                    // `mbPathOf` gives up and returns null, which is the only
                    // way to produce a mailbox whose PATH is unknown while its
                    // leaf name is not -- and the leaf name is what the scope
                    // check used to silently fall back to.
                    if (b.containerRaises) {
                        return {name: function() { throw new Error('Invalid index'); },
                                exists: function() { return false; }};
                    }
                    if (box._parent !== null) return box._parent;
                    return {name: function() { return null; }, exists: function() { return false; }};
                }
            });
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
                },
                // Configurable so a test can wrap this getter and change the
                // mailbox at a chosen read without the spec keys above having to
                // model every kind of change. A message being *refiled into
                // another account* is one of those: it does not leave the world,
                // so `byId` keeps resolving it, and only its own account can
                // tell that a row's stamp has stopped being true.
                configurable: true
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
            linkContainers(boxes);
            return {
                name: function() { return a.name; },
                exists: function() { return true; },
                emailAddresses: function() { return a.emailAddresses || []; },
                mailboxes: mailboxCollectionOf(function() { return boxes; })
            };
        });
        var localBoxes = (spec.local || []).map(function(b) { return makeMailbox(b, 'On My Mac'); });
        linkContainers(localBoxes);

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
                         'toRecipients', 'ccRecipients', 'allHeaders'];
        function specifier(resolve, present) {
            function live() {
                var m = resolve();
                if (m == null) throw new Error("Can't get object.");
                return m;
            }
            // `_live` is the specifier's own resolution, exposed so that a
            // command taking an element -- `mail.delete(msg)` -- can act on
            // the message rather than on the specifier wrapping it. Mail
            // resolves the specifier itself; the stub has to be told to.
            var spec = {exists: present, _live: live};
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

        // `mail.delete(x)` -- Mail's delete command, which for a message moves
        // it to Trash rather than erasing it. The stub takes it out of the
        // mailbox it is in and records it, which is all any caller here can
        // observe. It accepts either a message or a specifier for one.
        function deleteElement(el) {
            var m = (el && typeof el._live === 'function') ? el._live() : el;
            if (m == null || m._box == null) throw new Error("Can't get object.");
            var at = m._box._msgs.indexOf(m);
            if (at < 0) throw new Error("Can't get object.");
            m._box._msgs.splice(at, 1);
            log.deleted.push({id: m._id, subject: m._subject, mailbox: m._box.name()});
        }

        return {
            log: log,
            inbox: inbox,
            takeOut: takeOut,
            delete: deleteElement,
            accounts: collectionOf(function() { return accounts; }, function(a) { return '' + a.name(); }),
            mailboxes: mailboxCollectionOf(function() { return localBoxes; })
        };
    }
    """
}
