import Foundation

enum MailService {
    /// Wall-clock ceiling for a single osascript invocation. Mail can wedge for
    /// minutes on an expensive Apple Event, and an unbounded wait would hang the
    /// whole server, so every run gets a deadline and a SIGKILL backstop.
    ///
    /// Not private: it is a default argument of `runJXAData`, which the tests
    /// drive directly.
    static let defaultTimeout: TimeInterval = 120

    /// The bundle every mail_* tool sends Apple Events to. Not private, for the
    /// same reason as above.
    static let mailBundleID = "com.apple.mail"

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
    ///
    /// `automationProbe` exists for the tests. When the automation grant is
    /// taken is the property that keeps a consent-blocked run from hanging, and
    /// it is not observable from the outside: a test has to be able to see the
    /// probe fire and to see what the script had done by then.
    static func runJXAData(
        _ script: String,
        retries: Int = 2,
        timeout: TimeInterval = defaultTimeout,
        scopable: Bool = true,
        automationProbe: (() -> AutomationStatus)? = nil
    ) -> (output: Data, error: String?) {
        // Ask TCC where the automation grant stands *before* running anything.
        // Asking afterwards, on the error path, is too late: while a consent
        // prompt is on screen the check itself blocks -- 12s in one measurement,
        // and still blocked 20s after the script that raised the prompt had been
        // killed -- so the answer has to be taken while nothing is waiting on
        // the user. It costs about 10ms then, against a spawn that costs an
        // order of magnitude more, and it is the difference between reporting
        // "Mail was slow" and reporting the thing that is actually wrong.
        let automation = automationProbe?() ?? PermissionsService.automationStatus(bundleID: mailBundleID)

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
                // Which failure this was is decided by the OSStatus osascript
                // appends, read at the position osascript writes it. Testing
                // the whole of stderr for "-1712" let any string a caller
                // controls impersonate one: a mailbox named `Q (-1712) box`
                // came back as "Mail timed out evaluating the request (-1712)"
                // while the script had thrown `no mailbox named "Q (-1712) box"`
                // -- a -2700 reported as a -1712, with the sentence that said
                // what was wrong thrown away.
                let code = osaStatus(errOutput)?.code

                // -1712 is an Apple Event timeout inside Mail itself. Retrying
                // just spends the same wait again, so surface it instead.
                if code == -1712 {
                    return (Data(), "Mail timed out evaluating the request (-1712). Narrow the scope and try again.")
                }
                if attempt < retries && code == -1728 {
                    Thread.sleep(forTimeInterval: 0.5)
                    continue
                }
                // A script that threw is reporting something the caller can act
                // on, in a sentence the script chose. Hand back that sentence
                // rather than osascript's wrapper around it.
                if let thrown = scriptErrorMessage(errOutput) { return (output, thrown) }
                return (output, errOutput.isEmpty ? "osascript exited with status \(process.terminationStatus)" : errOutput)
            }
            return (output, nil)
        }
        return (Data(), "max retries exceeded")
    }

    /// How a handler script's stdout was understood.
    enum ScriptPayload: Equatable {
        /// A JSON object the handler can read fields out of.
        case object([String: Any])
        /// The script reported a failure. The associated value is the message,
        /// already unwrapped, so it reads like every other mail tool's error
        /// rather than like a JSON blob.
        case failure(String)
        /// Not JSON at all -- a bare string result such as `'done'`.
        case text(String)

        static func == (lhs: ScriptPayload, rhs: ScriptPayload) -> Bool {
            switch (lhs, rhs) {
            case let (.failure(a), .failure(b)): return a == b
            case let (.text(a), .text(b)): return a == b
            case let (.object(a), .object(b)):
                return NSDictionary(dictionary: a).isEqual(to: b)
            default: return false
            }
        }
    }

    /// Classifies a handler script's stdout.
    ///
    /// mail_mark_read and mail_move used to detect a failure with
    /// `output.contains("\"error\"")` and then hand the whole JSON string to the
    /// caller, so a missing message came back as `{"error":"message not found
    /// with id: 99999999"}` while every sibling returned the sentence on its
    /// own. The substring test was also a content check rather than a structural
    /// one: a successful result that happened to contain the characters `"error"`
    /// anywhere -- in a mailbox name, say -- would have been reported as a
    /// failure. Both go away by parsing the thing and reading the field.
    static func scriptPayload(_ output: String) -> ScriptPayload {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .text(output)
        }
        if let message = object["error"] as? String { return .failure(message) }
        return .object(object)
    }

    /// Recovers the sentence a script threw from what osascript wrote to stderr,
    /// or nil when stderr is not a thrown script error.
    ///
    /// A generated script has two ways to report a failure. Returning
    /// `{error: '...'}` goes through `scriptPayload` and reaches the caller as
    /// prose. Throwing does not: osascript exits non-zero, and the message came
    /// back wrapped in its own error text --
    ///
    ///     execution error: Error: account "Alice" has no mailbox named "Receipts" (-2700)
    ///
    /// -- doubled `Error:` and an OSStatus included. That is the shape #10 was
    /// filed about, and it survived in every path that refuses by throwing:
    /// `mail_move`'s missing destination mailbox (added by the fix for #4), and
    /// `account not found` from `mail_move`, `mail_mark_read`, `mail_get_email`
    /// and `mail_get_source`. Unwrapping here rather than in each script fixes
    /// the ones that exist and the ones written later, and leaves the scripts
    /// free to throw, which is the natural thing to do from inside an IIFE.
    ///
    /// Only `-2700` is unwrapped: that is the code osascript uses for "the
    /// script threw", so the text after it is the script's own. Every other
    /// code -- `-1712` from Mail, `-1728` for an unresolvable reference, a
    /// syntax error's `0:7: syntax error:` -- is macMCP's problem or Mail's,
    /// and the raw text with its number is the evidence for whoever debugs it.
    ///
    /// The `Error:` that osascript prefixes is always dropped. A second one,
    /// which is the JavaScript `Error` class naming itself, is dropped too;
    /// `TypeError:` and friends are kept, because a thrown `TypeError` is a bug
    /// in the script rather than a message for the caller and the class name is
    /// the useful part of it.
    static func scriptErrorMessage(_ stderr: String) -> String? {
        let prefix = "execution error: "
        guard let status = osaStatus(stderr), status.code == -2700,
              status.text.hasPrefix(prefix) else { return nil }
        var message = String(status.text.dropFirst(prefix.count))
        guard message.hasPrefix("Error: ") else { return nil }
        message = String(message.dropFirst("Error: ".count))
        // `throw new Error('')` reaches stderr as `execution error: Error: Error
        // (-2700)` -- the class naming itself with nothing after it. Unwrapping
        // that hands the caller the word "Error", which says less than the raw
        // line does, so the raw line is kept.
        if message == "Error" { return nil }
        if message.hasPrefix("Error: ") { message = String(message.dropFirst("Error: ".count)) }
        message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }

    /// Splits the OSStatus off the end of an osascript error, returning the text
    /// before it and the code.
    ///
    /// osascript puts the code in exactly one place: the end of the error, as
    /// ` (-NNNN)`. Everything before that is the message, and a message can
    /// contain anything a caller passed in -- a mailbox name, an account name --
    /// including something that looks like a code. Matching a code anywhere in
    /// stderr therefore lets the caller's own text decide how their error is
    /// reported, which is how `mail_move` on a mailbox named `Q (-1712) box`
    /// came back as a Mail timeout instead of "no mailbox named …".
    ///
    /// Only negative codes are recognised: that is what osascript emits, and it
    /// keeps an ordinary parenthesised number at the end of a sentence from
    /// being read as a status.
    static func osaStatus(_ stderr: String) -> (text: String, code: Int)? {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(")"),
              let opening = trimmed.range(of: " (-", options: .backwards) else { return nil }
        let digits = trimmed[opening.upperBound..<trimmed.index(before: trimmed.endIndex)]
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let magnitude = Int(digits) else { return nil }
        return (String(trimmed[trimmed.startIndex..<opening.lowerBound]), -magnitude)
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
    /// What the scan, `mail_get_emails` and `mail_get_email` all call Mail's
    /// app-level mailboxes -- the ones that belong to no account.
    ///
    /// The scan has always labelled their rows `On My Mac:<mailbox>`, so a
    /// caller was handed rows from a mailbox that `mail_list_mailboxes` did not
    /// name and that no `account` argument would reach: `resolveTargets` passed
    /// the string straight through and the scope lookup threw `account not
    /// found`. It is now a name every mail tool accepts (#54), which is what
    /// relay's resource scoping needs -- it cannot scope what the enumeration
    /// does not name.
    static let localAccountName = "On My Mac"

    /// Whether an `account` argument names the local boxes rather than an
    /// account Mail holds. Case-insensitive, like every other account match here.
    static func isLocalAccount(_ account: String) -> Bool {
        account.lowercased() == localAccountName.lowercased()
    }

    private enum BoxScope {
        /// Every mailbox of the named account. The JXA throws when it is missing.
        case account(String)
        /// Mail's app-level "On My Mac" mailboxes only.
        case local
        /// Every account's mailboxes plus the local On-My-Mac boxes.
        case everything
    }

    /// JXA that builds `var <varName> = [{mbox, acctName, name, path}]` for
    /// `scope`. Note: Mail returns account.mailboxes() already flattened (nested
    /// folders included), so no recursion is needed -- but the names it reports
    /// are **leaf** names, which is why every entry also carries a path.
    /// JavaScript that gives a Mail collection's elements an identity, and binds
    /// each element by that identity.
    ///
    /// Two separate problems, one helper.
    ///
    /// **A leaf name does not identify a mailbox.** Mail flattens an account's
    /// mailbox tree and reports leaf names, so `Projects/Archive` beside a
    /// top-level `Archive` gives an account **two** mailboxes called `Archive`,
    /// and one account can hold two `Trash`es and two `Drafts`es. Anything that
    /// resolves, labels or excludes a mailbox by that name is guessing between
    /// them -- which is how a `mail_move` to `"Trash"` filed a message into a
    /// user's project folder and reported `verified: true`.
    ///
    /// What identifies it is the **path**: the leaf names of its containers,
    /// outermost first, joined with `/`. Three things make that the right
    /// choice rather than merely a unique label, all measured against the
    /// fixture (Mail 16.0, 30 mailboxes on one account):
    ///
    /// * It is what Mail itself accepts. `mailboxes.byName('Projects/Archive')`
    ///   resolves, and `byName('Archive')` resolves to the **top-level** one --
    ///   so a path is a handle, not just a name, and a bare name is a path with
    ///   one component. All 30 paths resolved, including the nested ones whose
    ///   leaf name does not (`byName('Sub')` for `Archive/Sub` is `exists()`
    ///   false) and including names carrying quotes, apostrophes, spaces,
    ///   ampersands, emoji and Hebrew.
    /// * It cannot be ambiguous. Mail treats `/` in a mailbox name as a
    ///   separator -- creating a mailbox named `a/b` produces a mailbox `b`
    ///   inside a mailbox `a` -- so no leaf name can contain one, and siblings
    ///   are unique.
    /// * It is cheap. The containers come back as bulk columns, one Apple Event
    ///   per level of nesting for the whole collection:
    ///   `mailboxes.container.name()`, then `.container.container.name()`, until
    ///   a level is entirely null. Bob's 30 mailboxes, 4 levels deep: 6 Apple
    ///   Events, ~100ms -- against ~520ms for the 30 `exists()` probes this
    ///   replaces.
    ///
    /// **A collection read twice is not the same collection.** Every collection
    /// Mail hands back is indexed by **position**, and JXA re-evaluates a
    /// specifier on every property access rather than snapshotting the object
    /// behind it. `boxes[i]` therefore means "whatever is at position i right
    /// now". The names and the container columns are separate Apple Events read
    /// in lockstep by index, exactly like the message scan's columns, so they
    /// get exactly the message scan's guard: the name column is read again at
    /// the end and has to come back identical, and every container column has
    /// to be the same length. The `exists()` probes that used to sit *between*
    /// the two reads -- ~386ms of the ~400ms window measured on Bob -- are gone
    /// from it entirely.
    ///
    /// The binding is `collection.byName(path)`, which re-resolves by identity
    /// and so answers for the same mailbox every time or raises. Two guards on
    /// it, neither costing more than one Apple Event:
    ///
    /// * A path that is not unique in the collection keeps the positional
    ///   specifier. Mail cannot produce one (siblings are unique) but a
    ///   collection with no containers at all can -- `mail.accounts` reaches
    ///   this helper too, and two accounts may share a name.
    /// * One probe per collection, on the deepest path, says whether this Mail
    ///   resolves paths at all; if it does not, the whole collection falls back
    ///   to positional specifiers, which is what it used before. Per-element
    ///   probes are what made the old window 400ms wide, and what the probe
    ///   guards against is a property of the collection rather than of one
    ///   mailbox.
    ///
    /// `boundByName` returns `null` when the collection would not hold still
    /// across three attempts. Callers turn that into an `unstable` report or a
    /// refusal; none of them guess.
    /// Not private: several generated scripts are only meaningful with these
    /// helpers in scope, so a test that runs one has to emit them too.
    static let boundByNameJXA = """
    var MB_MAX_DEPTH = 16;
    var MB_ATTEMPTS = 3;
    function mbSameNames(before, after) {
        if (before.length !== after.length) return false;
        for (var i = 0; i < before.length; i++) {
            if ((before[i] == null) !== (after[i] == null)) return false;
            if (before[i] != null && ('' + before[i]) !== ('' + after[i])) return false;
        }
        return true;
    }
    // The path of one already-resolved mailbox, asked of the mailbox itself.
    // Used where there is no collection to read a column from -- a message
    // saying which mailbox it is in. Costs one Apple Event per level plus one:
    // the container of a top-level mailbox answers `name()` with null rather
    // than raising, which is the stop condition.
    function mbPathOf(box) {
        var parts = [];
        var cur = box;
        for (var d = 0; d <= MB_MAX_DEPTH; d++) {
            var nm = null;
            try { nm = cur.name(); } catch (e) { return null; }
            if (nm == null) break;
            parts.unshift('' + nm);
            try { cur = cur.container; } catch (e) { break; }
            if (cur == null) break;
        }
        return parts.length === 0 ? null : parts.join('/');
    }
    function boundByName(collection) {
        for (var attempt = 0; attempt < MB_ATTEMPTS; attempt++) {
            // --- the window. Bulk column fetches and nothing else: no probe,
            // no per-element access, nothing that can block.
            var names = collection.name();
            var levels = [];
            var up = collection;
            for (var d = 0; d < MB_MAX_DEPTH; d++) {
                var level = null;
                // A collection with no container chain (mail.accounts) raises
                // here, which is the same answer as "everything is top level".
                try { up = up.container; level = up.name(); } catch (e) { break; }
                if (level == null || level.length !== names.length) { levels = null; break; }
                levels.push(level);
                var deeper = false;
                for (var i = 0; i < level.length; i++) { if (level[i] != null) { deeper = true; break; } }
                if (!deeper) break;
            }
            var recheck = collection.name();
            // --- window closed. Everything below is arithmetic on what came
            // back, or one probe that cannot mispair anything.
            if (levels === null) continue;
            if (!mbSameNames(names, recheck)) continue;

            var out = [];
            for (var i = 0; i < names.length; i++) {
                var parts = ['' + names[i]];
                for (var d = 0; d < levels.length; d++) {
                    if (levels[d][i] == null) break;
                    parts.unshift('' + levels[d][i]);
                }
                out.push({element: null, name: '' + names[i], path: parts.join('/'), depth: parts.length - 1});
            }
            var once = Object.create(null);
            for (var i = 0; i < out.length; i++) once[out[i].path] = (once[out[i].path] || 0) + 1;

            var deepest = -1;
            for (var i = 0; i < out.length; i++) {
                if (once[out[i].path] !== 1) continue;
                if (deepest < 0 || out[i].depth > out[deepest].depth) deepest = i;
            }
            var pathsBind = false;
            if (deepest >= 0) {
                try { pathsBind = collection.byName(out[deepest].path).exists() === true; } catch (e) { pathsBind = false; }
            }
            var needElements = !pathsBind;
            for (var i = 0; i < out.length && !needElements; i++) {
                if (once[out[i].path] !== 1) needElements = true;
            }
            var elements = null;
            if (needElements) {
                // The fallback, and a second window of its own. Positional
                // specifiers are what this helper exists to avoid, so they are
                // fetched only when there is nothing better -- and then under
                // the same guard, because fetching them lazily further down
                // would reopen exactly the window this closes.
                elements = collection();
                if (elements.length !== names.length) continue;
                if (!mbSameNames(names, collection.name())) continue;
            }
            for (var i = 0; i < out.length; i++) {
                out[i].element = (pathsBind && once[out[i].path] === 1)
                    ? collection.byName(out[i].path)
                    : elements[i];
            }
            return out;
        }
        return null;
    }
    // What a caller does with a collection that would not hold still. Nothing
    // here guesses: a scan reports the mailboxes it could not read, and
    // anything that acts on one mailbox refuses outright.
    var MB_UNSTABLE = MB_UNSTABLE || [];
    function boundByNameOrReport(collection, label) {
        var bound = boundByName(collection);
        if (bound !== null) return bound;
        // Nothing in it can be bound, but the names are still readable, and
        // naming the mailboxes that could not be read is the difference
        // between a short answer and a short answer presented as a complete
        // one. The entries are carried through with no element so that the
        // caller's own filter applies to them: what comes back then names the
        // mailboxes in scope rather than every mailbox the account holds.
        var names = null;
        try { names = collection.name(); } catch (e) { names = null; }
        if (names === null || names.length === 0) { MB_UNSTABLE.push(label); return []; }
        var out = [];
        for (var i = 0; i < names.length; i++) {
            out.push({element: null, name: '' + names[i], path: '' + names[i], depth: 0});
        }
        return out;
    }
    function boundByNameOrThrow(collection, what) {
        var bound = boundByName(collection);
        if (bound !== null) return bound;
        throw new Error(what + ' kept changing while it was being read, so no mailbox could be identified; nothing was done. This is transient: try again in a moment.');
    }
    """

    private static func collectBoxesJXA(_ scope: BoxScope, varName: String) -> String {
        let pushAccountBoxes = """
                var acctName = accts[ai].name;
                var mboxes = boundByNameOrReport(accts[ai].element.mailboxes, acctName + ':<mailbox list>');
                for (var mj = 0; mj < mboxes.length; mj++) {
                    sink.push({mbox: mboxes[mj].element, acctName: acctName, name: mboxes[mj].name, path: mboxes[mj].path});
                }
        """
        let pushLocalBoxes = """
            var localBoxes = boundByNameOrReport(mail.mailboxes, 'On My Mac:<mailbox list>');
            for (var lj = 0; lj < localBoxes.length; lj++) {
                sink.push({mbox: localBoxes[lj].element, acctName: 'On My Mac', name: localBoxes[lj].name, path: localBoxes[lj].path});
            }
        """

        let body: String
        switch scope {
        case .account(let account):
            let escapedAccount = escapeJSString(account)
            body = """
            var accts = boundByNameOrThrow(mail.accounts, 'the account list');
            for (var ai = 0; ai < accts.length; ai++) {
                if (accts[ai].name.toLowerCase() === '\(escapedAccount)'.toLowerCase()) {
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
            var accts = boundByNameOrThrow(mail.accounts, 'the account list');
            for (var ai = 0; ai < accts.length; ai++) {
        \(pushAccountBoxes)
            }
        \(pushLocalBoxes)
            return sink;
        """
        }

        return """
        \(boundByNameJXA)
        var \(varName) = (function() {
            var sink = [];
        \(body)
        })();
        """
    }

    /// Convenience for the by-id helpers, where a nil account means "look
    /// everywhere" rather than "look at the local boxes".
    private static func collectBoxesJXA(account: String?, varName: String) -> String {
        guard let account else { return collectBoxesJXA(.everything, varName: varName) }
        return collectBoxesJXA(isLocalAccount(account) ? .local : .account(account), varName: varName)
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
    /// The mailbox scan, minus the `var mail = Application('Mail');` line.
    ///
    /// Not private, and split from the handler, for the same reason the source
    /// and move scripts are: the logic worth testing is in the JavaScript, and
    /// a test has to be able to run it against a stub whose mailbox changes
    /// underneath it.
    static func scanScriptJXA(
        account: String?,
        mailbox: String,
        query: String?,
        searchRecipients: Bool,
        limit: Int
    ) -> String {
        // `nil` here means the local boxes, not "everywhere": the caller scans one
        // account per osascript and passes nil for the local pass. Naming them
        // explicitly reaches the same place.
        let collect = collectBoxesJXA(
            account.map { isLocalAccount($0) ? BoxScope.local : .account($0) } ?? .local,
            varName: "allBoxes"
        )

        let filter: String
        if mailbox.lowercased() == "all" {
            // Object.create(null) rather than {}: a mailbox named "constructor"
            // or "toString" would otherwise inherit a truthy Object.prototype
            // value and be silently dropped from the scan.
            filter = """
        var SKIP = Object.create(null);
        ['trash','junk','spam','junk email','deleted items','deleted messages','drafts','outbox']
            .forEach(function(n) { SKIP[n] = 1; });
        // Excluded by **identity**, not by leaf name. An account's own Trash is
        // the one at the root of it; a folder a user made called `Trash` three
        // levels down inside a project is ordinary mail, and matching the leaf
        // name dropped it from every scan. Measured on the fixture: 35 messages
        // reported against 38 on disk, `scan_complete: true`,
        // `skipped_mailboxes: []`.
        //
        // What is left out is now named. `all` means "everything except the
        // account's own Trash, Junk, Drafts and Outbox", and a caller who is
        // not told which mailboxes those were cannot tell a short count from a
        // complete one -- the same thing #57 fixed for mailboxes that could not
        // be read.
        var excluded = [];
        var entries = [];
        for (var f = 0; f < allBoxes.length; f++) {
            var box = allBoxes[f];
            if (box.path.indexOf('/') < 0 && SKIP[box.name.toLowerCase()]) {
                excluded.push(box.acctName + ':' + box.path);
            } else {
                entries.push(box);
            }
        }
        """
        } else {
            let escaped = escapeJSString(mailbox)
            // A miss here is normal -- the caller scans each account separately
            // and only reports "no such mailbox" if every account came up empty.
            //
            // A path wins over a leaf name, and a bare name is a path with one
            // component, so `mailbox: "Archive"` is the mailbox at the root of
            // the account rather than whichever `Archive` Mail lists first --
            // the same rule `mailboxInAccountJXA` resolves a destination by, so
            // a name means the same mailbox to a read as it does to a move.
            // The leaf fallback is what lets `Sub` reach `Archive/Sub`; unlike
            // the move path it does not refuse when several mailboxes carry the
            // name, because rows come back labelled with their own paths and
            // reading two mailboxes is not a wrong answer, while filing into
            // one of two is.
            filter = """
        var excluded = [];
        var WANT = '\(escaped)'.toLowerCase();
        var entries = allBoxes.filter(function(b) { return b.path.toLowerCase() === WANT; });
        if (entries.length === 0) {
            entries = allBoxes.filter(function(b) { return b.name.toLowerCase() === WANT; });
        }
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
        \(queryLine)
        var LIMIT = \(max(limit, 1));
        \(collect)
        \(filter)

        var rows = [], scanned = [], skipped = [], unstable = [], total = 0, messagesScanned = 0;
        // Gmail-style accounts file every message in both INBOX and "All Mail",
        // so ids are deduplicated across this account's mailboxes. Without it
        // `total` counts each message once per mailbox it appears in.
        var seen = Object.create(null);

        // Each column below is its own Apple Event, and they are read in
        // lockstep by index. A mailbox that changes between two of them pairs
        // one message's id with another message's subject -- and the id is the
        // handle mail_move, mail_mark_read and mail_get_email act on. So the id
        // column is read again at the end and has to come back the same.
        function unchanged(before, after) {
            if (before.length !== after.length) return false;
            for (var i = 0; i < before.length; i++) {
                if ('' + before[i] !== '' + after[i]) return false;
            }
            return true;
        }
        function sameLength(ids, columns) {
            for (var c = 0; c < columns.length; c++) {
                if (columns[c] !== null && columns[c].length !== ids.length) return false;
            }
            return true;
        }

        for (var e = 0; e < entries.length; e++) {
            var label = entries[e].acctName + ':' + entries[e].path;
            // A mailbox whose collection would not hold still long enough to be
            // identified. It is reported here rather than where it was read, so
            // the caller is told about the mailboxes in scope and not about
            // every mailbox the account happens to hold.
            if (entries[e].mbox === null) { unstable.push(label); continue; }
            try {
                var mb = entries[e].mbox;
                var ids = null, su = null, se = null, dt = null, rd = null;
                var tos = null, ccs = null, tns = null, cns = null;
                var aligned = false;
                // Three tries: a message arriving mid-scan is a moment, not a
                // state, so the next read almost always lands cleanly.
                for (var attempt = 0; attempt < 3 && !aligned; attempt++) {
                    ids = mb.messages.id();
                    if (ids.length === 0) { aligned = true; break; }
                    su = mb.messages.subject();
                    se = mb.messages.sender();
                    dt = mb.messages.dateReceived();
                    rd = mb.messages.readStatus();
        \(recipientFetch)
                    aligned = sameLength(ids, [su, se, dt, rd, tos, ccs, tns, cns])
                        && unchanged(ids, mb.messages.id());
                }
                // Reporting a mailbox as unread is a smaller wrong than
                // reporting a message under another message's id.
                if (!aligned) { unstable.push(label); continue; }
                if (ids.length > 0) {
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
                            mailbox: entries[e].path,
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
        for (var u = 0; u < MB_UNSTABLE.length; u++) unstable.push(MB_UNSTABLE[u]);
        JSON.stringify({rows: rows, total: total, scanned: scanned, skipped: skipped, unstable: unstable, excluded: excluded, matched: entries.length, messages_scanned: messagesScanned});
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
    ///
    /// Not private: what it reports when a mailbox could not be read is a claim
    /// about the world, and the tests pin it directly rather than through a
    /// mailbox.
    struct ScanOutcome {
        var rows: [[String: Any]] = []
        var total = 0
        var messagesScanned = 0
        var scanned: [String] = []
        var skipped: [String] = []
        /// Mailboxes that changed while their columns were being read, so no
        /// row from them could be trusted to pair the right id with the right
        /// subject. Reported rather than silently dropped.
        var unstable: [String] = []
        var failed: [String] = []
        /// Mailboxes `mailbox: "all"` deliberately left out: an account's own
        /// Trash, Junk, Drafts and Outbox.
        ///
        /// They are out of scope rather than unread, so they do not make
        /// `scan_complete` false -- a flag that is false for every `all` scan
        /// would say nothing, which is why the summary boolean on
        /// `mail_get_source` was removed. But leaving them unnamed is what let
        /// a nested `R4-PROBE-Deep/Trash` disappear from a scan that reported
        /// `scan_complete: true` and `skipped_mailboxes: []`, so they are
        /// named.
        var excluded: [String] = []
        var matchedMailbox = false

        /// Whether every mailbox in scope was actually read.
        ///
        /// `total_messages` and `total_matches` count what *was* read, so when
        /// this is false they are a floor rather than a total -- and a caller
        /// who does not know to look at `unstable_mailboxes`,
        /// `skipped_mailboxes` and `failed_accounts` reads a short count as a
        /// complete one. It is reported unconditionally, true or false: a flag
        /// that only appears when something is wrong is one a caller has to
        /// already suspect before it helps.
        var scanComplete: Bool { unstable.isEmpty && skipped.isEmpty && failed.isEmpty }

        /// What was not read, in words, for the same reason.
        var incompleteNote: String? {
            guard !scanComplete else { return nil }
            var parts: [String] = []
            if !unstable.isEmpty {
                parts.append("\(unstable.joined(separator: ", ")) kept changing while being read, so no row from there could be trusted to pair the right id with the right subject (transient — try again in a moment)")
            }
            if !skipped.isEmpty {
                parts.append("\(skipped.joined(separator: ", ")) could not be read")
            }
            if !failed.isEmpty {
                parts.append("\(failed.joined(separator: "; "))")
            }
            return "Not every mailbox in scope was read, so the counts here are a floor rather than a total: "
                + parts.joined(separator: "; ") + "."
        }
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
    /// Not private: mapping "On My Mac" onto the local pass is the whole of
    /// what makes those mailboxes scopable, and it is worth pinning without a
    /// mailbox.
    static func resolveTargets(account: String?) -> (targets: [String?], error: String?) {
        // `nil` is the local pass, so scoping to On My Mac is that pass alone.
        if let account { return ([isLocalAccount(account) ? nil : account], nil) }
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
            let script = """
            var mail = Application('Mail');
            \(scanScriptJXA(
                account: account,
                mailbox: mailbox,
                query: query,
                searchRecipients: searchRecipients,
                limit: limit
            ))
            """
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
            outcome.unstable.append(contentsOf: obj["unstable"] as? [String] ?? [])
            outcome.excluded.append(contentsOf: obj["excluded"] as? [String] ?? [])
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
    static func scanFailure(_ outcome: ScanOutcome, targets: [String?], mailbox: String) -> MCPCallResult? {
        if outcome.failed.count == targets.count {
            return errorResult("scan failed for every account — \(outcome.failed.joined(separator: "; "))")
        }
        // Every mailbox in scope changed under the read, so there is nothing to
        // report -- and reporting nothing as `total_messages: 0` beside
        // `isError: false` is an affirmative claim that they are empty. The
        // mailbox this fired on held thousands of messages. A caller who does
        // not read `unstable_mailboxes` cannot tell the two apart, and the
        // answer to "I could not read this" is not "it is empty".
        if outcome.scanned.isEmpty && !outcome.unstable.isEmpty {
            let one = outcome.unstable.count == 1
            return errorResult(
                "\(outcome.unstable.joined(separator: ", ")) kept changing while being read — "
                + "every attempt paired one message's id with another message's subject, so no row from "
                + (one ? "it" : "them") + " could be returned, and "
                + (one ? "it was" : "they were") + " the whole of the scope. "
                + "This is transient: try again in a moment, or narrow the scope to a quieter mailbox."
            )
        }
        if !outcome.matchedMailbox && mailbox.lowercased() != "all" {
            return errorResult("no mailbox named \"\(mailbox)\" found — use mail_list_mailboxes to see available names, or pass mailbox \"all\"")
        }
        return nil
    }

    /// How many times a by-Message-ID lookup will re-read a mailbox that changed
    /// underneath it. The same allowance the scan takes, for the same reason: a
    /// mailbox changing under a read is a moment, not a state.
    private static let findAttempts = 3

    /// How many times a script that **changes** something may be re-run.
    ///
    /// Zero, and that is the whole point. `runJXAData` retries by running the
    /// *entire* script again, so a -1728 raised after `found.mailbox =
    /// destMbox` has already executed re-runs the move. Same-account that is
    /// merely wasteful; across accounts the move is a re-upload and the
    /// numeric id does not survive it, so the retry's `findMessageJXA` finds
    /// nothing and the caller is told "message not found with id: N" for a
    /// move that succeeded. `mail_send` and `mail_create_draft` have always
    /// passed 0 for the same reason; `mail_move` and `mail_mark_read` were
    /// left on the default.
    static let mutatingRetries = 0

    /// What a caller's `message_id` can be matched against.
    enum MessageHandle: Equatable {
        /// Mail's own numeric message id.
        case numeric(Int)
        /// An RFC 5322 Message-ID header value, angle brackets stripped.
        case rfc(String)
        /// Neither, so no message can carry it.
        case unmatchable
    }

    /// Classifies a `message_id` argument. Not private so the classification can
    /// be pinned without a mailbox.
    ///
    /// Angle brackets are optional -- `<x@y>` and `x@y` are the same handle. An
    /// identifier that is neither a plain integer nor something with an `@` in it
    /// is `unmatchable` rather than "search for it anyway": the old code compared
    /// such a string against the numeric id column, which could never match, so
    /// this is the same answer arrived at without the search. The integer has to
    /// round-trip, so `0123` stays unmatchable exactly as it was before rather
    /// than quietly becoming 123.
    static func messageHandle(_ raw: String) -> MessageHandle {
        var bare = raw
        if bare.hasPrefix("<") { bare.removeFirst() }
        if bare.hasSuffix(">") { bare.removeLast() }
        if let numeric = Int(bare), String(numeric) == bare { return .numeric(numeric) }
        if bare.contains("@") { return .rfc(bare) }
        return .unmatchable
    }

    /// JXA snippet that binds `found` to one message, plus `foundAccount` and
    /// `foundMailbox` saying where it is. `found` is null when nothing matched.
    ///
    /// **`found` is bound by identity, never by position** -- issue #50. This
    /// used to end with `found = subset[i].mbox.messages[k]`, an index into a
    /// bulk id column. JXA re-resolves a specifier on *every* property access
    /// rather than snapshotting the object, so that `found` meant "whatever is
    /// at position k right now" and each read off it could land on a different
    /// message than the last one did. Measured on the fixture at ~3,000 messages
    /// with continuous delivery, `mail_get_email` was wrong in 26 of 60 calls,
    /// and in 18 of those it returned the right id, the right subject and the
    /// right `rfc_message_id` beside **another message's body** -- a shape
    /// nothing in the response lets a caller detect. `mail_move` was worse
    /// still: it resolves the destination mailbox between reading the id and
    /// assigning `found.mailbox`, and reported no id at all.
    ///
    /// `messages.byId()` is the fix. It re-resolves on every access too, but by
    /// id, so it answers for the same message every time or raises. Two things
    /// about it, both measured against Mail 16:
    ///
    /// * Resolution is **global**, not scoped to the collection the specifier
    ///   hangs off: an id from Bob's INBOX resolves through Alice's, and the
    ///   message's own `mailbox` (and `mailbox.account`) says where it really
    ///   is. So a numeric lookup needs no mailbox enumeration at all -- it is
    ///   one Apple Event to resolve and two to locate, against one bulk id
    ///   column per mailbox before. On a 3,887-message mailbox that is ~11ms
    ///   against 54ms for the column it replaces.
    /// * A local On My Mac mailbox raises on `.account`, which is how the two
    ///   are told apart.
    ///
    /// An RFC Message-ID cannot be resolved that way -- Mail indexes messages by
    /// its own id -- so that path still reads a column to translate the header
    /// value into a numeric id, then binds by that id and **asks the bound
    /// message for its own Message-ID**. Whatever the two columns did between
    /// them, a shifted pairing cannot get past a message answering for itself.
    ///
    /// Matching an RFC Message-ID matters for drafts on IMAP accounts: saving a
    /// draft uploads it, the server hands back its own copy, and Mail's numeric
    /// id for the local one is dead within seconds -- while the Message-ID header
    /// survives the round trip.
    /// Not private: the binding this establishes is the whole of #50, and it
    /// can only be pinned by running the generated script against a mailbox that
    /// changes between two reads of the message it bound.
    static func findMessageJXA(account: String?, mailbox: String, messageId: String) -> String {
        let accountExpr = account.map { "'\(escapeJSString($0))'" } ?? "null"
        // Naming an account that does not exist is a different answer from not
        // finding the message in it. The numeric path no longer walks the
        // accounts to build a search scope, so it has to ask on its own account.
        let accountCheck = account.flatMap { account -> String? in
            // On My Mac is not in `mail.accounts()` -- it is the absence of one --
            // but it is a name every other mail tool accepts, so it is not a miss.
            if isLocalAccount(account) { return nil }
            return """
            (function() {
                var known = mail.accounts.name();
                for (var i = 0; i < known.length; i++) {
                    if (('' + known[i]).toLowerCase() === ('' + FM_ACCOUNT).toLowerCase()) return;
                }
                throw new Error('account not found: \(escapeJSString(account))');
            })();
            """
        } ?? ""

        let preamble = """
    \(boundByNameJXA)
    var found = null; var foundAccount = null; var foundMailbox = null;
    var FM_ACCOUNT = \(accountExpr);
    function fmBare(v) { return v == null ? null : ('' + v).replace(/^</, '').replace(/>$/, ''); }
    // Where a message actually is, asked of the message rather than of the
    // collection it was reached through: `byId` resolves across every account,
    // so the specifier used to reach it says nothing about the answer.
    //
    // `mailbox` is the **path**, because the leaf name does not identify the
    // mailbox: an account holding `Projects/Archive` beside a top-level
    // `Archive` answered `"mailbox": "Archive"` for a message in either, and
    // that string is what `moved_from` reported and what a caller would pass
    // back as a scope. Walking the containers costs one Apple Event per level
    // plus one -- ~35ms for a top-level mailbox, ~80ms four deep.
    function fmLocate(msg) {
        var box = null;
        try { box = msg.mailbox; } catch (e) { return null; }
        var boxName = null;
        try { boxName = '' + box.name(); } catch (e) { return null; }
        var boxPath = mbPathOf(box);
        if (boxPath === null) boxPath = boxName;
        // A local On My Mac mailbox has no account and raises here.
        var acctName = 'On My Mac';
        try { acctName = '' + box.account.name(); } catch (e) { acctName = 'On My Mac'; }
        return {account: acctName, mailbox: boxPath, leaf: boxName};
    }
    function fmInScope(at) {
        return FM_ACCOUNT === null
            || ('' + at.account).toLowerCase() === ('' + FM_ACCOUNT).toLowerCase();
    }
    function fmBind(msg, at) { found = msg; foundAccount = at.account; foundMailbox = at.mailbox; }
    \(accountCheck)
    """

        switch messageHandle(messageId) {
        case .unmatchable:
            // Nothing can carry this identifier, so `found` stays null and the
            // caller reports it not found -- the same answer the search used to
            // arrive at, without the Apple Events.
            return preamble

        case .numeric(let id):
            return """
    \(preamble)
    (function() {
        var byId = mail.inbox.messages.byId(\(id));
        var here = false;
        try { here = byId.exists(); } catch (e) { here = false; }
        if (!here) return;
        var at = fmLocate(byId);
        if (at === null || !fmInScope(at)) return;
        fmBind(byId, at);
    })();
    """

        case .rfc(let rfcId):
            let escapedMailbox = escapeJSString(mailbox)
            let escapedRfc = escapeJSString(rfcId)
            return """
    \(collectBoxesJXA(account: account, varName: "fmBoxes"))
    \(preamble)
    (function() {
        var targetLC = '\(escapedMailbox)'.toLowerCase();
        var TARGET = '\(escapedRfc)';
        function searchIn(subset) {
            for (var i = 0; i < subset.length; i++) {
                for (var attempt = 0; attempt < \(findAttempts); attempt++) {
                    var rfcs = null;
                    try { rfcs = subset[i].mbox.messages.messageId(); } catch (e) { break; }
                    var k = -1;
                    for (var r = 0; r < rfcs.length; r++) {
                        if (fmBare(rfcs[r]) === TARGET) { k = r; break; }
                    }
                    if (k < 0) break;
                    var ids = null;
                    try { ids = subset[i].mbox.messages.id(); } catch (e) { break; }
                    // Two Apple Events, so the mailbox can have changed between
                    // them. Nothing below trusts that it did not.
                    if (ids.length !== rfcs.length || ids[k] == null) continue;
                    var numeric = parseInt('' + ids[k], 10);
                    if (!isFinite(numeric)) continue;
                    var cand = mail.inbox.messages.byId(numeric);
                    var got = null;
                    try { got = cand.messageId(); } catch (e) { continue; }
                    // The message answering for itself. A pairing shifted by an
                    // arrival between the two columns fails here and is retried.
                    if (fmBare(got) !== TARGET) continue;
                    var at = fmLocate(cand);
                    if (at === null || !fmInScope(at)) continue;
                    fmBind(cand, at);
                    return true;
                }
            }
            return false;
        }
        // The caller's `mailbox` is only a hint about where to look first, so
        // it matches either the identity (a path, and a bare name is a path
        // with one component) or the leaf name -- and a mailbox that could not
        // be identified at all is skipped rather than searched, since nothing
        // read out of it could be trusted.
        var named = []; var rest = [];
        for (var i = 0; i < fmBoxes.length; i++) {
            if (fmBoxes[i].mbox === null) continue;
            if (fmBoxes[i].path.toLowerCase() === targetLC || fmBoxes[i].name.toLowerCase() === targetLC) named.push(fmBoxes[i]); else rest.push(fmBoxes[i]);
        }
        if (!searchIn(named)) searchIn(rest);
    })();
    """
        }
    }

    /// JXA snippet resolving a mailbox *inside one account*, named by a
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
    /// **The same collision happens inside one account, and it used to be
    /// resolved by taking the first match.** Mail reports leaf names for a
    /// flattened tree, so an account holding `Projects/Archive` beside a
    /// top-level `Archive` offers two mailboxes called `Archive` — and Mail
    /// enumerates children before parents with the special mailboxes last, so
    /// "the first one" was systematically the nested one. Measured against the
    /// fixture: `mail_move` to `"Archive"` filed into `Projects/Archive`, and
    /// `mail_move` to `"Trash"` filed into `R4-PROBE-Deep/Trash` — a "delete
    /// this" that leaves the message undeleted in a user's project folder,
    /// reported as `{"mailbox": "Trash", "verified": true}`.
    ///
    /// Resolution is now in two steps, and neither of them guesses:
    ///
    /// 1. **An exact path wins.** A bare name is a path with one component, so
    ///    `Archive` names the mailbox at the root of the account and
    ///    `Projects/Archive` names the nested one. That is not a convention
    ///    invented here: it is how Mail's own `byName` reads the string, which
    ///    is why the resolved mailbox can then be *bound* by it. It also
    ///    answers the special-mailbox question without a special case — the
    ///    account's `Trash` wins over a user folder called `Trash` because it
    ///    is the one at the root, not because it is special.
    /// 2. **Otherwise the leaf name, and only when exactly one mailbox carries
    ///    it.** This is what lets `Sub` reach `Archive/Sub`, a mailbox no bare
    ///    name of Mail's own would resolve. When more than one carries it the
    ///    call is **refused and both paths are named**, in the same shape as
    ///    the refusal for a name no mailbox carries: filing into one of two
    ///    mailboxes is a coin toss whose result the caller cannot see, and the
    ///    caller can say which they meant with one more path component.
    ///
    /// Sets `<varName>` to the mailbox, `<varName>Account` to the account it
    /// came from and `<varName>Path` to the path that identifies it, so the
    /// caller can report where the message went and check it against what was
    /// asked for. Every list in an error message is a list of paths, because a
    /// list of leaf names is where this started: `Archive, ..., Archive`.
    ///
    /// The throw reaches the caller as prose because `runJXAData` unwraps
    /// osascript's wrapper (`scriptErrorMessage`); it used to arrive as
    /// `execution error: Error: Error: … (-2700)`.
    private static func mailboxInAccountJXA(
        mailbox: String,
        accountExpr: String,
        varName: String = "mbox"
    ) -> String {
        let escapedMailbox = escapeJSString(mailbox)
        return """
    \(boundByNameJXA)
    var \(varName)Account = null;
    var \(varName)Path = null;
    var \(varName) = (function() {
        var wantName = '\(escapedMailbox)'.toLowerCase();
        var wantAcct = \(accountExpr);
        // Name what the account does have, by path. The mailboxes are already
        // fetched by then, so it costs nothing, and "no mailbox named X" on its
        // own leaves a caller guessing at spelling, localisation and which
        // account owns the folder they meant.
        function pathList(boxes) {
            var names = [];
            for (var n = 0; n < boxes.length && n < 25; n++) names.push(boxes[n].path);
            if (boxes.length > names.length) names.push('...');
            return names.join(', ');
        }
        function pathsOf(boxes) {
            var names = [];
            for (var n = 0; n < boxes.length; n++) names.push('"' + boxes[n].path + '"');
            return names.join(' and ');
        }
        function pick(boxes, where) {
            var exact = [], leaf = [];
            for (var i = 0; i < boxes.length; i++) {
                if (boxes[i].element === null) continue;
                if (boxes[i].path.toLowerCase() === wantName) exact.push(boxes[i]);
                else if (boxes[i].name.toLowerCase() === wantName) leaf.push(boxes[i]);
            }
            if (exact.length === 1) return exact[0];
            // Mail cannot produce two mailboxes at the same path -- siblings
            // are unique and `/` is its own separator -- so this is here
            // because refusing costs nothing and resolving it would be a guess.
            if (exact.length > 1) {
                throw new Error(where + ' has ' + exact.length + ' mailboxes at the path "\(escapedMailbox)"; it is ambiguous and nothing was done');
            }
            if (leaf.length === 1) return leaf[0];
            if (leaf.length > 1) {
                throw new Error(where + ' has ' + leaf.length + ' mailboxes named "\(escapedMailbox)": ' + pathsOf(leaf)
                    + '. Name the one you mean by its full path -- nothing was done');
            }
            throw new Error(where + ' has no mailbox named "\(escapedMailbox)"; it has: ' + pathList(boxes));
        }
        if (wantAcct !== null && ('' + wantAcct).toLowerCase() !== 'on my mac') {
            var accts = boundByNameOrThrow(mail.accounts, 'the account list');
            for (var a = 0; a < accts.length; a++) {
                if (accts[a].name.toLowerCase() === ('' + wantAcct).toLowerCase()) {
                    var boxes = boundByNameOrThrow(accts[a].element.mailboxes, 'the mailbox list of account "' + accts[a].name + '"');
                    var hit = pick(boxes, 'account "' + accts[a].name + '"');
                    \(varName)Account = accts[a].name;
                    \(varName)Path = hit.path;
                    return hit.element;
                }
            }
            throw new Error('account not found: ' + wantAcct);
        }
        var localBoxes = boundByNameOrThrow(mail.mailboxes, 'the mailbox list of On My Mac');
        var localHit = pick(localBoxes, 'On My Mac');
        \(varName)Account = 'On My Mac';
        \(varName)Path = localHit.path;
        return localHit.element;
    })();
    """
    }

    /// Returns JXA that resolves the sender address, plus the assignment that
    /// puts it on the message. `from` takes precedence over `account`.
    ///
    /// **Both forms are checked against the accounts Mail actually holds, and
    /// both refuse rather than fall back.** `from` used to be passed straight
    /// through to `msg.sender`, and Mail does not reject an address no account
    /// owns -- it quietly sends from the default account instead. A send with
    /// `from: "nosuch@relaytest.local"` therefore returned `{"status":
    /// "sent"}` and went out as `From: Alice Tester <alice@relaytest.local>`,
    /// Return-Path `alice@`, filed in Alice's Sent: a caller asking to send as
    /// one identity sent as another, with nothing in the response saying so
    /// and the message already gone. The `account` form has always thrown
    /// `account not found` for the same class of mistake; this is that
    /// refusal, for the other argument.
    ///
    /// The check runs **before** `mail.OutgoingMessage` is created, so a
    /// rejected sender leaves nothing behind at all -- no compose message, and
    /// therefore no draft for Mail to autosave.
    ///
    /// `emailAddresses()` is the right set to check against because it holds
    /// every address an account can send as, aliases included. A display name
    /// is allowed (`"A Tester" <alice@…>`): the address is what is matched,
    /// and the whole string is what is assigned, which is the form Mail wants.
    ///
    /// `senderAddr` is defined on every path, `null` when the caller named no
    /// sender, because `preSendGuardJXA` reads it back.
    ///
    /// Not private: whether an unowned sender is refused is a property of the
    /// generated script, and only running it can pin it.
    static func senderJXA(from: String?, account: String?) -> (lines: String, prop: String) {
        if let from = from {
            let escapedFrom = escapeJSString(from)
            let wanted = escapeJSString(parseAddress(from).address.lowercased())
            let lines = """
            var senderAddr = (function() {
                var want = '\(wanted)';
                var known = [];
                var accts = mail.accounts();
                for (var i = 0; i < accts.length; i++) {
                    var addrs = [];
                    try { addrs = accts[i].emailAddresses(); } catch (e) { addrs = []; }
                    for (var a = 0; a < addrs.length; a++) {
                        var one = ('' + addrs[a]).trim();
                        if (one.length === 0) continue;
                        known.push(one);
                        if (one.toLowerCase() === want) return '\(escapedFrom)';
                    }
                }
                throw new Error('no account in Mail sends as "' + want + '", and Mail does not refuse an unknown sender -- it sends from the default account instead, so this would have gone out as someone else. Nothing was composed. Mail can send as: '
                    + (known.length ? known.join(', ') : '(no account has an address)'));
            })();
            """
            return (lines, "msg.sender = senderAddr;")
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
        // No sender named: Mail uses its default account, which is the right
        // answer for a caller with one account. `senderAddr` is still declared
        // so the guard has something to read, and the account the message
        // really went out from is reported back either way.
        return ("var senderAddr = null;", "")
    }

    // MARK: - Tool Handlers

    private static func listAccounts(_ args: JSONObject?) -> MCPCallResult {
        // Empty input schema: there is no account, no mailbox and no limit to
        // pass, so "narrow the scope" would be advice the caller cannot follow.
        let (names, error) = accountNames(scopable: false)
        if let error { return errorResult(error) }
        return jsonResult(names)
    }

    /// Lists every mailbox a scan can reach, which now includes Mail's
    /// app-level ones (#54).
    ///
    /// It used to enumerate `mail.accounts()` and nothing else, while
    /// `mail.mailboxes()` on the same machine held `Recovered Messages (Alice)`,
    /// `SendLater`, `Outbox` and `Deleted Messages`. The scan covers those and
    /// labels their rows `On My Mac:<mailbox>`, so a caller could be handed a
    /// row from a mailbox the only enumeration tool said did not exist -- and
    /// could not ask for it by name, because nothing told them the name and no
    /// `account` value reached it.
    ///
    /// The entry is emitted whether or not there are any: "this account holds no
    /// mailboxes" is an answer, and omitting it puts a caller back to having to
    /// know the name before they can ask.
    ///
    /// **What it lists are paths.** Mail flattens the tree and reports leaf
    /// names, so this used to answer with `Archive, ..., Archive` and
    /// `Drafts, ..., Drafts` — two entries a caller cannot tell apart, for two
    /// different mailboxes — beside a `Sub` and an `L4` that no other tool
    /// would resolve, because a bare leaf name reaches a nested mailbox only
    /// when it is the only one of its kind. Every name here is now the string
    /// that identifies the mailbox and that every other mail tool accepts as
    /// `mailbox`, `source_mailbox` or `target_mailbox`.
    private static func listMailboxes(_ args: JSONObject?) -> MCPCallResult {
        let account = args?["account"]?.stringValue
        // One bulk build per collection rather than a `mailboxes[i].name()`
        // walk. The walk was one Apple Event per mailbox -- 436ms against 15ms
        // for Bob's 30 -- and it had no try/catch, so a mailbox vanishing
        // mid-walk cost the caller the whole listing including the accounts
        // already enumerated.
        let pathsOf = """
        function pathsOf(collection) {
            var bound = boundByName(collection);
            if (bound === null) throw new Error('the mailbox list kept changing while it was being read; try again in a moment');
            var out = [];
            for (var i = 0; i < bound.length; i++) out.push(bound[i].path);
            return out;
        }
        """
        let script: String
        if let account, isLocalAccount(account) {
            script = """
            var mail = Application('Mail');
            \(boundByNameJXA)
            \(pathsOf)
            JSON.stringify(pathsOf(mail.mailboxes));
            """
        } else if let account {
            let escaped = escapeJSString(account)
            script = """
            var mail = Application('Mail');
            \(boundByNameJXA)
            \(pathsOf)
            (function() {
                var accts = boundByNameOrThrow(mail.accounts, 'the account list');
                for (var i = 0; i < accts.length; i++) {
                    if (accts[i].name.toLowerCase() === '\(escaped)'.toLowerCase()) {
                        return JSON.stringify(pathsOf(accts[i].element.mailboxes));
                    }
                }
                throw new Error('account not found: \(escaped)');
            })();
            """
        } else {
            script = """
            var mail = Application('Mail');
            \(boundByNameJXA)
            \(pathsOf)
            var accts = boundByNameOrThrow(mail.accounts, 'the account list');
            var results = [];
            for (var i = 0; i < accts.length; i++) {
                results.push({account: accts[i].name, mailboxes: pathsOf(accts[i].element.mailboxes)});
            }
            results.push({account: '\(escapeJSString(localAccountName))', mailboxes: pathsOf(mail.mailboxes)});
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
            "skipped_mailboxes": outcome.skipped,
            "scan_complete": outcome.scanComplete
        ]
        if !outcome.failed.isEmpty { payload["failed_accounts"] = outcome.failed }
        if !outcome.unstable.isEmpty { payload["unstable_mailboxes"] = outcome.unstable }
        if !outcome.excluded.isEmpty { payload["excluded_mailboxes"] = outcome.excluded }
        if let note = outcome.incompleteNote { payload["note"] = note }
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
        var payload: [String: Any]
        switch scriptPayload(output) {
        case .failure(let message): return errorResult(message)
        case .text(let text): return textResult(text)
        case .object(let object): payload = object
        }
        return reconciled(
            payload,
            listedByMail: payload["attachments"] as? [[String: Any]] ?? [],
            account: payload["account"] as? String ?? args?["account"]?.stringValue,
            mailbox: payload["mailbox"] as? String ?? mailbox,
            messageId: messageId
        )
    }

    /// Checks a message read out of Mail against the message itself, and reports
    /// what could not be checked instead of guessing.
    ///
    /// `content()` and `mailAttachments()` answer for what Mail has downloaded,
    /// and answer without complaint when that is nothing. With the server
    /// unreachable, a 400 KB message carrying one attachment came back as
    /// `body: ""`, `has_attachments: false`, `attachments: []` and no error --
    /// beside a `message_size` of 400595 in the same response. #31 put that
    /// check on `mail_get_source` and named this tool as a consumer of the same
    /// bytes; this is that check reaching it.
    ///
    /// Two rules, and the second is the one that matters:
    ///
    /// * **A negative from an incomplete fetch is not reported at all.** An
    ///   empty body and an empty attachment list are omitted rather than
    ///   returned, because "" and `false` are answers a caller acts on. What
    ///   Mail *does* have -- a partial body, an attachment it has already
    ///   listed -- is positive evidence and is kept, with `fidelity` saying the
    ///   message is not all here.
    /// * **The attachment list is reconciled with the message source**, which is
    ///   where `mail_save_attachment` reads it from. Mail's own list is not
    ///   authoritative even after the message arrives: a message first read
    ///   while it was still downloading kept `has_attachments: false`
    ///   permanently, while `mail_save_attachment` extracted its attachment
    ///   byte-exactly. Anything the source declares that Mail does not list is
    ///   added and flagged, so the two tools stop disagreeing about the same
    ///   message.
    ///
    /// A source fetch that fails leaves the message as Mail reported it, with
    /// `source_check` saying the check did not happen -- an unreadable source is
    /// not a reason to cost the caller a message that did read.
    private static func reconciled(
        _ message: [String: Any],
        listedByMail: [[String: Any]],
        account: String?,
        mailbox: String,
        messageId: String
    ) -> MCPCallResult {
        var payload = message
        let (source, expectedSize, error) = fetchSource(
            account: account,
            mailbox: mailbox,
            messageId: messageId,
            timeout: attachmentTypeFetchTimeout
        )
        guard error == nil else {
            payload["attachments"] = listedByMail.map(withFilenameGuess)
            payload["has_attachments"] = !listedByMail.isEmpty
            payload["source_check"] = "the message source could not be read (\(error!)), so the body and attachments here are Mail's own answer and nothing confirms the message had finished downloading"
            return jsonResult(payload)
        }

        return jsonResult(messageChecked(
            payload,
            listedByMail: listedByMail,
            source: source,
            fidelity: sourceFidelity(source, expectedSize: expectedSize)
        ))
    }

    /// Applies both rules to a message Mail reported and the source it was
    /// checked against. Split out from the fetch so the rules can be tested
    /// without a mailbox.
    static func messageChecked(
        _ message: [String: Any],
        listedByMail: [[String: Any]],
        source: Data,
        fidelity: SourceFidelity
    ) -> [String: Any] {
        var payload = message
        payload["fidelity"] = fidelity.dict

        // Parsed once and handed to both readers below. It used to be parsed
        // twice, which on a 70 MB source is not free, and the two could not have
        // disagreed about the message's structure without disagreeing silently.
        //
        // `structure` reports what the reader could and could not read, on the
        // same principle as `fidelity` beside it: a message whose parts nest
        // deeper than `MIME.maxDepth` yields a *shorter* attachment list, and a
        // short list is indistinguishable from a message with fewer
        // attachments. It appears only on the complete path because that is the
        // only path on which anything was parsed -- an incomplete fetch reports
        // Mail's own list, and `omitted` already covers it.
        var attachments: [[String: Any]]
        var missed: [[String: Any]] = []
        if fidelity.complete {
            let parsed = MIME.parseReporting(source)
            payload["structure"] = parsed.report.dict
            attachments = declaredAttachmentTypes(listedByMail, parsed: parsed.part)
            missed = attachmentsMailDidNotList(listedByMail, parsed: parsed.part)
        } else {
            attachments = listedByMail.map(withFilenameGuess)
        }
        attachments += missed
        if !missed.isEmpty {
            payload["attachments_note"] = "\(missed.count) attachment(s) here are declared by the message but are not in Mail's own list for it, which is what mail_save_attachment reads and Mail can leave empty for good once a message has been read while it was still downloading. They carry listed_by_mail: false, and size is the decoded size of the part."
        }

        var omitted: [String] = []
        if attachments.isEmpty && !fidelity.complete {
            // "No attachments" measured against a message Mail does not have is
            // not a finding.
            payload.removeValue(forKey: "attachments")
            omitted += ["attachments", "has_attachments"]
        } else {
            payload["attachments"] = attachments
            payload["has_attachments"] = !attachments.isEmpty
        }

        if (payload["body"] as? String)?.isEmpty != false && !fidelity.complete {
            payload.removeValue(forKey: "body")
            omitted.append("body")
        }

        if !omitted.isEmpty {
            payload["omitted"] = omitted
            payload["omitted_reason"] = "Mail has not finished downloading this message (see fidelity), and these fields would have reported empty rather than measured. Ask again once fidelity.complete is true."
        }
        return payload
    }

    /// The attachments a message declares that Mail did not list, matched by
    /// name so that a message with two parts of the same name still reports both.
    ///
    /// Inline parts are left out: Mail deliberately does not list a body image
    /// as an attachment, and turning `has_attachments` true for every HTML
    /// message with a logo in it would be a new wrong answer in place of the old
    /// one.
    static func attachmentsMailDidNotList(
        _ listedByMail: [[String: Any]],
        source: Data
    ) -> [[String: Any]] {
        attachmentsMailDidNotList(listedByMail, parsed: MIME.parse(source))
    }

    static func attachmentsMailDidNotList(
        _ listedByMail: [[String: Any]],
        parsed: MIME.Part
    ) -> [[String: Any]] {
        func key(_ name: Any?) -> String { (name as? String ?? "").lowercased() }
        var listed: [String: Int] = [:]
        for attachment in listedByMail { listed[key(attachment["name"]), default: 0] += 1 }

        var out: [[String: Any]] = []
        for part in MIME.attachments(of: parsed) where !part.inline {
            if let count = listed[part.name.lowercased()], count > 0 {
                listed[part.name.lowercased()] = count - 1
                continue
            }
            out.append([
                "name": part.name,
                // Mail quotes `fileSize` for the parts it lists, which is the
                // encoded size; this is what the part decodes to, and the note
                // on the result says so rather than passing one off as the other.
                "size": part.data.count,
                "mime_type": part.mimeType,
                "mime_type_source": "declared",
                "listed_by_mail": false,
                "downloaded": true
            ])
        }
        return out
    }

    /// Wall-clock allowance for the source fetch `mail_get_email` checks itself
    /// against. Shorter than a plain `mail_get_source`, because it is a check on
    /// a read that already worked: exceeding it costs the caller a less precise
    /// answer, not the message.
    ///
    /// The fetch used to happen only when Mail had listed at least one
    /// attachment, which is exactly the case a half-downloaded message does not
    /// present: it lists none, and the enrichment that would have caught it was
    /// skipped for want of one. It now happens on every read.
    ///
    /// What it buys, beyond completeness: Mail's `MIME type` property on
    /// `mail attachment` raises "AppleEvent handler failed" on every message
    /// that has one, so the type used to be inferred from the filename -- a
    /// guess presented as a fact, which disagreed with `mail_save_attachment`
    /// for the same attachment (`text/csv` against `image/png` for a part
    /// declared as `image/png; name="data.csv"`). `mime_type_source` says which
    /// of the two a caller is looking at.
    private static let attachmentTypeFetchTimeout: TimeInterval = 45

    private static func withFilenameGuess(_ attachment: [String: Any]) -> [String: Any] {
        var out = attachment
        out["mime_type"] = MIME.mimeType(forFilename: attachment["name"] as? String ?? "")
        out["mime_type_source"] = "filename"
        return out
    }

    /// Matches Mail's attachment list against the parts in the raw source and
    /// takes each type from the message.
    ///
    /// Matching is by name, consuming each declared part once so that two
    /// attachments sharing a filename still get their own types in order. An
    /// attachment with no counterpart in the source keeps the filename guess and
    /// says so, rather than borrowing the type of an unrelated part.
    static func declaredAttachmentTypes(
        _ attachments: [[String: Any]],
        source: Data
    ) -> [[String: Any]] {
        declaredAttachmentTypes(attachments, parsed: MIME.parse(source))
    }

    static func declaredAttachmentTypes(
        _ attachments: [[String: Any]],
        parsed: MIME.Part
    ) -> [[String: Any]] {
        var declared: [String: [String]] = [:]
        for part in MIME.attachments(of: parsed) {
            declared[part.name.lowercased(), default: []].append(part.mimeType)
        }
        return attachments.map { attachment in
            let key = (attachment["name"] as? String ?? "").lowercased()
            guard var queue = declared[key], !queue.isEmpty else {
                return withFilenameGuess(attachment)
            }
            var out = attachment
            out["mime_type"] = queue.removeFirst()
            out["mime_type_source"] = "declared"
            declared[key] = queue
            return out
        }
    }

    /// The JXA for one body-scan batch: the bodies of a known set of ids in one
    /// mailbox, minus the `var mail = Application('Mail');` line.
    ///
    /// Not private, and split from the caller, because the binding is the whole
    /// point and only running it against a mailbox that changes can prove it.
    ///
    /// Each body is fetched off a specifier bound by the id it is attributed to.
    /// This used to read the id column and then take `mb.messages[i].content()`
    /// at the matching index -- its own comment claimed to locate by id and did
    /// the opposite -- so a message arriving mid-call put one message's body
    /// under another message's id, and the row returned as a body-search hit was
    /// not the message whose body matched (#50). Nothing is read by index here,
    /// and the ids are already known, so no column is fetched at all.
    ///
    /// `byId` resolves across every mailbox, so a message that has left this one
    /// since the metadata scan would still answer. Its mailbox is checked,
    /// because the row carries the mailbox it was found in and that claim has to
    /// stay true.
    static func bodyFetchScriptJXA(account: String, mailbox: String, ids: [String]) -> String {
        let escapedAccount = escapeJSString(account)
        let escapedMailbox = escapeJSString(mailbox)
        let wantedLiteral = ids.map { "'\(escapeJSString($0))'" }.joined(separator: ",")
        return """
\(boundByNameJXA)
var WANT = [\(wantedLiteral)];
var mb = (function() {
    var boxes = [];
    var accts = boundByNameOrThrow(mail.accounts, 'the account list');
    for (var i = 0; i < accts.length; i++) {
        if (accts[i].name === '\(escapedAccount)') { boxes = boundByNameOrReport(accts[i].element.mailboxes, accts[i].name); break; }
    }
    if (boxes.length === 0 && '\(escapedAccount)' === 'On My Mac') boxes = boundByNameOrReport(mail.mailboxes, 'On My Mac');
    // The mailbox comes from a row this pass is following up, and a row is
    // stamped with the mailbox's **path**. Matching the leaf name here would
    // reach whichever `Archive` came first, which is a different mailbox from
    // the one the row came out of.
    for (var j = 0; j < boxes.length; j++) {
        if (boxes[j].element !== null && boxes[j].path === '\(escapedMailbox)') return boxes[j].element;
    }
    return null;
})();
var out = [];
if (mb) {
    for (var i = 0; i < WANT.length; i++) {
        var numeric = parseInt(WANT[i], 10);
        if (!isFinite(numeric)) continue;
        try {
            var m = mb.messages.byId(numeric);
            if (mbPathOf(m.mailbox) !== '\(escapedMailbox)') continue;
            out.push({id: WANT[i], body: '' + m.content()});
        } catch (e) {}
    }
}
JSON.stringify(out);
"""
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

            let script = """
            var mail = Application('Mail');
            \(bodyFetchScriptJXA(account: key.account, mailbox: key.mailbox, ids: wanted))
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
            "skipped_mailboxes": outcome.skipped,
            "scan_complete": outcome.scanComplete
        ]
        if let bodyInfo { payload["body_search"] = bodyInfo }
        if !outcome.failed.isEmpty { payload["failed_accounts"] = outcome.failed }
        if !outcome.unstable.isEmpty { payload["unstable_mailboxes"] = outcome.unstable }
        if !outcome.excluded.isEmpty { payload["excluded_mailboxes"] = outcome.excluded }
        if let note = outcome.incompleteNote { payload["note"] = note }
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

    /// JXA that refuses to hand the message on unless Mail holds exactly the
    /// message the caller asked for: the same recipients, the same subject and
    /// the same sender.
    ///
    /// This is the last line of defence against mail leaving the machine as
    /// something other than what was requested, and both halves of that have
    /// happened. With several compose windows open, the reference returned by
    /// `OutgoingMessage()` bound to a pre-existing window instead of the new
    /// message and `send()` delivered that window's recipient;
    /// `resolveOutgoingJXA` should make that impossible, but the cost of being
    /// wrong is a message that cannot be recalled. And a `from` naming an
    /// address no account owns used to be accepted in silence, Mail
    /// substituting its default account -- so the sender is read back here
    /// too, not only validated up front. What Mail holds is the evidence;
    /// what was asked for is only the request.
    ///
    /// **The abort names the field that differed.** It used to render the two
    /// recipient lists whatever the mismatch was, so a subject carrying a CR
    /// (Mail normalises it to a space, correctly tripping the guard) aborted
    /// with two *identical* recipient lists printed side by side -- reading
    /// like a recipient-tampering alarm, which is the scariest false positive
    /// this guard can raise.
    ///
    /// **And it does not claim more than it knows.** The tail sentence comes
    /// from `composeLeftBehind` when compose defines it, because Mail
    /// autosaves the message being composed and `close({saving: 'no'})` does
    /// not remove a copy already written: "Nothing was sent or saved" was
    /// false every time this fired. Standing alone -- which is how the tests
    /// run it -- it says only that nothing was sent, which is always true at
    /// this point.
    ///
    /// Not private: this is the guard, and a guard that has never been run
    /// against a message it should refuse is not known to work.
    static func preSendGuardJXA(
        to: [String],
        cc: [String],
        bcc: [String],
        subject: String,
        from: String?,
        account: String?
    ) -> String {
        let expected = (to + cc + bcc)
            .map { parseAddress($0).address.lowercased() }
            .map { "'\(escapeJSString($0))'" }
            .joined(separator: ", ")
        // What the sender is expected to be. A `from` is known here in full. An
        // `account` resolves to an address only at run time, in `senderAddr`,
        // which `senderJXA` has already defined by the time this runs. Naming
        // neither leaves nothing to check: Mail's default account is a correct
        // answer to a request that expressed no preference, and the address it
        // chose is reported in the result instead.
        let expectedSender: String
        if let from {
            expectedSender = "'\(escapeJSString(parseAddress(from).address.lowercased()))'"
        } else if account != nil {
            expectedSender = "(typeof senderAddr === 'undefined' || senderAddr === null) ? null : mailAddressOf(senderAddr)"
        } else {
            expectedSender = "null"
        }
        return """
        (function() {
            // Mail hands back a sender as `Display Name <addr>` or as a bare
            // address depending on how the account is configured, so the
            // address is what is compared.
            function mailAddressOf(v) {
                var s = ('' + (v == null ? '' : v)).trim();
                var lt = s.lastIndexOf('<'), gt = s.lastIndexOf('>');
                if (lt >= 0 && gt > lt) s = s.slice(lt + 1, gt).trim();
                return s.toLowerCase();
            }
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
            var wantSubject = '\(escapeJSString(subject))';
            var gotSubject = '' + msg.subject();
            var wantSender = \(expectedSender);
            var gotSender = null;
            try { gotSender = mailAddressOf(msg.sender()); } catch (e) { gotSender = null; }

            var problems = [];
            if (missing.length || extra.length) {
                problems.push('Mail has it addressed to [' + actual.join(', ')
                    + '] rather than [' + expected.join(', ') + ']');
            }
            if (gotSubject !== wantSubject) {
                problems.push('Mail has the subject as "' + gotSubject + '" rather than "' + wantSubject + '"');
            }
            if (wantSender !== null && gotSender !== wantSender) {
                problems.push('Mail would send it from ' + (gotSender ? gotSender : '(no sender)')
                    + ' rather than ' + wantSender);
            }
            if (problems.length) {
                // Close first, then say what is there: closing stops Mail
                // writing any further copy, so what Drafts holds afterwards is
                // final rather than a value that can still change.
                try { msg.close({saving: 'no'}); } catch (e) {}
                var tail = (typeof composeLeftBehind === 'function')
                    ? composeLeftBehind()
                    : 'Nothing was sent.';
                throw new Error('aborted before sending: ' + problems.join('; ') + '. ' + tail);
            }
        })();
        """
    }

    /// JXA that owns the draft Mail writes behind a compose message's back.
    ///
    /// Mail autosaves whatever it is composing. A message typed by hand has
    /// that copy removed when its window closes; `visible: false` plus a
    /// scripted `send()` means the close never happens, so **every** send left
    /// a permanent full copy -- body, recipients, subject, and an
    /// `X-Apple-Auto-Saved: 1` header -- in the sending account's Drafts.
    /// Three copies on disk per send instead of two, Alice's Drafts going
    /// 13 -> 14 -> 15 across two sends, in a folder `mailbox: "all"` excludes,
    /// so no tool here would have shown a caller it happened. The abort path
    /// was worse: it already called `close({saving: 'no'})` and told the
    /// caller "Nothing was sent or saved" while the draft -- carrying the very
    /// recipient the guard had just refused -- sat on the server.
    ///
    /// Three measurements against Mail 16.0 on the fixture shape this, and the
    /// design follows from them rather than from guessing:
    ///
    /// * `send()` and `save()` each clear the autosaved copy that exists at
    ///   that moment, and Mail writes a **new** one for the message that is
    ///   still open a few seconds later (the leaked draft's own `Date` header
    ///   was 7s *after* the sent copy's). Closing the message stops that: a
    ///   send followed immediately by `close({saving: 'no'})` left Drafts
    ///   unchanged at 20 while delivering the message and filing it in Sent.
    /// * `close({saving: 'no'})` prevents any further autosave but does
    ///   **not** delete one already written. A compose message left open for
    ///   14s autosaved at ~0.3s, and closing it afterwards left the draft
    ///   exactly where it was. That is why the abort path leaked despite
    ///   already closing, and it is why closing alone is not the whole fix.
    /// * A draft saved on purpose carries no `X-Apple-Auto-Saved` header and
    ///   an autosaved one always does, so the two can be told apart. Verified
    ///   across 22 drafts on the fixture: every deliberate `mail.save` draft
    ///   lacked it, every leaked one had it.
    ///
    /// So compose closes the message it opened, and then **checks**. The check
    /// is not decoration: it is what turns "closing prevents the leak" from
    /// something believed into something established on each call, and it is
    /// the only thing that can clean up the abort path, where the copy already
    /// exists by the time anything goes wrong.
    ///
    /// A draft is removed only when all three of these hold, because the
    /// alternative to being sure is deleting a draft the user wrote:
    ///
    /// 1. its id was **not** in that account's Drafts before the compose
    ///    message was created (the snapshot below, taken first for that
    ///    reason),
    /// 2. its subject is this message's subject, and
    /// 3. it carries `X-Apple-Auto-Saved`.
    ///
    /// `mail.delete` moves the draft to Trash rather than erasing it, and the
    /// result says so -- reporting a removal as more final than it is would be
    /// the same kind of claim this exists to stop making.
    ///
    /// Not private: what the sweep will and will not delete is the whole of
    /// its correctness, and it is generated JavaScript, so it is pinned by
    /// running it.
    static func composeDraftHygieneJXA(subject: String) -> String {
        """
        var COMPOSE_SUBJECT = '\(escapeJSString(subject))';
        function mailAddressOf(v) {
            var s = ('' + (v == null ? '' : v)).trim();
            var lt = s.lastIndexOf('<'), gt = s.lastIndexOf('>');
            if (lt >= 0 && gt > lt) s = s.slice(lt + 1, gt).trim();
            return s.toLowerCase();
        }
        function composeAccounts() {
            var out = [];
            try {
                var accts = mail.accounts();
                for (var i = 0; i < accts.length; i++) out.push(accts[i]);
            } catch (e) {}
            return out;
        }
        // The account's own Drafts. A bare name is a path with one component,
        // so `byName('Drafts')` reaches the mailbox at the root rather than a
        // project folder that happens to be called Drafts -- one Apple Event,
        // and Mail's own reading of the string. The full path build is the
        // fallback for an account that does not answer to it, and costs
        // nothing until then.
        function composeDraftsBox(acct) {
            try {
                var direct = acct.mailboxes.byName('Drafts');
                if (direct.exists() === true) return direct;
            } catch (e) {}
            var bound = null;
            try { bound = boundByName(acct.mailboxes); } catch (e) { bound = null; }
            if (bound === null) return null;
            for (var i = 0; i < bound.length; i++) {
                if (bound[i].element !== null && ('' + bound[i].path).toLowerCase() === 'drafts') return bound[i].element;
            }
            return null;
        }
        // Taken before the compose message exists, which is the only moment at
        // which "this draft is not ours" can be established. One bulk id
        // column per account.
        var COMPOSE_DRAFTS_BEFORE = (function() {
            var snap = [];
            var accts = composeAccounts();
            for (var i = 0; i < accts.length; i++) {
                var name = null;
                try { name = '' + accts[i].name(); } catch (e) { continue; }
                var box = composeDraftsBox(accts[i]);
                if (box === null) { snap.push({account: name, box: null, ids: null}); continue; }
                var ids = null;
                try { ids = box.messages.id(); } catch (e) { ids = null; }
                var seen = null;
                if (ids !== null) {
                    seen = Object.create(null);
                    for (var k = 0; k < ids.length; k++) seen['' + ids[k]] = true;
                }
                snap.push({account: name, box: box, ids: seen});
            }
            return snap;
        })();
        // Which account Mail is actually sending from, read off the message
        // rather than off the request. With no `from` and no `account` this is
        // the only way to know, and it is what tells the sweep and the saved
        // draft lookup where to look.
        function composeResolveSenderAccount() {
            var addr = null;
            try { addr = mailAddressOf(msg.sender()); } catch (e) { addr = null; }
            if (addr === null || addr.length === 0) return {address: null, account: null};
            var accts = composeAccounts();
            for (var i = 0; i < accts.length; i++) {
                var addrs = [];
                try { addrs = accts[i].emailAddresses(); } catch (e) { continue; }
                for (var a = 0; a < addrs.length; a++) {
                    if (('' + addrs[a]).trim().toLowerCase() === addr) {
                        try { return {address: addr, account: '' + accts[i].name()}; } catch (e) { return {address: addr, account: null}; }
                    }
                }
            }
            return {address: addr, account: null};
        }
        // Everything the cleanup needs off the live message, taken while it is
        // still open. Two reasons it cannot be left until afterwards. The
        // abort path closes the message before it reports, and a closed
        // message answers nothing. And the subject an autosaved copy carries
        // is the one **Mail** holds, not the one that was asked for: a subject
        // with a CR in it reaches Drafts with a space, so matching on the
        // request alone found no copy and reported a leak as a clean abort --
        // measured, 19 -> 20 drafts under "Nothing was sent or saved".
        var COMPOSE_SENDER = {address: null, account: null};
        var COMPOSE_SUBJECT_SEEN = null;
        function composeObserve() {
            COMPOSE_SENDER = composeResolveSenderAccount();
            try { COMPOSE_SUBJECT_SEEN = '' + msg.subject(); } catch (e) { COMPOSE_SUBJECT_SEEN = null; }
            return COMPOSE_SENDER;
        }
        function composeSubjectMatches(v) {
            var got = '' + v;
            return got === COMPOSE_SUBJECT
                || (COMPOSE_SUBJECT_SEEN !== null && got === COMPOSE_SUBJECT_SEEN);
        }
        // The snapshot entry for one account, or null with `out.detail` saying
        // why there is none.
        function composeDraftEntry(acctName, out) {
            if (acctName === null) {
                out.detail = 'the account Mail composed from could not be identified, so its Drafts was not checked';
                return null;
            }
            for (var i = 0; i < COMPOSE_DRAFTS_BEFORE.length; i++) {
                if (('' + COMPOSE_DRAFTS_BEFORE[i].account).toLowerCase() === ('' + acctName).toLowerCase()) {
                    var entry = COMPOSE_DRAFTS_BEFORE[i];
                    out.account = entry.account;
                    if (entry.box === null || entry.ids === null) {
                        out.detail = 'the Drafts mailbox of account "' + entry.account + '" could not be read';
                        return null;
                    }
                    return entry;
                }
            }
            out.detail = 'account "' + acctName + '" was not in the account list when the message was created';
            return null;
        }
        // The drafts in `entry` that were not there before this message was
        // composed and that carry its subject. Returns null, with
        // `out.detail`, if the mailbox would not hold still.
        //
        // Two columns, two Apple Events, walked by index -- so they are paired
        // only if they came back the same length, the same rule the scan lives
        // by. A mismatch would pair one message's id with another's subject,
        // and this one deletes. It is not hypothetical: this runs moments
        // after `send()`, which is itself removing the autosaved copy, and the
        // first send measured against the fixture caught Drafts mid-change. So
        // it is retried rather than abandoned -- the churn is Mail finishing
        // what the send started, and it settles.
        function composeNewMatchingDrafts(entry, out) {
            var ids = null, subs = null;
            for (var attempt = 0; attempt < \(findAttempts); attempt++) {
                ids = null; subs = null;
                try {
                    ids = entry.box.messages.id();
                    subs = entry.box.messages.subject();
                } catch (e) {
                    out.detail = 'the Drafts mailbox of account "' + entry.account + '" could not be read back: ' + e;
                    return null;
                }
                if (ids.length === subs.length) break;
                ids = null;
                delay(0.4);
            }
            if (ids === null) {
                out.detail = 'the Drafts mailbox of account "' + entry.account + '" kept changing while it was being read';
                return null;
            }
            var hits = [];
            for (var k = 0; k < ids.length; k++) {
                if (entry.ids['' + ids[k]]) continue;
                if (!composeSubjectMatches(subs[k])) continue;
                var numeric = parseInt('' + ids[k], 10);
                if (!isFinite(numeric)) continue;
                hits.push({id: '' + ids[k], numeric: numeric});
            }
            return hits;
        }
        // Finds the copy Mail autosaved, and removes it **only when Mail has
        // let go of the message it was composing**.
        //
        // `mayRemove` is that condition, and it is narrow on purpose. Measured
        // against Mail 16.0: delete the autosaved draft of a compose message
        // Mail still holds and Mail writes it straight back -- 3s later in one
        // run, 12s in another, 15s in a third -- so the delete does not remove
        // a copy, it adds one in Trash beside the copy that returns. That was
        // watched happen end to end: an abort that deleted what it found
        // reported "that copy has been moved to Trash" and Drafts went from 21
        // to 22, one in Trash and a fresh one in Drafts, where doing nothing
        // would have left exactly one.
        //
        // Closing first does not help -- closing stops Mail *updating* the
        // draft, not re-creating one that has gone -- and neither does
        // `mail.delete` on the outgoing message, nor setting it visible and
        // closing it. Every sequence tried ends with one copy in Drafts.
        // `send()` is the one thing that ends Mail's interest in the message,
        // which is why a send followed immediately by a close leaves Drafts
        // untouched, and why removing a leftover is sound only after one.
        //
        // So an abort deletes nothing, and there is a second reason not to:
        // this guard fires when what Mail is holding is not what was asked
        // for, which is the worst possible moment to start deleting things on
        // the strength of having identified them. What it does instead is say
        // what is there, which is all "Nothing was sent or saved" was ever
        // standing in for.
        // Of those, the ones Mail wrote by itself. Without the header a draft
        // is one something else saved on purpose -- including the one
        // `mail_create_draft` just asked for, which is new since the snapshot
        // and carries the same subject -- and it is none of this code's
        // business. Verified across the fixture's 22 drafts: every deliberate
        // save lacks the header, every autosave has it.
        function composeAutosavedOnly(entry, hits) {
            var out = [];
            for (var k = 0; k < hits.length; k++) {
                var bound = entry.box.messages.byId(hits[k].numeric);
                var headers = null;
                try { headers = '' + bound.allHeaders(); } catch (e) { headers = null; }
                if (headers === null || !/^X-Apple-Auto-Saved:/im.test(headers)) continue;
                out.push({id: hits[k].id, element: bound});
            }
            return out;
        }
        function composeSweepDrafts(acctName, mayRemove) {
            var out = {checked: false, removed: 0};
            var entry = composeDraftEntry(acctName, out);
            if (entry === null) return out;
            var hits = composeNewMatchingDrafts(entry, out);
            if (hits === null) return out;
            var autosaved = composeAutosavedOnly(entry, hits);
            out.checked = true;
            out.found = autosaved.length;
            var leftAlone = [];
            var failures = [];
            for (var k = 0; k < autosaved.length; k++) {
                if (!mayRemove) { leftAlone.push(autosaved[k].id); continue; }
                try { mail.delete(autosaved[k].element); out.removed++; }
                catch (e) { failures.push('' + autosaved[k].id + ': ' + e); }
            }
            if (failures.length) out.not_removed = failures;
            if (leftAlone.length) out.left_in_drafts = leftAlone;
            if (out.found > 0) {
                if (out.removed === out.found) {
                    out.note = 'Mail autosaved a copy of this message while composing it; that copy has been moved to Trash';
                } else if (!mayRemove) {
                    out.note = 'Mail autosaved a copy of this message and it is still in Drafts. It is left alone deliberately: Mail re-creates the autosaved copy of a message it is still holding, so deleting it leaves two copies rather than none';
                } else {
                    out.note = 'Mail autosaved a copy of this message while composing it and it could not be removed; it is still in Drafts';
                }
            }
            return out;
        }
        // The sentence the pre-send guard puts after what went wrong. It says
        // what was left behind rather than asserting that nothing was.
        var COMPOSE_SWEEP = null;
        function composeLeftBehind() {
            // Nothing is deleted here -- see composeSweepDrafts.
            COMPOSE_SWEEP = composeSweepDrafts(COMPOSE_SENDER.account, false);
            if (!COMPOSE_SWEEP.checked) {
                return 'Nothing was sent. Mail autosaves the message it is composing, and whether it left a copy in Drafts could not be checked: '
                    + COMPOSE_SWEEP.detail + '.';
            }
            // Never "nothing was saved". An abort is the one path that hands
            // the message to Mail neither by sending it nor by saving it, so
            // Mail keeps the compose message -- `close` does not remove it
            // from `outgoingMessages` -- and autosaves it whenever its timer
            // next comes round. That was measured at under a second on a Mail
            // that had been running a while and at **30 seconds** on one just
            // relaunched, which is long enough for this check to look, find
            // nothing, and say so truthfully about a copy that then appears.
            // What it can say is what it saw.
            if (COMPOSE_SWEEP.found === 0) {
                return 'Nothing was sent, and no draft was saved for it. Mail keeps a compose message it has been told to close, though, and autosaves it into Drafts on its own schedule -- within a second on a busy Mail, 30s on one just relaunched -- so a copy of this message may still appear in the Drafts of account "'
                    + COMPOSE_SWEEP.account + '". None was there when this was checked.';
            }
            return 'Nothing was sent, but Mail had already autosaved a copy of this message in the Drafts of account "'
                + COMPOSE_SWEEP.account + '" and it is still there (message id '
                + (COMPOSE_SWEEP.left_in_drafts || []).join(', ')
                + '). It is not deleted, because Mail re-creates the autosaved copy of a message it is still holding: deleting it would leave two copies rather than none.';
        }
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
        // `byId`, not a walk ending in `open[i]`. A positional specifier
        // re-resolves by position on every access, and this reference is held
        // across setting the recipients, the body and the attachments, then the
        // send -- so another compose message appearing in the collection
        // meanwhile would move it onto a different message (#50).
        var byId = mail.outgoingMessages.byId(newMessageId);
        var here = false;
        try { here = byId.exists(); } catch (e) { here = false; }
        return here ? byId : null;
    })();
    if (!msg) { throw new Error('could not identify the newly created message in Mail; nothing was sent or saved'); }
    """

    /// Shared email composition: validates params, builds JXA, runs it.
    ///
    /// `visible` controls whether a compose window opens. `finalAction` is the
    /// JXA run once the message is fully built, and must leave a `result`
    /// object in scope for the caller to return. `afterClose` runs after the
    /// compose message has been closed, for work that needs the *saved*
    /// message rather than the one being composed.
    /// `postProcess` gets the decoded result payload before it is returned, so
    /// a caller can add to it something only a read-back can establish.
    ///
    /// **Compose owns the compose message from creation to close.** It is
    /// created, used, closed, and then the account's Drafts is checked for the
    /// copy Mail autosaves behind its back -- see `composeDraftHygieneJXA` for
    /// why each of those steps is there and what was measured to put it there.
    /// The order is deliberate at both ends: the sender is validated and the
    /// Drafts snapshot taken **before** `mail.OutgoingMessage` exists, so a
    /// request that is going to be refused creates nothing at all; and the
    /// close comes immediately after the send or save, before anything slow,
    /// because everything between them is time in which Mail can autosave.
    private static func composeEmail(
        _ args: JSONObject?,
        visible: Bool,
        finalAction: String,
        disposesMessage: Bool,
        afterClose: String = "",
        postProcess: (([String: Any]) -> [String: Any])? = nil
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
                throw new Error('Mail produced an empty body from html_body — this build of Mail no longer accepts HTML. Resend using body instead. ' + composeLeftBehind());
            }
            """
        } ?? ""

        let script = """
        ObjC.import('Foundation');
        var mail = Application('Mail');
        \(boundByNameJXA)
        \(senderSnippet.lines)
        \(composeDraftHygieneJXA(subject: subject))
        var draft = mail.OutgoingMessage({
            subject: '\(escapeJSString(subject))',
            \(contentProp)\(visibleProp)
        });
        mail.outgoingMessages.push(draft);
        \(resolveOutgoingJXA)
        \(recipientLines)
        \(senderSnippet.prop)
        \(attachmentsJXA(attachments))
        // Read off the live message, before anything can close it: which
        // identity Mail is really sending as, and the subject Mail really
        // holds. Both are what the cleanup and the result are then built from.
        composeObserve();
        // Whitespace is stripped before counting, so this is not the body's
        // length -- 'just one line here' reports 15, not 18. It is deliberate:
        // the question it answers is "did Mail render anything visible", and
        // that is better served by ignoring whitespace than by counting it. Both
        // compose schemas say so, because a caller comparing this against
        // body.count otherwise sees a mismatch on every message with a space in
        // it and has nothing to explain it.
        var renderedChars = 0;
        try { renderedChars = ('' + msg.content()).replace(/\\s+/g, '').length; } catch (e) {}
        \(htmlGuard)
        \(preSendGuardJXA(
            to: to,
            cc: cc,
            bcc: bcc,
            subject: subject,
            from: args?["from"]?.stringValue,
            account: args?["account"]?.stringValue
        ))
        // With neither `from` nor `account` given this is the only thing that
        // says which identity the message went out as, and it is what points
        // the Drafts sweep and the saved-draft lookup at the right account.
        var composeSenderAccount = COMPOSE_SENDER.account;
        var result = {
            recipients: {to: \(to.count), cc: \(cc.count), bcc: \(bcc.count)},
            attachments: \(attachments.count),
            content_type: '\(htmlBody != nil ? "html" : "text")',
            rendered_chars: renderedChars,
            from: COMPOSE_SENDER.address,
            account: composeSenderAccount
        };
        \(finalAction)
        // Close the moment the send or save is done, with **nothing** in
        // between. Mail writes an autosaved copy of the message it is still
        // holding a few seconds after a send -- the leaked draft's own Date
        // header was 7s after the sent copy's -- and closing is what stops it.
        // The width of this gap is the whole of the fix: a send followed
        // immediately by this close left Drafts unchanged across two sends on
        // the fixture, and putting the Drafts check in the gap instead (a
        // second or so of Apple Events) was enough to let the copy through
        // again, once for Alice and once for Bob.
        try { msg.close({saving: 'no'}); } catch (e) {}
        // Then account for it, which is now a reading taken after Mail has
        // been told to stop. Reported unconditionally, found or not: a leaked
        // draft is invisible to every other tool here -- `mailbox: "all"`
        // excludes Drafts -- so "there was none" and "nobody looked" have to
        // be told apart in the result rather than inferred from a missing
        // field.
        result.autosaved_draft = COMPOSE_SWEEP === null
            ? composeSweepDrafts(composeSenderAccount, \(disposesMessage))
            : COMPOSE_SWEEP;
        \(afterClose)
        JSON.stringify(result);
        """
        // Composing has no scope: the message is the message.
        let (output, error) = runJXA(script, retries: 0, scopable: false)
        if let error { return errorResult(error) }
        guard let data = output.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return textResult(output)
        }
        return jsonResult(postProcess?(payload) ?? payload)
    }

    /// What Mail actually composed, compared with what the caller asked for.
    struct BodyCheck {
        /// True when the message's `text/plain` alternative is the body that was
        /// asked for.
        let matches: Bool
        /// Present when it is not, saying how it differs.
        let detail: String?

        var dict: [String: Any] {
            var out: [String: Any] = ["plain_text_matches_body": matches]
            if let detail { out["detail"] = detail }
            return out
        }
    }

    /// Compares the `text/plain` alternative of a composed message against the
    /// body that was requested.
    ///
    /// This exists because Mail rewrites the body of anything composed through
    /// its scripting interface, and the compose script cannot see it happen:
    /// `msg.content()` reads back exactly what was set, and the alternatives are
    /// generated later. So `rendered_chars` reports a plausible number for a
    /// message whose plain-text part is quoted, or empty.
    ///
    /// Reading the saved message is the only way to know, which is why this
    /// takes raw source rather than anything Mail said.
    static func checkComposedBody(source: Data, requestedBody: String) -> BodyCheck {
        func normalise(_ s: String) -> String {
            s.replacingOccurrences(of: "\r\n", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let plainPart = firstPlainTextPart(of: MIME.parse(source)) else {
            return BodyCheck(
                matches: false,
                detail: "the message has no text/plain part — the body exists only as HTML, which a plain-text-preferring client will show as blank"
            )
        }
        let plain = normalise(
            String(data: plainPart, encoding: .utf8)
                ?? String(data: plainPart, encoding: .isoLatin1)
                ?? ""
        )
        let wanted = normalise(requestedBody)
        if plain == wanted { return BodyCheck(matches: true, detail: nil) }

        if plain.isEmpty && !wanted.isEmpty {
            return BodyCheck(
                matches: false,
                detail: "Mail wrote an empty text/plain part; the body survives only in the text/html alternative, so any client that prefers plain text shows this message as blank"
            )
        }
        // Mail derives the plain-text alternative from HTML, and it wraps a
        // scripted body in <blockquote type="cite">, which comes out as "> " on
        // every line.
        let unquoted = normalise(
            plain.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.hasPrefix("> ") ? String($0.dropFirst(2)) : ($0 == ">" ? "" : String($0)) }
                .joined(separator: "\n")
        )
        if unquoted == wanted {
            return BodyCheck(
                matches: false,
                detail: "Mail quoted the body: every line of the text/plain part is prefixed with \"> \", so the recipient reads it as quoted or forwarded text rather than as the sender's own words"
            )
        }
        return BodyCheck(
            matches: false,
            detail: "the text/plain part is not the body that was supplied"
        )
    }

    /// The first `text/plain` part that is a body rather than an attachment.
    ///
    /// Iterative, like `MIME.attachments(of:)` and for the same reason: a walk
    /// that recurses over a tree whose depth the sender chose is a way to
    /// exhaust the stack, and this one is reached from a compose path that can
    /// be handed back a message someone else wrote.
    private static func firstPlainTextPart(of root: MIME.Part) -> Data? {
        var stack: [MIME.Part] = [root]
        while let part = stack.popLast() {
            if part.isMultipart {
                stack.append(contentsOf: part.parts.reversed())
                continue
            }
            guard part.contentType == "text/plain",
                  part.filename == nil,
                  part.disposition != "attachment" else { continue }
            return part.decodedBody
        }
        return nil
    }

    /// Composed invisibly on purpose. Composing with `visible: true` puts a real
    /// window on screen, and a frontmost compose window is something Mail can
    /// act on in place of the message the script is holding — which is how a
    /// send once went out to the recipient of an unrelated window the user had
    /// open, rather than the address that was passed in. Nothing is gained by
    /// the window: `send` needs no UI.
    ///
    /// The close that `composeEmail` runs straight after this is what stops
    /// the send leaving a full copy of the message in Drafts. `visible: false`
    /// is what made it necessary -- there is no window whose closing would
    /// have done it -- so the two go together, and neither can be dropped in
    /// favour of the other.
    private static func sendEmail(_ args: JSONObject?) -> MCPCallResult {
        // `disposesMessage: true`: after `send()` Mail has let go of the
        // compose message, which is the one state in which removing a leftover
        // autosaved copy sticks rather than provoking another.
        composeEmail(args, visible: false, finalAction: """
        msg.send();
        result.status = 'sent';
        """, disposesMessage: true)
    }

    /// After saving, the draft is looked up and its identifiers returned.
    ///
    /// This is what makes a draft verifiable. Mail's numeric id for a freshly
    /// saved IMAP draft is short-lived — the server takes the upload and hands
    /// back its own copy, and the local one is gone — so the RFC Message-ID
    /// goes back too, and `mail_get_email` accepts either.
    /// JXA that finds the draft just saved and names it, defining `savedDraft`.
    ///
    /// Nothing in the compose script can hand the saved message back: `save`
    /// returns nothing, and the outgoing message it was composed from is not the
    /// draft the account filed. So the draft is found by subject in the
    /// account's Drafts mailbox, newest id first.
    ///
    /// The id and subject columns are separate Apple Events, so the newest id
    /// carrying that subject is a **guess** until the message confirms it.
    /// Binding by that id and reading the subject back off the bound message is
    /// what turns it into an answer -- and it is the handle `body_check` then
    /// fetches a source for, so naming the wrong message here would check the
    /// wrong draft's body (#50). The Message-ID is read off the same bound
    /// message rather than out of a third column, which is one Apple Event
    /// fewer and one fewer thing to zip by index.
    ///
    /// **A caller who named neither `account` nor `from` gets an answer too.**
    /// The walk used to admit an account only when its name matched `account`
    /// or one of its addresses matched `from`; with both null nothing could
    /// ever match, so `savedDraft` came back null and `mail_create_draft`
    /// answered `{"status": "draft created", "draft": null}` with no
    /// `body_check` at all -- on the **default** path, which is what a caller
    /// with one account uses. The draft was written; its `text/plain` part was
    /// empty, which is exactly the failure `body_check` exists to report.
    ///
    /// Two things scope it instead. `composeSenderAccount`, when compose has
    /// defined it, is the account Mail said it was sending from, read off the
    /// message -- an answer rather than a guess. Failing that the search is
    /// unscoped, which is right for the request that named no scope: the draft
    /// is looked for wherever it is, and the subject plus the read-back off
    /// the bound message is still what decides.
    ///
    /// `includeHelpers` is false where the caller has already emitted
    /// `boundByNameJXA` -- compose has, since its Drafts snapshot needs it.
    ///
    /// Not private: this is the fourth place the same positional binding was
    /// found, and it can only be pinned by running it against a mailbox that
    /// changes between two column fetches.
    static func savedDraftLookupJXA(
        account: String?,
        from: String?,
        subject: String,
        includeHelpers: Bool = true
    ) -> String {
        let acctExpr = account.map { "'\(escapeJSString($0))'.toLowerCase()" } ?? "null"
        let fromExpr = from.map { "'\(escapeJSString($0))'.toLowerCase()" } ?? "null"
        return """
\(includeHelpers ? boundByNameJXA : "")
var savedDraft = (function() {
    var wantAcct = \(acctExpr);
    var wantFrom = \(fromExpr);
    var SUBJECT = '\(escapeJSString(subject))';
    // Nothing was named, so ask the message. `composeSenderAccount` is the
    // account Mail reported as the sender of the message that was just saved;
    // outside compose there is no such variable and the search stays unscoped.
    if (wantAcct === null && wantFrom === null
            && typeof composeSenderAccount !== 'undefined' && composeSenderAccount) {
        wantAcct = ('' + composeSenderAccount).toLowerCase();
    }
    // With no scope of any kind, every account is a candidate. Returning null
    // instead is what cost the default path its draft id and its body_check.
    var unscoped = wantAcct === null && wantFrom === null;
    try {
        var accts = boundByNameOrThrow(mail.accounts, 'the account list');
        for (var i = 0; i < accts.length; i++) {
            var name = accts[i].name;
            var match = unscoped || (wantAcct !== null && name.toLowerCase() === wantAcct);
            if (!match && wantFrom !== null) {
                var addrs = accts[i].element.emailAddresses();
                for (var a = 0; a < addrs.length; a++) {
                    if (('' + addrs[a]).toLowerCase() === wantFrom) { match = true; break; }
                }
            }
            if (!match) continue;
            var mbs = boundByNameOrThrow(accts[i].element.mailboxes, 'the mailbox list of account "' + name + '"');
            // The account's own Drafts is the one at the root of it, so it is
            // tried first: a user folder called `Drafts` nested inside a
            // project is enumerated under the same leaf name and Mail lists
            // children before parents. The loop still falls through to any
            // other mailbox of that name rather than giving up, which is what
            // it did before and is why a nested Drafts never shadowed the real
            // one -- this only stops it costing a wasted pass.
            var order = [];
            for (var j = 0; j < mbs.length; j++) {
                if (mbs[j].element !== null && mbs[j].path.toLowerCase() === 'drafts') order.push(mbs[j]);
            }
            for (var j = 0; j < mbs.length; j++) {
                if (mbs[j].element !== null && mbs[j].path.toLowerCase() !== 'drafts'
                    && mbs[j].name.toLowerCase() === 'drafts') order.push(mbs[j]);
            }
            for (var j = 0; j < order.length; j++) {
                var box = order[j];
                var drafts = box.element;
                // The id and subject columns are separate Apple Events,
                // so the newest id carrying this subject is a guess
                // until the message itself confirms it. Binding by that
                // id and reading the subject back off the bound message
                // is what turns it into an answer -- and it is the
                // handle `body_check` then fetches a source for, so
                // naming the wrong message here would check the wrong
                // draft's body (#50). The third column this used to
                // fetch is gone: the Message-ID is read off the message.
                for (var attempt = 0; attempt < \(findAttempts); attempt++) {
                    var ids = drafts.messages.id();
                    var subs = drafts.messages.subject();
                    if (ids.length !== subs.length) continue;
                    var best = -1;
                    for (var k = 0; k < ids.length; k++) {
                        if (('' + subs[k]) !== SUBJECT) continue;
                        if (best < 0 || ids[k] > ids[best]) best = k;
                    }
                    if (best < 0) break;
                    var numeric = parseInt('' + ids[best], 10);
                    if (!isFinite(numeric)) break;
                    var saved = drafts.messages.byId(numeric);
                    var gotSubject = null;
                    try { gotSubject = '' + saved.subject(); } catch (e) { continue; }
                    if (gotSubject !== SUBJECT) continue;
                    var rfc = '';
                    try { var r = saved.messageId(); rfc = r == null ? '' : '' + r; } catch (e) {}
                    return {
                        account: name,
                        mailbox: box.path,
                        message_id: '' + ids[best],
                        rfc_message_id: rfc
                    };
                }
            }
        }
    } catch (e) { return {lookup_error: '' + e}; }
    return null;
})();
"""
    }

    private static func createDraft(_ args: JSONObject?) -> MCPCallResult {
        let account = args?["account"]?.stringValue
        let from = args?["from"]?.stringValue
        let subject = args?["subject"]?.stringValue ?? ""

        let finalAction = """
        mail.save(msg);
        result.status = 'draft created';
        """
        // Everything below runs after the compose message has been closed.
        // The 1.5s wait for the account to file the draft used to sit between
        // the save and the close, which is a second and a half of Mail being
        // free to autosave a second copy of the same message.
        let afterClose = """
        // Let the account file the saved draft before looking for it.
        $.NSThread.sleepForTimeInterval(1.5);
        \(savedDraftLookupJXA(account: account, from: from, subject: subject, includeHelpers: false))
        result.draft = savedDraft;
        """
        // Read the saved draft back off the server and compare its text/plain
        // part with the body that was asked for. Mail rewrites the body of
        // anything composed through its scripting interface -- a plain body
        // comes back quoted, and a draft's plain part comes back empty -- and
        // nothing in the compose script can see it happen, because `content()`
        // reads back exactly what was set and the alternatives are generated
        // afterwards. Reporting `rendered_chars` and calling it a success is how
        // that went unnoticed.
        //
        // Only for a plain `body`: the plain-text part of an html_body message
        // is Mail's own rendering, and there is nothing to compare it against.
        // `disposesMessage: false`: `save` does not end Mail's interest in the
        // compose message, so an autosaved copy is reported rather than
        // deleted -- deleting one Mail is still holding brings it back.
        return composeEmail(args, visible: false, finalAction: finalAction, disposesMessage: false, afterClose: afterClose) { payload in
            guard let body = args?["body"]?.stringValue,
                  args?["html_body"]?.stringValue == nil,
                  let draft = payload["draft"] as? [String: Any] else { return payload }
            let identifier = (draft["rfc_message_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (draft["message_id"] as? String)
            guard let identifier else { return payload }

            let (source, _, fetchError) = fetchSource(
                account: draft["account"] as? String,
                mailbox: draft["mailbox"] as? String ?? "Drafts",
                messageId: identifier
            )
            var enriched = payload
            guard fetchError == nil else {
                enriched["body_check"] = ["plain_text_matches_body": NSNull(), "detail": "could not read the saved draft back: \(fetchError!)"]
                return enriched
            }
            enriched["body_check"] = checkComposedBody(source: source, requestedBody: body).dict
            return enriched
        }
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
    /// Known limits, neither of them recoverable here, both measured against
    /// the testMail fixture's Maildir and reported by `sourceFidelity`:
    ///
    /// * A NUL in the message comes back as `0x80`.
    /// * Every CRLF comes back as LF.
    ///
    /// Both happen **inside Mail**, before macMCP is involved. The text channel
    /// is not at fault, though this comment used to say it was: plain JXA emits
    /// both fine (`'a' + String.fromCharCode(0)` reaches stdout as `61 00`, and
    /// `'a\r\nb'` as `61 0d 0a 62`), Swift's UTF-8/Latin-1 round trip preserves
    /// `0d 0a`, and Mail's own `.emlx` copy of a message written to disk with 21
    /// CRLFs and one NUL holds 0 CRs and 0 NULs. Nothing downstream can undo
    /// that, so it is reported rather than papered over.
    static func decodeSourceBytes(_ raw: Data) -> Data {
        var data = raw
        if data.last == 0x0A { data = data.dropLast() }
        guard let text = String(data: data, encoding: .utf8),
              let recovered = text.data(using: .isoLatin1) else {
            return data
        }
        return recovered
    }

    /// How faithfully a fetched source matches the message the server holds.
    ///
    /// #5 was closed on the claim that a fetched source is byte-identical to the
    /// message. Measured against the fixture's Maildir it is not, in two ways,
    /// and both are Mail's doing rather than anything macMCP can undo:
    ///
    /// * **A NUL arrives as `0x80`.** 253 of the 254 byte values a probe message
    ///   carried round-tripped exactly; `0x00` did not. Worse than losing it, it
    ///   is now *ambiguous*: a `0x80` in a returned source is either a real
    ///   `0x80` in the message or a NUL that did not survive, and after the fact
    ///   nothing can tell the two apart. So the count is reported, not a claim.
    /// * **Every CRLF arrives as LF.** A message stored with 21 CRLFs came back
    ///   with 21 LFs and no CR at all, which means a byte comparison against the
    ///   message's wire form differs on every line break.
    ///
    /// A code comment is not an interface, which is the whole point of this
    /// function: a caller checksumming a saved message, or writing an 8bit
    /// attachment to disk, has to be able to see this in the response.
    ///
    /// `source_encoding` is not the place for it. That field says how the inline
    /// `source` string was encoded for return; it exists only on the inline path,
    /// and a source can be perfectly valid `utf-8` and still be missing a NUL.
    ///
    /// There is deliberately **no summary boolean** here. There used to be:
    /// `exact`, true when the source was complete, free of `0x80`, and had CRLF
    /// line endings. Mail strips every CR, so the third condition never held on
    /// the live pipeline and `exact` was false for every real message --
    /// including one whose fetched bytes were byte-identical to the copy on
    /// disk. A field that cannot be true tells a caller nothing, and three tests
    /// asserted it on a branch only synthetic data could reach. What is left is
    /// three facts, each of which can go either way, and a note that says what
    /// they mean.
    struct SourceFidelity {
        /// "crlf", "lf", "mixed", or "none" for a source with no line breaks.
        let lineEndings: String
        /// How many bytes are `0x80` where a NUL could have been lost.
        ///
        /// Not every `0x80`. A `0x80` sitting in a well-formed multi-byte UTF-8
        /// sequence is a continuation byte and cannot be Mail's replacement for
        /// a NUL, which always lands standalone -- counting those reported
        /// `ambiguous_nul_bytes: 3` for a body whose only sin was three em
        /// dashes (`E2 80 94`), on a message containing no NUL and no real
        /// `0x80` at all.
        let ambiguousNulBytes: Int
        /// The wire size Mail reports for the message, when it could be read.
        let expectedSize: Int?
        /// How many bytes were measured -- the whole source Mail handed over,
        /// which is not necessarily the number of bytes a result returns.
        let byteCount: Int
        /// What the returned bytes would measure on the wire: one CR back for
        /// every LF, since that is the transform they came through.
        let wireSize: Int

        /// False when Mail was still downloading and handed over a fragment --
        /// 838 bytes of a 300 KB message in one measurement, with nothing in the
        /// old response to distinguish that from a 838-byte message.
        ///
        /// Two things it is worth being precise about:
        ///
        /// * **Zero bytes is never complete**, whatever Mail says the size is.
        ///   Every RFC 822 message has a header block, so an empty source is
        ///   the absence of a message rather than an empty one, and it is the
        ///   one case that needs no size to judge.
        /// * **A message whose size Mail would not report is not accused.** An
        ///   unreadable `messageSize` is not evidence that the download is
        ///   unfinished, and refusing every such message would cost reads that
        ///   work. `complete` is then "nothing contradicts it" rather than a
        ///   verified match -- `sizeKnown` says which of the two a caller has,
        ///   and the note says so in words.
        var complete: Bool { completeBasis != "short" && completeBasis != "none" }

        /// What `complete` rests on, because it is not always the same thing
        /// and the weaker case has slack in it (#53).
        ///
        /// `messageSize` is quoted in one of two units and Mail does not say
        /// which. A message the server holds is quoted in **wire** units, CRLFs
        /// counted: a 489-byte message measured 375+19 here and 394 there. A
        /// **local draft** is quoted in the units Mail stores it in, LF endings
        /// and all -- measured at `bytes_measured: 1362` against
        /// `message_size: 1362`, matching the Maildir's `S=1362` rather than its
        /// `W=1395`.
        ///
        /// Counting every LF as a CRLF, which is what makes the server case come
        /// out right, therefore hands the local case one byte of slack per line
        /// break: a 1362-byte draft passes at `1362 + 33 >= 1362`, and so would a
        /// fragment of it 33 bytes short. Hence:
        ///
        /// * `"bytes"` -- the bytes reach the size **on their own**, so it holds
        ///   whichever unit Mail quoted. Nothing is assumed.
        /// * `"wire"` -- they reach it only once each LF is counted as a CRLF.
        ///   True for the ordinary server-side message, and the note says how
        ///   many bytes would be missing if Mail had meant the other unit.
        /// * `"short"` -- they do not reach it either way. A fragment.
        /// * `"unchecked"` -- Mail would not report a size.
        /// * `"none"` -- no bytes at all, which is never a message.
        ///
        /// The obvious tightening -- requiring one of the two readings to match
        /// *exactly*, which both measurements above do -- is deliberately not
        /// taken. It would close the slack, and it would turn any imprecision in
        /// `messageSize` into a permanent false `incomplete`, which costs a
        /// caller `mail_save_attachment` entirely. Reporting the basis costs
        /// them nothing.
        var completeBasis: String {
            if byteCount == 0 { return "none" }
            guard let expectedSize else { return "unchecked" }
            if byteCount >= expectedSize { return "bytes" }
            if wireSize >= expectedSize { return "wire" }
            return "short"
        }

        /// Whether `complete` was checked against a size Mail supplied.
        var sizeKnown: Bool { expectedSize != nil }

        /// How many bytes would be missing if `messageSize` were quoted in the
        /// units Mail stores the message in rather than in wire units. Zero
        /// unless `completeBasis` is `"wire"`.
        var slackBytes: Int {
            guard completeBasis == "wire", let expectedSize else { return 0 }
            return expectedSize - byteCount
        }

        var note: String? {
            var sentences: [String] = []
            if byteCount == 0 {
                sentences.append("Mail returned no bytes at all for this message — not even its headers had arrived. An RFC 822 message always has a header block, so this is the absence of a message rather than an empty one. Try again in a moment.")
            } else if !complete, let expectedSize {
                sentences.append("Mail had only \(wireSize) of this message's \(expectedSize) bytes when the source was read and did not finish downloading the rest within the wait, so what is here is a fragment rather than the message. Try again in a moment.")
            } else if !sizeKnown {
                sentences.append("Mail would not report this message's size, so whether it had finished downloading could not be checked: complete is \"nothing contradicts it\" here rather than a verified match.")
            } else if completeBasis == "wire" {
                sentences.append("These \(byteCount) bytes reach the \(expectedSize ?? 0) Mail reports only once each LF is counted as the CRLF it stood for on the wire, which is how a server-side message is sized. Mail sizes a local draft in the units it stores it in instead, and read that way \(slackBytes) byte(s) of this message would still be missing — so complete rests on which unit Mail meant here, and complete_basis says so.")
            }
            if lineEndings == "lf" || lineEndings == "mixed" {
                sentences.append("Mail hands a source back with LF line endings where the message's wire form has CRLF, so a byte comparison against the wire form differs on every line break; a copy stored with LF endings, as a Maildir server holds it, can still match exactly.")
            }
            if ambiguousNulBytes > 0 {
                sentences.append("\(ambiguousNulBytes) byte(s) of this source are 0x80 in a position where a NUL could have been lost — counted across all \(byteCount) bytes Mail returned, not only across any slice this result carries. Mail turns a NUL into 0x80 before macMCP sees it, so each one is either a real 0x80 in the message or a NUL that did not survive — the two are indistinguishable. A 0x80 that is part of a valid UTF-8 character is not counted, and parts carried as base64 or quoted-printable are unaffected, their encoded form being pure ASCII.")
            }
            return sentences.isEmpty ? nil : sentences.joined(separator: " ")
        }

        var dict: [String: Any] {
            var out: [String: Any] = [
                "complete": complete,
                // What `complete` rests on: "bytes" when the bytes reach the
                // size on their own, "wire" when they reach it only once each
                // LF is counted as a CRLF, "short", "unchecked", or "none".
                "complete_basis": completeBasis,
                "line_endings": lineEndings,
                "ambiguous_nul_bytes": ambiguousNulBytes,
                // Which bytes the two counts above were measured over, since a
                // result may return fewer than these.
                "bytes_measured": byteCount,
                // null rather than absent: "Mail would not say" is a different
                // answer from "nobody asked", and it is what makes `complete`
                // above unverified.
                "message_size": expectedSize as Any? ?? NSNull()
            ]
            if let note { out["note"] = note }
            return out
        }
    }

    static func sourceFidelity(_ data: Data, expectedSize: Int? = nil) -> SourceFidelity {
        var crlf = 0, bareLF = 0, bareCR = 0
        var previous: UInt8 = 0
        for byte in data {
            switch byte {
            case 0x0A: if previous == 0x0D { crlf += 1 } else { bareLF += 1 }
            default: break
            }
            if previous == 0x0D && byte != 0x0A { bareCR += 1 }
            previous = byte
        }
        if previous == 0x0D { bareCR += 1 }

        let endings: String
        switch (crlf, bareLF + bareCR) {
        case (0, 0): endings = "none"
        case (_, 0): endings = "crlf"
        case (0, _): endings = bareLF > 0 && bareCR == 0 ? "lf" : "mixed"
        default: endings = "mixed"
        }
        return SourceFidelity(
            lineEndings: endings,
            ambiguousNulBytes: standaloneHighBytes(data),
            expectedSize: expectedSize,
            byteCount: data.count,
            // Every LF here stood for a CRLF on the wire, so this is what these
            // bytes weigh in the units `messageSize` is quoted in.
            wireSize: data.count + crlf + bareLF
        )
    }

    /// Counts `0x80` bytes that are not continuation bytes of a well-formed
    /// UTF-8 sequence.
    ///
    /// Mail's replacement for a NUL is a lone `0x80`. `E2 80 94` — an em dash —
    /// also contains one, and so does a large share of ordinary mail: a body
    /// reading `em dash — here — and Hebrew שלום — end` has no NUL and no real
    /// `0x80` in it, and was reported as carrying three lost NULs. A `0x80` that
    /// completes a valid multi-byte character cannot be one, so the sequence is
    /// stepped over whole.
    ///
    /// A source is not required to be UTF-8 — it is raw RFC 822 bytes, and a
    /// binary part can hold anything. Byte values that happen to spell a valid
    /// sequence are therefore skipped there too, which under-counts rather than
    /// over-counts. That is the right way round: the count exists to make a real
    /// loss visible, and a warning that fires on em dashes is one callers learn
    /// to ignore.
    static func standaloneHighBytes(_ data: Data) -> Int {
        let bytes = [UInt8](data)
        var count = 0
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            if byte < 0x80 { i += 1; continue }
            if let length = utf8SequenceLength(bytes, at: i) { i += length; continue }
            if byte == 0x80 { count += 1 }
            i += 1
        }
        return count
    }

    /// The length of the well-formed UTF-8 sequence starting at `index`, or nil
    /// if there is not one. Rejects overlong forms, surrogates and anything
    /// above U+10FFFF, so their continuation bytes are not skipped over.
    private static func utf8SequenceLength(_ bytes: [UInt8], at index: Int) -> Int? {
        func continuation(_ offset: Int, _ range: ClosedRange<UInt8>) -> Bool {
            index + offset < bytes.count && range.contains(bytes[index + offset])
        }
        let lead = bytes[index]
        switch lead {
        case 0xC2...0xDF:
            return continuation(1, 0x80...0xBF) ? 2 : nil
        case 0xE0:
            return continuation(1, 0xA0...0xBF) && continuation(2, 0x80...0xBF) ? 3 : nil
        case 0xE1...0xEC, 0xEE...0xEF:
            return continuation(1, 0x80...0xBF) && continuation(2, 0x80...0xBF) ? 3 : nil
        case 0xED:
            return continuation(1, 0x80...0x9F) && continuation(2, 0x80...0xBF) ? 3 : nil
        case 0xF0:
            return continuation(1, 0x90...0xBF) && continuation(2, 0x80...0xBF) && continuation(3, 0x80...0xBF) ? 4 : nil
        case 0xF1...0xF3:
            return continuation(1, 0x80...0xBF) && continuation(2, 0x80...0xBF) && continuation(3, 0x80...0xBF) ? 4 : nil
        case 0xF4:
            return continuation(1, 0x80...0x8F) && continuation(2, 0x80...0xBF) && continuation(3, 0x80...0xBF) ? 4 : nil
        default:
            return nil
        }
    }

    /// How long the source fetch waits for Mail to finish downloading a message
    /// it has only part of, and how often it looks.
    static let sourceCompletionAttempts = 20
    static let sourceCompletionInterval = 0.5

    /// Marks the size line the source script prints ahead of the message.
    ///
    /// The source itself is raw bytes on stdout, so there is nowhere else to put
    /// the size without either corrupting it or paying for a second osascript
    /// spawn. One ASCII line, stripped only when it is exactly this shape.
    private static let sourceSizeMarker = "MACMCP-SIZE:"

    /// The source fetch, minus the `var mail = Application('Mail');` line.
    ///
    /// Not private, and split from the handler, for the same reason the move
    /// script is: the logic worth testing is in the JavaScript. `attempts` and
    /// `interval` are parameters so a test can run the wait without spending ten
    /// seconds on it.
    ///
    /// `source()` returns what Mail has downloaded so far, which for a message
    /// still arriving is the headers and a fragment -- 838 bytes of a 300 KB
    /// message in one measurement, reported as the whole thing (#31). So the
    /// script asks Mail how big the message is and waits, bounded, for the bytes
    /// to add up. `messageSize` is the wire size, and every LF in a returned
    /// source stands for one CRLF on the wire, which makes the check exact
    /// rather than a heuristic.
    ///
    /// An **empty** source is waited for whatever the size says, including when
    /// `messageSize` could not be read at all. That is the one judgement a size
    /// is not needed for: no RFC 822 message has an empty source, so zero bytes
    /// is always Mail not having started rather than a message to report.
    static func sourceScriptJXA(
        account: String?,
        mailbox: String,
        messageId: String,
        attempts: Int = sourceCompletionAttempts,
        interval: Double = sourceCompletionInterval
    ) -> String {
        """
        \(findMessageJXA(account: account, mailbox: mailbox, messageId: messageId))
        if (!found) { throw new Error('message not found with id: \(escapeJSString(messageId))'); }
        var expected = -1;
        try { expected = found.messageSize(); } catch (e) {}
        function wireLength(s) { return s.length + (s.split('\\n').length - 1); }
        var src = '' + found.source();
        function short(s) { return s.length === 0 || (expected > 0 && wireLength(s) < expected); }
        for (var attempt = 0; attempt < \(attempts) && short(src); attempt++) {
            delay(\(interval));
            src = '' + found.source();
        }
        var sourceResult = '\(sourceSizeMarker)' + expected + '\\n' + src;
        sourceResult;
        """
    }

    private static func fetchSource(
        account: String?,
        mailbox: String,
        messageId: String,
        timeout: TimeInterval = sourceFetchTimeout
    ) -> (data: Data, expectedSize: Int?, error: String?) {
        let script = """
        var mail = Application('Mail');
        \(sourceScriptJXA(account: account, mailbox: mailbox, messageId: messageId))
        """
        let (data, error) = runJXAData(script, retries: 0, timeout: timeout, scopable: true)
        if let error {
            if error.contains("message not found") {
                return (Data(), nil, "message not found with id: \(messageId)")
            }
            return (Data(), nil, error)
        }
        let marker = splitSourceSizeMarker(data)
        if let error = marker.error { return (Data(), nil, error) }
        return (decodeSourceBytes(marker.body), marker.size, nil)
    }

    /// Splits the size line off the front of the script's output.
    ///
    /// Not private, and separate from the fetch, because this is where a
    /// sideband line of macMCP's own can end up inside a caller's message.
    ///
    /// **The line is macMCP's, always, and is always at offset 0.**
    /// `sourceScriptJXA` builds its result as `'MACMCP-SIZE:' + expected + '\n'`
    /// before a single byte of the message, unconditionally and on every path
    /// including the one where `messageSize()` threw. So this used to fail
    /// *open* -- returning the raw bytes untouched when the value on the line
    /// did not parse, on the reasoning that a message beginning with something
    /// that merely looks like the marker must not lose its first line. That
    /// reasoning is void: the caller's first line is never at offset 0, because
    /// the marker is. What failing open actually did was leave
    /// `MACMCP-SIZE:null` in the bytes, where it reaches `save_to` files,
    /// `bytes_total`, `sourceFidelity`'s counts, and `MIME.parse` as a bogus
    /// `macmcp-size:` header on the message.
    ///
    /// So it fails closed, in the two ways it can:
    ///
    /// * **The line is stripped whatever is on it.** Losing the size costs a
    ///   caller `complete_basis: "unchecked"`, which is an answer the result
    ///   already knows how to give. Keeping the line costs them their message.
    /// * **A value macMCP did not write is an error**, named as one. `-1` is
    ///   accepted because the script writes it itself -- it is the initialiser
    ///   of `expected`, and the documented way to say `messageSize()` raised.
    ///   Anything else (`null`, `NaN`, a float) means the script's own contract
    ///   did not hold, and the wait loop that decides whether the source is
    ///   complete ran on that same value. Nothing here can say what was
    ///   fetched, so it does not.
    static func splitSourceSizeMarker(_ raw: Data) -> (size: Int?, body: Data, error: String?) {
        let marker = Data(sourceSizeMarker.utf8)
        guard raw.starts(with: marker), let newline = raw.firstIndex(of: 0x0A) else {
            return (nil, Data(), "the source fetch returned output that does not begin with its own \(sourceSizeMarker) line, which the script writes before every message on every path — so nothing here can tell macMCP's own bytes from the message's, and none are returned. This is a bug in macMCP rather than something about the message; please report it.")
        }
        let body = Data(raw[(newline + 1)...])
        let digits = raw[(raw.startIndex + marker.count)..<newline]
        guard !digits.isEmpty,
              digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 || $0 == 0x2D }),
              let size = Int(String(decoding: digits, as: UTF8.self)) else {
            let text = String(decoding: digits, as: UTF8.self)
            return (nil, body, "the source fetch reported this message's size as \"\(text)\", which is not a number macMCP wrote — the script writes a count, or -1 when Mail would not give one. The wait that decides whether the whole message had arrived ran against that same value, so whether these bytes are the message or a fragment of it is unknown and they are not returned. Try again in a moment.")
        }
        return (size > 0 ? size : nil, body, nil)
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

        let (data, expectedSize, fetchError) = fetchSource(
            account: args?["account"]?.stringValue,
            mailbox: mailbox,
            messageId: messageId
        )
        if let fetchError { return errorResult(fetchError) }

        // Refuse rather than write a file cut out of a fragment. An attachment
        // saved from a half-downloaded message is silently wrong on disk, which
        // is worse than a failure the caller can retry.
        let fidelity = sourceFidelity(data, expectedSize: expectedSize)
        if !fidelity.complete {
            guard let expectedSize else {
                return errorResult("Mail returned none of this message's bytes — not even its headers — so there is nothing to cut an attachment out of. Try again in a moment.")
            }
            return errorResult("Mail has only \(fidelity.wireSize) of this message's \(expectedSize) bytes and did not finish downloading it — attachments cut from that would be truncated. Try again in a moment.")
        }

        let parsed = MIME.parseReporting(data)
        let all = MIME.attachments(of: parsed.part)
        guard !all.isEmpty else {
            // "No attachments" measured against a message the reader could not
            // read in full is the same class of confident wrong answer as one
            // measured against a message Mail had not finished downloading, and
            // is refused for the same reason.
            guard parsed.report.complete else {
                return errorResult("no attachment could be read out of message \(messageId), which is not the same as the message having none: \(parsed.report.note ?? "the message could not be read in full")")
            }
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
            // Of the source the attachments were cut out of. What is written to
            // disk is only as faithful as what Mail handed over, and a caller
            // saving an 8bit part has no other way to learn that.
            "fidelity": fidelity.dict,
            // Of the parse the attachments were cut out of, on the same footing
            // as `fidelity` above: an attachment nested below `MIME.maxDepth`
            // is simply absent from `saved`, and `parsed_complete` is the only
            // thing that separates that from a message that did not have one.
            "structure": parsed.report.dict,
            "message_id": messageId
        ])
    }

    private static func getSource(_ args: JSONObject?) -> MCPCallResult {
        guard let messageId = args?["message_id"]?.stringValue else {
            return errorResult("message_id is required")
        }
        let mailbox = args?["mailbox"]?.stringValue ?? "INBOX"
        let (data, expectedSize, fetchError) = fetchSource(
            account: args?["account"]?.stringValue,
            mailbox: mailbox,
            messageId: messageId
        )
        if let fetchError { return errorResult(fetchError) }
        let fidelity = sourceFidelity(data, expectedSize: expectedSize)

        // A fragment is returned, with `fidelity` saying how much of the message
        // it is: headers alone are worth having, and reporting them honestly is
        // what this seam is for. Zero bytes is different. There is nothing to
        // report on, no RFC 822 message has an empty source, and returning
        // `"source": ""` with `truncated: false` reads as "this message is
        // empty" to anyone who does not also read `fidelity` — the same
        // confident wrong answer `mail_save_attachment` already refuses to give.
        if data.isEmpty {
            var message = "Mail returned no bytes at all for this message — not even its headers had arrived, so there is no source to return. Try again in a moment."
            if let expectedSize { message += " Mail reports the message as \(expectedSize) bytes." }
            return errorResult(message)
        }

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
            return jsonResult([
                "path": url.path,
                "bytes": data.count,
                "message_id": messageId,
                "fidelity": fidelity.dict
            ])
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
            // Measured over the whole source, not the returned slice: the
            // caveats are properties of how Mail handed the message over, and a
            // caller asking for the first kilobyte still needs to know that the
            // rest of it is subject to them.
            "fidelity": fidelity.dict,
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
        // The destination the caller asked for, checked against the mailbox
        // that is about to be written to -- asked of that mailbox rather than
        // of the list it came out of. `destMboxPath` is what the request
        // resolved to; `mbPathOf` walks the bound mailbox's own containers. If
        // the two disagree the binding found something other than what was
        // asked for, and the right answer is to move nothing.
        //
        // This is the half of the old verification that was missing. The
        // read-back below looks for the message in `destMbox`, which confirms
        // *where it was put* and can never contradict the pick; a move to
        // "Trash" that filed into `R4-PROBE-Deep/Trash` came back
        // `verified: true`. Both halves are needed: this one says the mailbox
        // is the one that was asked for, that one says the message reached it.
        var destName = mbPathOf(destMbox);
        if (destName === null || destName.toLowerCase() !== ('' + destMboxPath).toLowerCase()) {
            moveResult = {error: 'the destination resolved to "' + destMboxPath + '" but reads back as "'
                + destName + '"; nothing was moved'};
        } else {
        // Where the message is *now*. Resolving the destination is dozens of
        // Apple Events, and `moved_from` claims to describe the move that is
        // about to happen rather than the state the search left behind. `found`
        // is bound by id, so this either answers for the same message or says
        // it has gone -- which is the one case where refusing beats moving.
        var origin = fmLocate(found);
        if (origin === null) {
            moveResult = {error: 'message \(escapedId) is no longer in Mail; nothing was moved'};
        } else {
        var sourceAccount = origin.account;
        var sourceMailboxName = origin.mailbox;
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
            // Which message this happened to. The result used to name only the
            // destination, so a message filed under the wrong id was invisible
            // in it (#50). The numeric id does not survive an IMAP re-file, so
            // it identifies what was acted on rather than what to ask for next;
            // the RFC Message-ID does survive, and is the handle to use.
            message_id: numericId,
            rfc_message_id: rfcId,
            moved_from: {account: sourceAccount, mailbox: sourceMailboxName},
            cross_account: destMboxAccount !== sourceAccount,
            verified: verified
        };
        }
        }
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
        // See `mutatingRetries`: this script moves a message, and a retry
        // re-runs the move.
        let (output, error) = runJXA(script, retries: mutatingRetries)
        if let error { return errorResult(error) }
        switch scriptPayload(output) {
        case .failure(let message): return errorResult(message)
        case .object(let payload): return jsonResult(payload)
        case .text(let text): return textResult(text.isEmpty ? "email moved" : text)
        }
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
        // See `mutatingRetries`. Setting the flag twice is harmless in
        // itself, but a retried mutation is a habit rather than a judgement,
        // and the id this one binds by is no more guaranteed to still resolve
        // on the second run than the moved message's was.
        let (output, error) = runJXA(script, retries: mutatingRetries)
        if let error { return errorResult(error) }
        if case .failure(let message) = scriptPayload(output) { return errorResult(message) }
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
                "from": stringProp("Sender email address (overrides account lookup). Must be an address one of Mail's accounts sends as; an address no account owns is refused rather than substituted, because Mail's own behaviour is to send from the default account instead. The address the message actually went out as is reported back as `from`"),
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
                description: "List mailboxes. Groups by account when no account specified. Includes Mail's app-level mailboxes under the account name \"On My Mac\" — those belong to no account, and every mail tool accepts that name wherever an account is taken, so they can be scoped like any other. Nested folders are listed by their full path with / separators (Projects/Archive), because Mail reports leaf names for a flattened tree and one account can hold two mailboxes called Archive. Each string here is what identifies that mailbox and is accepted as mailbox, source_mailbox or target_mailbox by every other mail tool",
                inputSchema: schema(
                    properties: [
                        "account": stringProp("Account name, or \"On My Mac\" for Mail's local mailboxes (lists every account if omitted)")
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
                description: "Get the most recent emails (newest first) from matching mailboxes across accounts. Returns messages plus scan-coverage metadata (total_messages, truncated, messages_scanned, scanned/skipped mailboxes). Mailbox names in the result are paths (Projects/Archive), which is what identifies a mailbox and what you can pass straight back as mailbox/target_mailbox. excluded_mailboxes names what a mailbox 'all' scan deliberately left out — the accounts' own Trash, Junk, Drafts and Outbox — which are out of scope rather than unread, so they do not make scan_complete false. scan_complete says whether every mailbox in scope was actually read; when it is false the counts are a floor rather than a total and note says what was missed. A mailbox that changed while it was being read is reported in unstable_mailboxes and contributes no results, because the columns a scan reads arrive in separate calls and a mailbox that changes between them would pair one message's id with another message's subject. If that was the whole of the scope the call is an error rather than an empty result, because total_messages 0 would be a claim that the mailbox is empty",
                inputSchema: schema(
                    properties: [
                        "account": stringProp("Account name, or \"On My Mac\" for Mail's local mailboxes (scans every account and the local boxes if omitted)"),
                        "mailbox": stringProp("Mailbox to read, matched case-insensitively in every account and local On-My-Mac boxes (default: INBOX). A mailbox is named by its path: Mail reports leaf names for a flattened tree, so one account can hold two mailboxes called Archive and two called Trash. A bare name means the mailbox at the root of the account (Archive is the account's own Archive, never Projects/Archive); a nested one is named by its full path with / separators (Projects/Archive). A leaf name that only one mailbox in the account carries also works. mail_list_mailboxes lists these paths, and every mailbox reported back to you is one. Pass 'all' to scan every mailbox except the account's own junk/trash/drafts/outbox — those are named in excluded_mailboxes, and a nested folder that happens to be called Trash is ordinary mail and is scanned"),
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
                description: "Get full email by message ID, including the list of attachments (name, size, mime_type, mime_type_source). mime_type is the Content-Type the message itself declares, read from its raw source, so it agrees with mail_save_attachment; mime_type_source is \"declared\" for that, or \"filename\" when the source could not be read and the type had to be guessed from the extension. The message is checked against its own source, and the result reports fidelity (as mail_get_source does): when Mail has NOT finished downloading it, body, attachments and has_attachments are OMITTED rather than reported empty — an empty body and an empty attachment list from a half-downloaded message are answers a caller acts on — and the omitted field lists what was left out. Attachments the message declares but Mail does not list are included with listed_by_mail: false, because Mail's own list can stay empty for good for a message first read while it was still arriving, and mail_save_attachment reads the source rather than that list. source_check appears instead of fidelity when the source could not be read at all, in which case the body and attachments are Mail's unverified answer. structure reports what the MIME reader made of the source: parsed_complete is false when the message nests multipart parts deeper than macMCP descends (max_depth) or declares more parts than it reads (max_parts), and the attachment list is then short by whatever those parts contain rather than complete — a short list and a message with fewer attachments look identical without it. Searches all accounts when account omitted. Use mail_save_attachment to retrieve attachment contents",
                inputSchema: schema(
                    properties: [
                        "message_id": stringProp("Numeric message ID from mail_get_emails or mail_search, or an RFC Message-ID such as <abc@example.org> (use the RFC form for drafts, whose numeric id goes stale once the server syncs them)"),
                        "account": stringProp("Account name from results (optional, speeds up lookup)"),
                        "mailbox": stringProp("Mailbox to check first (default: INBOX); automatically falls back to searching all mailboxes. Matches a full path (Projects/Archive) or a leaf name")
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
                description: "Search emails by subject and sender, optionally recipients and body (case-insensitive). Scans every mailbox in every account by default, newest first. Returns matches plus scan-coverage metadata (total_matches, truncated, messages_scanned, scanned/skipped mailboxes). Mailbox names in the result are paths (Projects/Archive), which is what identifies a mailbox and what you can pass straight back as mailbox/target_mailbox. excluded_mailboxes names what a mailbox 'all' scan deliberately left out — the accounts' own Trash, Junk, Drafts and Outbox — which are out of scope rather than unread, so they do not make scan_complete false. scan_complete says whether every mailbox in scope was actually read; when it is false the counts are a floor rather than a total and note says what was missed. A mailbox that changed while it was being read is reported in unstable_mailboxes and contributes no results, because the columns a scan reads arrive in separate calls and a mailbox that changes between them would pair one message's id with another message's subject. If that was the whole of the scope the call is an error rather than an empty result, because total_matches 0 would be a claim that nothing matched",
                inputSchema: schema(
                    properties: [
                        "query": stringProp("Search query"),
                        "account": stringProp("Account name, or \"On My Mac\" for Mail's local mailboxes (searches every account and the local boxes if omitted)"),
                        "mailbox": stringProp("Mailbox to search (default: 'all' — every mailbox except the account's own junk/trash/drafts/outbox, which are named in excluded_mailboxes; a nested folder called Trash is ordinary mail and is searched). A mailbox is named by its path: Mail reports leaf names for a flattened tree, so one account can hold two mailboxes called Archive and two called Trash. A bare name means the mailbox at the root of the account (Archive is the account's own Archive, never Projects/Archive); a nested one is named by its full path with / separators (Projects/Archive). A leaf name that only one mailbox in the account carries also works. mail_list_mailboxes lists these paths, and every mailbox reported back to you is one"),
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
                description: "Send an email via Mail.app, optionally as HTML and with file attachments. The result reports rendered_chars: the length of the body Mail composed with all whitespace removed, so an 18-character body of \"just one line here\" reports 15. It exists to catch a body Mail rendered as empty, not to match the length of what was sent. Note: Mail rewrites the body of anything composed through its scripting interface — the delivered message carries the text inside <blockquote type=\"cite\">, so its text/plain alternative arrives with \"> \" on every line. This is Mail's own behaviour (a message typed by hand in Mail is unaffected, and plain AppleScript produces the same result), not something this tool can turn off. Use mail_create_draft, whose result reports body_check from the saved message, if you need to see what Mail actually produced. The result also reports from and account (the identity Mail actually sent as, read off the message) and autosaved_draft: Mail autosaves whatever it is composing, and this says whether that copy was found in Drafts and removed",
                inputSchema: composeSchema(action: "send from"),
                annotations: MCPAnnotations(readOnlyHint: false)
            ),
            category: cat,
            handler: sendEmail
        )

        registry.register(
            MCPTool(
                name: "mail_create_draft",
                description: "Create an email draft in Mail.app's Drafts folder, optionally as HTML and with file attachments. Does NOT send the email. Returns the saved draft's numeric and RFC message IDs so it can be read back with mail_get_email, plus body_check: the draft is re-read from the server and its text/plain part compared with the body that was asked for. rendered_chars is the length of the body Mail composed with all whitespace removed (an 18-character body of \"just one line here\" reports 15), and exists to catch a body Mail rendered as empty rather than to match the length of what was asked for. Mail rewrites the body of anything composed through its scripting interface, so expect body_check to report a mismatch — currently an empty text/plain part, with the body surviving only as HTML. The result also reports from and account (the identity Mail composed as, read off the message) and autosaved_draft: Mail autosaves whatever it is composing, and this says whether that extra copy was found in Drafts and removed — the draft you asked for is never touched by it",
                inputSchema: composeSchema(action: "save the draft in"),
                annotations: MCPAnnotations(readOnlyHint: false)
            ),
            category: cat,
            handler: createDraft
        )

        registry.register(
            MCPTool(
                name: "mail_save_attachment",
                description: "Save attachments from a received message to disk. Writes the files directly (Mail's own save is blocked by its sandbox). Saves every attachment when neither attachment_name nor index is given. The result reports fidelity for the message source the attachments were cut out of: Mail normalises CRLF to LF and turns any NUL into 0x80 before macMCP sees the bytes, so a part carried as 8bit or binary can reach disk altered in those two ways. A part carried as base64 or quoted-printable is unaffected. Refuses rather than writing a truncated file when Mail has not finished downloading the message — note that fidelity.message_size is null when Mail would not report the size, and completeness could then not be checked. The result also reports structure: parsed_complete is false when the message nests multipart parts deeper than macMCP descends (max_depth) or declares more parts than it reads (max_parts), in which case an attachment inside those parts is not in saved and not counted in attachments_in_message",
                inputSchema: schema(
                    properties: [
                        "message_id": stringProp("Numeric message ID from mail_get_emails or mail_search, or an RFC Message-ID"),
                        "destination": stringProp("Absolute POSIX path: a directory to save into (created if missing), or a full file path when saving a single attachment"),
                        "attachment_name": stringProp("Name of the attachment to save, as reported by mail_get_email (exact match preferred, substring accepted)"),
                        "index": intProp("Zero-based index of the attachment to save, as an alternative to attachment_name"),
                        "account": stringProp("Account name (optional, speeds up lookup)"),
                        "mailbox": stringProp("Mailbox to check first (default: INBOX); automatically falls back to searching all mailboxes. Matches a full path (Projects/Archive) or a leaf name"),
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
                description: "Get a message's raw RFC 822 source. Returns the first max_bytes by default, or writes the whole thing to save_to. An inline result reports source_encoding (utf-8, or iso-8859-1 for a source that is not valid UTF-8) and bytes_returned, which counts the bytes actually returned in that encoding — a truncation is moved back to a character boundary rather than cutting one in half. NOT byte-identical to the message on the server, so every result reports fidelity, measured over the WHOLE source (bytes_measured) rather than over the slice returned: line_endings is lf for every real message because Mail hands a source over with LF where the wire form has CRLF; ambiguous_nul_bytes counts bytes that are 0x80 where a NUL could have been lost, since Mail turns a NUL into 0x80 before macMCP sees it (a 0x80 inside a valid UTF-8 character is not counted, and base64 or quoted-printable parts are unaffected); complete says whether Mail had finished downloading the message — the fetch waits for it and reports a fragment as one rather than passing it off as the message — and complete_basis says what that rests on: \"bytes\" when the bytes reach message_size on their own, \"wire\" when they only reach it once each LF is counted as the CRLF it stood for (right for a server-side message, but a local draft is sized in LF units, so the note then says how many bytes would still be missing under that reading), \"short\" for a fragment, \"unchecked\" when Mail would not report a size, \"none\" for no bytes at all. message_size is Mail's own size, or null when Mail would not report it, in which case complete means \"nothing contradicts it\" rather than a verified match. Errors rather than returning an empty string when Mail has none of the message yet. Use mail_save_attachment instead when the goal is just to extract attachments",
                inputSchema: schema(
                    properties: [
                        "message_id": stringProp("Numeric message ID from mail_get_emails or mail_search, or an RFC Message-ID"),
                        "account": stringProp("Account name (optional, speeds up lookup)"),
                        "mailbox": stringProp("Mailbox to check first (default: INBOX); automatically falls back to searching all mailboxes. Matches a full path (Projects/Archive) or a leaf name"),
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
                        "source_mailbox": stringProp("Source mailbox to check first (default: INBOX); automatically falls back to searching all mailboxes. Matches a full path (Projects/Archive) or a leaf name"),
                        "target_mailbox": stringProp("Destination mailbox, resolved within the message's own account. A mailbox is named by its path: Mail reports leaf names for a flattened tree, so one account can hold two mailboxes called Archive and two called Trash. A bare name means the mailbox at the root of the account (Archive is the account's own Archive, never Projects/Archive); a nested one is named by its full path with / separators (Projects/Archive). A leaf name that only one mailbox in the account carries also works. mail_list_mailboxes lists these paths, and every mailbox reported back to you is one. If two mailboxes in the account carry the name and neither is at the root, the move is refused and both paths are named rather than one being guessed at"),
                        "account": stringProp("Account name to search for the message (optional, speeds up lookup)"),
                        "target_account": stringProp("Account to move the message INTO. Omit to keep it in its own account — which is almost always what you want, since every account has an Archive, Sent, Trash and Drafts. Setting this to another account uploads the message to that account and removes it from this one. That upload is a re-send of Mail's own copy, not a server-side move, so the bytes change: headers, content and RFC Message-Id survive, but the numeric message_id does not, line endings arrive as LF, and any NUL byte is lost — the same caveats mail_get_source reports as fidelity. Mail does fetch a message it holds only partially before uploading it, so nothing is truncated")
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
                        "mailbox": stringProp("Mailbox to check first (default: INBOX); automatically falls back to searching all mailboxes. Matches a full path (Projects/Archive) or a leaf name")
                    ],
                    required: ["message_id", "read"]
                )
            ),
            category: cat,
            handler: markRead
        )
    }
}
