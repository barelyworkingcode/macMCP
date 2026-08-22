# macMCP

Standalone Swift MCP server exposing macOS-native tools via stdio. 46 tools across 12 services. No external dependencies.

## Architecture

Single-threaded stdin/stdout MCP server. Newline-delimited JSON-RPC 2.0. Protocol version `2024-11-05`.

```
main.swift           Stdin loop, JSON-RPC dispatch (initialize, tools/list, tools/call)
JSONRPCTypes.swift   Wire types, JSONValue enum, MCPTool, result helpers
ToolRegistry.swift   Tool registration map + JSON schema builder helpers
Services/            One file per service, each a caseless enum namespace
```

Entry point initialises `NSApplication` (`.prohibited` -- no dock icon) for macOS TCC permission support, then reads stdin line-by-line, dispatches to `ToolRegistry`, writes JSON to stdout. No async, no concurrency -- all async APIs bridged synchronously via `CFRunLoopRunInMode`.

## Services

| Service | Tools | Backend |
|---------|-------|---------|
| Calendar | 3 | EventKit `EKEventStore` |
| Contacts | 10 | `CNContactStore` |
| Reminders | 3 | EventKit `EKEventStore` |
| Location | 3 | CoreLocation (RunLoop-pumped, 15s timeout) |
| Maps | 3 | `CLGeocoder` + `NSWorkspace` URL schemes |
| Capture | 2 | `/usr/sbin/screencapture`, `/usr/bin/afrecord` |
| Mail | 11 | JXA via `/usr/bin/osascript -l JavaScript` |
| Messages | 3 | SQLite3 on `~/Library/Messages/chat.db` (read), AppleScript (send) |
| Shortcuts | 2 | `/usr/bin/shortcuts` CLI |
| Utilities | 1 | `/usr/bin/afplay` |
| Weather | 3 | `api.open-meteo.com` (free, no key) |
| Web | 1 | `URLSession` (http/https GET, 1 MB cap) |

## Key Patterns

- **Service = caseless enum** with `static register(_ registry: ToolRegistry)` and private static handlers `(JSONObject?) -> MCPCallResult`.
- **Sync-over-async** -- `CFRunLoopRunInMode` pumps the main RunLoop to deliver callbacks synchronously. All async APIs (EventKit, CoreLocation, CLGeocoder, URLSession, CNContactStore) use this pattern. Semaphores are not used because `NSApplication.shared` routes completions through the main RunLoop, which semaphores would deadlock.
- **Permissions re-requested** on every tool call. macOS caches the grant, so this is idempotent.
- **No throws across service boundary** -- all errors returned as `MCPCallResult(isError: true)`.
- **Messages reads require Full Disk Access** (direct SQLite on `chat.db`).
- **Mail uses JXA** because Mail.app has no public framework API. String escaping is manual.
- **Mail reads must use bulk column fetches.** `mbox.messages.subject()` costs one Apple Event per column per mailbox regardless of message count (~0.07ms/message; 14k subjects in ~1s). Three things are forbidden in a read path, all measured against a 14,004-message mailbox:
  - `messages[i].prop()` in a loop — resolving one element is O(mailbox size), ~13ms on a small mailbox and ~150ms on a large one.
  - specifier `.slice()` — resolves element by element; 200 ids took 22s while all 14,004 took 1s.
  - `whose()` — an internal linear scan, ~10x slower than fetching the column and filtering in JS. `whose({content: ...})` decodes every body and times out on ~251 messages.

  **Columns from one mailbox must be checked for alignment before they are paired.** Each is a separate Apple Event and the scan walks them by index, so a mailbox that changes between two of them pairs one message's id with another message's subject — and the id is the handle `mail_move`, `mail_mark_read` and `mail_get_email` act on. Mail orders the collection by date received, so an arrival is spliced into the *middle*: moving a message into Alice's INBOX between two fetches produced `ids=9 subjects=10` with the new message at index 8 of 10, i.e. row 8 carrying id 412 under subject "Contract 2024-118". It is not theoretical — a scan run while a probe was arriving handed `mail_get_source` an id whose message measured 405 bytes against the probe's 300599. The scan therefore re-reads the id column after the others and requires it to come back identical (plus every column being the same length). Cost is one extra id column fetch per mailbox, the cheapest of them.

  **Detection is a trigger, not a verdict — the rows are recoverable one message at a time.** The check used to discard the whole mailbox, report it in `unstable_mailboxes` after three attempts, and (single-account scope) turn that into an error. Measured under sustained IMAP delivery into Alice's INBOX, 8 scans each: **5 of 8 refused with `total_messages: 0`**, i.e. ~11,800 readable rows thrown away to avoid a mispairing that affects at most the rows after the splice — and Mail's collection is newest-first, so an arrival splices at index 0 and shifts *every* index, which is why no prefix salvage works. What the columns cannot be trusted about is the **pairing**; the ids arrived in a single Apple Event and are not in doubt. So on divergence each of the `<= limit` rows actually being returned is re-bound with `messages.byId(id)` and asked for its own subject, sender, date and read state, and for where it is (`byId` resolves globally, so a row is **dropped** rather than relabelled if the message has left the mailbox it is stamped with). The mailbox is named in `changed_mailboxes` with `rows_reverified` / `rows_dropped`. Same 8 scans, same delivery rate, after: **8 of 8 returned 20 verified rows** with a correct `total_messages`, each row's id/subject pairing confirmed through the independent `mail_get_email` path. Cost is nothing on a quiet mailbox (0.90s vs 0.90s) and ~75ms per returned row when it fires (2.0s -> 3.5s at limit 20). A wall-clock budget (20s per account scan) caps the pathological case, past which a changed mailbox goes back to being reported as unread.

  **A search's count is the one thing the salvage cannot recover**, because the match is decided against the very columns shown not to line up: a row that really matches can be filtered out under its neighbour's subject and never reach the re-read. Every row returned is still verified, so nothing returned is wrong — but `scan_complete` is false for a filtered scan over a changed mailbox, which is exactly what that flag means everywhere else.

  **A scan that read nothing is an error, not an empty result.** `total_messages: 0` beside `isError: false` is an affirmative claim that a mailbox holding thousands of messages is empty, and a caller who does not know to read the coverage fields cannot tell the two apart. When no mailbox in scope could be read the call refuses and says so; a partial read still returns its rows, with `scan_complete` (reported unconditionally, true or false) and a `note` saying the counts are a floor. **Every reason is named, in one sentence.** The refusal used to have a branch per cause, so a scan where one account timed out *and* one mailbox would not hold still reported only the mailbox and never mentioned the timeout; and `no mailbox named "X"` — a claim about every account in scope — was returned flatly with part of that scope unread, before the payload, so `failed_accounts` and `note` were never emitted either. `skipped_mailboxes` now carries **why**, the way `failed_accounts` always has: `catch (err) { skipped.push(label) }` read the label and threw the error away, and "gone" and "Mail was busy" are not the same answer.

  **The body-search sweep is a second scan and reports its own coverage.** `mail_search`'s body pass runs `scanAllAccounts` again over the same scope and used to read only `rows` and `total` from it — `skipped`, `failed` and `changed` were discarded and `scanFailure` was never applied. A sweep that read nothing contributed no candidates *and* nothing to its own total, so `rows.count >= total` was satisfied **by** the failure and the answer came out `body_scan_complete: true, bodies_read: 0, body_matches: 0`: the completeness test passed because it was never reached. `body_scan_complete` now includes `sweep.scanComplete`, and `body_search` carries `body_scan_skipped_mailboxes` / `body_scan_failed_accounts` / `body_scan_changed_mailboxes` / `body_scan_note` separately from the metadata scan's, because the two are reads of the same scope at two moments and either can fall short alone.

  Message bodies cost ~1.2s each individually *and* in bulk, so body search is a capped second pass (`body_scan_limit`), never a full scan. Scans run one `osascript` per account so a wedged account degrades to a `failed_accounts` entry instead of losing the request; per-mailbox processes would cost more in spawn overhead (~150ms each) than the scan itself.

- **A JXA specifier is not the object it resolves to, and a positional one is a bug.** `mail.accounts()`, `acct.mailboxes()` and `mbox.messages()` all hand back specifiers indexed by **position**, and JXA re-evaluates a specifier on *every* property access rather than snapshotting. `found = mbox.messages[k]` therefore means "whatever is at position k right now": bind it, let one message leave the mailbox, and the same variable answers for a different message — no error, no warning. Measured on the fixture at ~3,000 messages under continuous delivery, `mail_get_email` was wrong in **26 of 60** calls, and in 18 of those it returned the right id, the right subject and the right `rfc_message_id` beside **another message's body** — a shape nothing in the response lets a caller detect. The exposure is the whole call, not a gap between two reads. Four places had it (#50): `findMessageJXA`, the body-scan pass, `mail_create_draft`'s find-back, and the mailbox collection itself.

  The fix is to bind by something that identifies the element. `messages.byId(n)` re-resolves by id, so it answers for the same message or raises, and it is **cheaper** than what it replaced: ~11ms on a 3,887-message mailbox against 54ms for the id column, and 28ms for `messages[i]`. Two things about it, both measured against Mail 16:
  - **`byId` resolves globally.** An id from Bob's INBOX resolves through Alice's, or through `mail.inbox`, or through a local On-My-Mac box. So a numeric lookup needs no mailbox enumeration at all — and the account/mailbox in the answer has to come off the message (`msg.mailbox.name()`, `msg.mailbox.account.name()`; the `account` read raises for a local mailbox, which is how On My Mac is told apart), not off whatever was searched. Any scoping the caller asked for is then checked against that, because the search no longer enforces it.
  - **An RFC Message-ID cannot be resolved that way.** That path still reads a column to translate the header value into a numeric id, then binds by that id and asks the bound message for its own `messageId()`. A message answering for itself is what makes it sound; no alignment guard is needed.
  - **A re-bind is only as good as the scope check on it.** Because `byId` is global, every place that binds by id has to read the account *and* the mailbox back off the message. `findMessageJXA` always did (`fmLocate`/`fmInScope`, account matched case-insensitively); the body-scan pass compared the mailbox **name** alone, and every account has an `INBOX` — so a message that moved `Alice:INBOX` -> `Bob:INBOX` between the metadata scan and the body pass passed the check and had its body returned under a row saying `"account": "Alice"`. Both halves are now read through one shared `mbWhere`/`mbSamePlace`, which the scan's per-row re-verification uses too.

  **A leaf name does not identify a mailbox; the path does.** Mail flattens an account's mailbox tree and reports leaf names, so `acct.mailboxes.name()` can return `["Archive","Projects","Sub","Archive",…]` — two different mailboxes called `Archive` (top-level and `Projects/Archive`) — and Mail enumerates **children before parents with the special mailboxes last**, so "the first match" is systematically the nested one. Every tool resolved, labelled and excluded a mailbox by that name, and each was a different way of guessing between two: `mail_move` to `"Archive"` filed into `Projects/Archive` and to `"Trash"` into `R4-PROBE-Deep/Trash` (a "delete this" left undeleted in a project folder) both reporting `verified: true`, because the read-back looked in the mailbox the pick had chosen; `mailbox: "all"` dropped any folder anywhere in the tree whose leaf name was Trash/Junk/Drafts, 35 messages reported against 38 on disk with `scan_complete: true` and `skipped_mailboxes: []`.

  The identity is the **path** — container leaf names, outermost first, joined with `/` — and it is Mail's own, not a label invented here. Measured against Mail 16.0 on the fixture (Bob, 33 mailboxes, 4 deep):
  - `mailboxes.byName('Projects/Archive')` **resolves**, so a path is a *handle*, not just a label. All 33 paths resolved, including names with quotes, apostrophes, spaces, ampersands, emoji and Hebrew, and including the nested ones whose leaf name does not (`byName('Sub')` for `Archive/Sub` is `exists()` false).
  - `byName('Archive')` resolves to the **top-level** one, so **a bare name is a path with one component**. That is the whole resolution rule: `Trash` means the account's Trash rather than `Projects/Trash`, and the special mailbox wins over a same-named user folder because it is at the root, not by a special case. A leaf name is then a *fallback* used only when exactly one mailbox carries it (so `Sub` still reaches `Archive/Sub`); two carriers is **refused with both paths named**, because filing into one of two is a coin toss the response cannot show.
  - `/` cannot occur inside a leaf name: creating a mailbox called `a/b` produces a mailbox `b` inside a mailbox `a`. So paths are unambiguous and siblings are unique.
  - It is **cheaper than what it replaced**. Containers come back as bulk columns — `mailboxes.container.name()`, then `.container.container.name()`, until a level is entirely null — one Apple Event per level for the whole collection. Measured: **7 Apple Events / 113ms** against **25 / 415ms** for the old bulk-name + `collection()` + per-name `exists()` probe. `mbPathOf` walks a single already-resolved mailbox (a message saying where it is) at one Apple Event per level plus one; the container of a top-level mailbox answers `name()` with **null** rather than raising, which is the stop condition.

  `boundByName` reads the name column, the container columns and (only when it must fall back to positional specifiers) the elements, then **re-reads the name column and requires it identical** — the message scan's guard, one level up, closing the ~400ms window in which a mailbox created or deleted mid-read stamped rows with another mailbox's name or dropped one from every list. The `exists()` probes that used to sit *inside* that window are gone: there is exactly **one** per collection, on the deepest unique path, saying whether this Mail resolves paths at all, and a Mail that does not degrades the whole collection to positional specifiers rather than losing it. A collection that will not hold still across three attempts yields entries with **no element**, which the caller's own filter then reports as `unstable` — so what is named is the mailboxes in scope, not every mailbox the account holds.

  Everything a caller sees is the path: `mail_list_mailboxes`, every row's `mailbox`, `moved_from`, and `mail_move`'s destination — each of which is accepted back as `mailbox`/`source_mailbox`/`target_mailbox`. `mail_move` also reads the bound destination's own path back with `mbPathOf` and refuses **before** the move if it is not what the request resolved to: the old read-back looked inside the mailbox the pick had chosen, so it could only ever confirm *where the message was put*, never *where the caller asked*. `all` excludes on identity (top-level only) and names what it left out in `excluded_mailboxes` — deliberately **not** in `skipped_mailboxes`, because those are out of scope rather than unread and a `scan_complete` that is false for every `all` scan says nothing, the same reason `mail_get_source`'s `exact` boolean was removed.

- **Mail composition binds by id, then verifies.** The reference `mail.OutgoingMessage()` returns is not reliably the message `outgoingMessages.push()` added: with other compose messages present it can resolve to one of those instead. This shipped a real send to the recipient of an unrelated open window. Compose therefore re-finds the message by its read-only `id` in the live collection, sends invisibly (`visible: false` — a frontmost compose window is another thing Mail can act on in place of the script's reference), and reads the recipients, the subject **and the sender** back off the message immediately before `send`/`save`, aborting on any mismatch. The abort names the field that differed: it used to render the two recipient lists whatever the mismatch was, so a subject carrying a CR (Mail normalises it to a space, correctly tripping the guard) aborted with two *identical* recipient lists printed side by side — the scariest false positive this guard can raise. Note `close({saving: 'no'})` does *not* remove an entry from `outgoingMessages`; they accumulate until Mail restarts, which is why binding cannot rely on position or on the collection being empty.

- **A `from` no account owns is refused, not substituted.** Mail does not reject an unknown sender — it sends from the default account instead — so `from: "nosuch@relaytest.local"` returned `{"status": "sent"}` and went out as `From: Alice Tester <alice@relaytest.local>`, Return-Path `alice@`, filed in Alice's Sent. A caller asking to send as one identity sent as another, with nothing in the response saying so and the message already gone. The address is now checked against every account's `emailAddresses()` (which is every address an account can send as, aliases included) **before** `mail.OutgoingMessage` exists, so a rejected sender composes nothing at all — and the refusal lists the addresses that would have worked. Validating up front is the request, though, not the evidence: the pre-send guard also reads `msg.sender()` back and aborts on a mismatch, exactly as it does for a recipient. Both compose results now carry `from` and `account`, read off the message rather than off the request, which is the only thing that says which identity a call with neither argument used.

- **Compose owns the draft Mail writes behind its back.** Mail autosaves whatever it is composing. A message typed by hand has that copy removed when its window closes; `visible: false` plus a scripted `send()` meant the close never happened, so **every** send left a permanent full copy — body, recipients, subject, `X-Apple-Auto-Saved: 1` — in the sending account's Drafts: three copies on disk per send, Alice's Drafts going 13 → 14 → 15 across two sends, in a folder `mailbox: "all"` excludes so no tool here would have shown a caller it happened. Four things measured against Mail 16.0 on the fixture decide the shape of the fix, and none of them is guessable:
  - `send()` and `save()` each clear the autosaved copy that exists at that moment, and Mail writes a **new** one a few seconds later for the message that is still open — the leaked draft's own `Date` header was 7s *after* the sent copy's. **Closing stops that**, and closing immediately after the send is the whole of the fix for the success path: two sends, then three more, left Drafts unchanged. The gap is what matters — putting the Drafts check *between* the send and the close, about a second of Apple Events, was enough to let the copy through again, once for Alice and once for Bob.
  - `close({saving: 'no'})` prevents a further autosave but does **not** delete one already written. So an abort, which already closed, still leaks.
  - **Deleting the copy of a message Mail is still holding makes Mail write another** — 3s later in one run, 12s in another, 15s in a third. An abort that deleted what it found reported "that copy has been moved to Trash" and took Drafts from 21 to 22: one in Trash and a fresh one in Drafts, where doing nothing leaves exactly one. `mail.delete` on the outgoing message does not help, nor does setting it visible and closing it. `send()` is the only thing that ends Mail's interest in the message, so a leftover is removed only after one; everywhere else it is reported. There is a second reason not to delete on an abort: the guard fires because what Mail is holding is not what was asked for, which is the worst possible moment to delete on the strength of having identified something.
  - A draft saved on purpose carries no `X-Apple-Auto-Saved` header and an autosaved one always does (checked across the fixture's 22 drafts), which is what keeps `mail_create_draft`'s own draft — new since the snapshot, same subject — out of the sweep's hands.

  `autosaved_draft` is reported unconditionally on both compose tools, because a leaked draft is invisible to every other tool here and "there was none" has to be distinguishable from "nobody looked". The identity is three-part — an id that was not in that account's Drafts before the compose message was created (the snapshot is taken first for that reason), this message's subject, and the header — and the subject matched is the one **Mail** holds, not the one that was asked for: matching only on the request found nothing for a CR-in-subject abort and reported a leak as a clean abort. What an abort says now is what is there — never that nothing was saved. An abort is the one path that hands the message to Mail neither by sending it nor by saving it, so Mail keeps the compose message (`close` does not remove it from `outgoingMessages`) and autosaves it whenever its timer next comes round: under a second on a Mail that has been running a while, and **30 seconds** on one just relaunched, which is long enough for the check to look, find nothing, and say so truthfully about a copy that then appears. Sending and saving both do release the message — five sends and a 114-second watch on a saved draft produced no copy at all — so `found: 0` on a success is a finished answer and only the abort has to hedge.

- **A mutating script is never re-run.** `runJXAData` retries by running the *whole* script again, and `mail_move` and `mail_mark_read` were on the default of 2 — so a `-1728` raised after `found.mailbox = destMbox` had executed re-ran the move. Same-account that is only wasteful; across accounts the move is a re-upload, the numeric id does not survive it, so the retry's `findMessageJXA` returns null and the caller is told "message not found with id: N" for a move that succeeded. Both now pass `mutatingRetries` (0), which is what `mail_send` and `mail_create_draft` have always passed.

- **`On My Mac` is an account name every mail tool accepts.** Mail's app-level mailboxes belong to no account, and the scan has always labelled their rows `On My Mac:<mailbox>` — but `mail_list_mailboxes` enumerated `mail.accounts()` only, so a caller could be handed a row from a mailbox the one enumeration tool said did not exist. Naming it was only half: `resolveTargets` passed the string through to a scope lookup that walks `mail.accounts()`, so `account: "On My Mac"` threw `account not found`. It now maps to the local pass (`nil`) everywhere, `findMessageJXA` exempts it from the account-existence check, and the listing carries it as an entry whether or not there are any local boxes (#54). Relay's resource scoping cannot scope what the enumeration does not name, and naming something that then cannot be asked for is worse than not naming it. Note the listing shows nested folders by **leaf name**, so one account really can show two mailboxes called `Archive`.

- **Mail destinations resolve inside one account.** Every account owns an `Archive`, `Drafts`, `Sent`, `Trash` and `Junk`, so resolving a mailbox by name across all accounts returns whichever account Mail lists first — which has nothing to do with the message. `mail_move` therefore resolves `target_mailbox` inside `foundAccount` (where `findMessageJXA` located the message) and refuses rather than borrowing another account's mailbox of the same name; crossing an account boundary requires an explicit `target_account`. It then reads the message back out of the destination by RFC Message-ID, because `moved` on its own says nothing about where it went. Note the reference is dead the instant `msg.mailbox` is assigned — every property read on it afterwards raises "Invalid index" — so identifiers must be captured before the move, and the numeric id does not survive an IMAP re-file.

- **A cross-account move is a re-upload of Mail's copy**, not a server-side move, and `target_account` says so. Measured against the fixture's Maildir: a 254-byte-value probe moved between accounts arrives at the destination **byte-for-byte identical to what `mail_get_source` returns** for it — LF line endings, the NUL gone — which is the proof that Mail uploads what it holds rather than asking the servers to copy. Headers (including `Return-Path`), content and the RFC `Message-Id` all survive; the numeric id does not. A 2 MB message Mail held only as `271.partial.emlx` (headers only) was uploaded **in full**, so a partial download is not a truncation risk. An earlier report of dropped `Delivered-To`-class headers did not reproduce: the 11-byte delta it described is what CRLF→LF accounts for on a message with 11 line breaks, and the destination copy matched the source header for header once line endings were normalised.

- **A script that throws is reported as the sentence it threw.** osascript wraps a
  thrown value in its own text -- `execution error: Error: Error: account "Alice" has
  no mailbox named "BobOnly" (-2700)`, doubled `Error:` and an OSStatus included --
  and that reached callers verbatim from every path that refuses by throwing:
  `mail_move`'s missing destination mailbox, and `account not found` from
  `mail_move`, `mail_mark_read`, `mail_get_email` and `mail_get_source`.
  `scriptErrorMessage` unwraps it in `runJXAData`, so scripts stay free to throw
  (the natural thing from inside an IIFE) and every one of them, including ones
  written later, comes out in the same voice as `{error: ...}` results. Only
  `-2700` is unwrapped -- that is osascript's code for "the script threw", so the
  text is ours; `-1712`, `-1728` and syntax errors keep their raw form because the
  number is the evidence. **Which code it is is read at the position osascript
  writes it** -- the trailing ` (-NNNN)` -- never searched for in the text.
  Everything before that position is the message, and a message contains whatever
  the caller passed in: `mail_move` on a mailbox named `Q (-1712) box` reported
  "Mail timed out evaluating the request (-1712)" while the script had thrown
  `no mailbox named "Q (-1712) box"`, and `-1728` in a name bought two silent
  retries.

- **A mail timeout is checked against TCC before Mail is blamed.** A consent-blocked `osascript` is indistinguishable from a wedged Apple Event from the outside, and the old message answered both with "narrow the scope" — advice `mail_list_accounts` (empty input schema) cannot act on. `runJXAData` now takes the automation grant with `AEDeterminePermissionToAutomateTarget(..., askUserIfNeeded: false)` **before** running the script, and `scopable` says whether the calling tool has anything to narrow. The order matters: that check answers in ~10ms normally but **blocks while a consent prompt is on screen** (measured 12s and 73s, still blocked 20s after the script had been killed), so it is bounded by a 2s deadline and a blocked check is itself reported as a pending decision rather than as ignorance. `permissions_check` reports `automation (Mail)` for the same reason — it is the one TCC service macMCP hangs on rather than merely being refused by.

- **A revoked Apple Events grant cannot be restored by putting the database back.**
  Learned during #7, and expensive: after a consent prompt was left to time out,
  tccd had written a **deny** row (`auth_value=0`, `auth_reason=9`) for the client,
  and it re-asserted that row over a restored copy of `TCC.db` **twice**. Copying
  the file back, even with tccd stopped, does not converge — the daemon's own view
  wins. What worked was raising a **fresh prompt** and approving it (`vmallow`
  watches for it; the prompt is owned by UserNotificationCenter, not by Mail or by
  the requesting app). So: never test consent by letting a prompt expire, and if a
  grant does go missing, re-prompt rather than reach for the database. Note also
  that ad-hoc signing pins a grant to the cdhash, so rebuilding Relay revokes
  macMCP's grants and they have to be re-granted through Relay > Settings > MCP
  Servers > macMCP > Reset Permissions. Verify functionally (`mail_list_accounts`
  returning accounts), not by reading a status field.

- **Mail escapes every non-ASCII character** as `\uXXXX` when generating JXA. The script reaches osascript as an `-e` argument, decoded using the process locale, and the MCP server's host need not set one — raw UTF-8 em dashes and Hebrew come out mangled. U+2028/U+2029 must go for a second reason: they terminate a JS string literal.

- **Mail's own attachment APIs are unusable.** `save` on a `mail attachment` fails with -10004 for every destination including `~/Downloads` (Mail's sandbox, not Full Disk Access), and the `MIME type` property raises "AppleEvent handler failed" on any message that has an attachment. `source` works, so `mail_save_attachment` fetches raw RFC 822 and decodes it in `MIME.swift` — and `mail_get_email` now takes its `mime_type` from the same place, so the two agree. The filename guess (`UTType`) survives only as a fallback, and `mime_type_source` says which one a caller is looking at: guessing from the extension reported `text/csv` for a part the message declares as `image/png; name="data.csv"`. A failed fetch leaves the guess in place rather than costing the caller the message.

  The fetch used to be skipped when Mail listed no attachments, which is exactly what a message Mail has not finished downloading looks like: `content()` returns `''` and `mailAttachments()` returns `[]`, without complaint. Severing the fixture's IMAPS proxy mid-fetch produced `body: ""`, `has_attachments: false`, `attachments: []` and no error for a 400 KB message carrying one attachment — beside a correct `message_size: 400595` in the same response. So `mail_get_email` now checks every message against its own source and **withholds negatives it cannot stand behind**: an empty body and an empty attachment list are omitted (listed in `omitted`, with `fidelity` saying why) rather than returned as `""` and `false`. Positive evidence — a partial body, an attachment Mail has already listed — is kept.

  **Mail's attachment list is not authoritative even after the message arrives.** The severed message's list stayed empty *permanently* once the download finished (`mailAttachments()` = 0 against a 400574-byte source declaring one), while `mail_save_attachment` extracted the attachment byte-exactly. The list is therefore reconciled with the message source, and anything the source declares that Mail does not list is added with `listed_by_mail: false`. Inline parts are excluded — Mail deliberately does not list a body image, and turning `has_attachments` true for every HTML message with a logo would be a new wrong answer in place of the old one. Note Mail's own list does **not** honour that rule (it listed a `Content-Disposition: inline` logo, and a CID-only PNG as "Mail Attachment.png"), so inline-ness is read off the message and never off whether Mail listed it.

- **There is one attachment list, and both tools work from it.** `mail_get_email` used to report Mail's `mailAttachments()` rows with source-declared extras appended, while `mail_save_attachment` indexed `MIME.attachments(of:)` straight — different membership, different order, different names, with `attachment_name` documented as "as reported by mail_get_email". On a probe carrying an HTML body, a CID-only inline PNG and a `report.txt`: `mail_get_email` said `[report.txt, Mail Attachment.png]`, `index: 0` **wrote the inline body image** and reported success, and `attachment_name: "Mail Attachment.png"` — the name just handed to the caller — was rejected outright, naming two names it had never shown (#R2-2). `MailService.attachmentList` is now the single source: derived from the message, in document order, inline parts split off. `index` is an index into it, `attachment_name` is one of its names, and an unqualified save writes exactly what `mail_get_email` listed. An inline part is still reachable, by `part_path` and only by `part_path`, so a caller who wants the logo can have it without every HTML message growing an attachment.

- **The identity of an attachment is its MIME part path, not its filename.** `mail attachment.id` is the part's position in the message — `2`, `3`, `1.2`, the numbering IMAP `BODYSTRUCTURE` uses. Measured on Mail 16: three attachments of a flat `multipart/mixed` came back `2`, `3`, `4`; an inline image inside a `multipart/related` that is part 1 of a `multipart/mixed` came back `1.2` in a message four levels deep. Reconciling on the **filename** instead emitted one part as **two attachments** whenever Mail rendered the name differently from the header, and the Mail-derived copy lost the declared type for one guessed off the extension — `text/csv` for a part headed `image/png`, which is verbatim the bug `mime_type_source` exists to prevent (#R4-4). Four independent triggers, all confirmed live and all fixed: an escaped quote in a quoted-string filename (`MIME.parse` stripped the quotes without undoing `\"`; `MIME.unquote` now does, and `splitOutsideQuotes` always handled escapes, so only the unquote was missing); a raw non-ASCII filename, where Mail returns its own Latin-1 mojibake — verified through plain JXA, so macMCP is relaying Mail faithfully and no decoding here will ever make the two strings equal; no `filename` parameter at all, where Mail invents "Mail Attachment" and the source has nothing to invent from; and a "/" in the filename, which Mail sanitises and the source keeps. A position is not a rendering of anything, so none of the four moves it. Name and size survive as later passes for a Mail that reports no id, and the size pass takes a match only when exactly one unclaimed part has that size. What the *result* reports is the message's name (that is the handle) with Mail's under `mail_name` when they differ (that is a label), and a row Mail lists that matches no part goes to `attachments_mail_lists_only` rather than being turned into an attachment with no bytes behind it.

- **A half-written save says what it wrote.** `mail_save_attachment` returned a bare error sentence on the first failed write and discarded the `saved` array, so files already on disk were invisible to the caller who had just been told the call failed (#R2-5). The failure is still a failure — `isError` stays true — but it now carries `saved` and a count.

- **`source()` arrives one encoding layer removed.** Mail builds the string for `found.source()` by decoding the message's raw bytes as **ISO-8859-1**, and osascript writes that string to stdout as UTF-8, so every byte above 0x7F comes back UTF-8 double-encoded. `decodeSourceBytes` undoes it (UTF-8 in, Latin-1 out) and also drops the single newline osascript appends after any result. Both halves are guarded: invalid UTF-8, or a scalar above U+00FF (what a Mail that decoded the source *correctly* would emit), returns the bytes untouched rather than mangling them again. Base64 attachments hid this for a long time because base64 is pure ASCII; the bug only shows on `Content-Transfer-Encoding: 8bit`.

- **A fetched source is still not byte-identical to the message, and says so.** Measured against the fixture's Maildir with a message carrying every byte value except CR/LF: 253 of 254 round-trip, but **a NUL comes back as `0x80`** and **every CRLF comes back as LF** (890 bytes on disk, 869 returned, 21 CRs gone, one `0x00` arriving as `0x80`). Both happen inside Mail — plain JXA emits NUL and CR fine, Swift's UTF-8/Latin-1 round trip preserves them, and Mail's own `.emlx` copy already holds 0 CRs and 0 NULs — so nothing here can undo them. `sourceFidelity` reports them instead, as a `fidelity` object on `mail_get_source` (both the inline and `save_to` paths) and on `mail_save_attachment`. The NUL case is *ambiguous*, not merely lossy: a returned `0x80` is either a real `0x80` or a lost NUL, so the count of candidates is reported rather than a claim about which — but **only a `0x80` that is not a UTF-8 continuation byte counts**, because Mail's replacement for a NUL always lands standalone and an em dash (`E2 80 94`) is not one. Counting every `0x80` reported three lost NULs for a body whose only sin was typography. `source_encoding` is not the place for this — it describes how the inline string was encoded for return, exists only on that path, and a source can be valid `utf-8` and still be missing a NUL.

  There is deliberately **no summary boolean**. `exact` used to be one (complete + CRLF + no `0x80`); Mail strips every CR, so it was false for every real message — including one whose fetched bytes matched the copy on disk exactly — and true only for data the pipeline cannot produce. What the object carries is facts that can go either way (`complete`, `line_endings`, `ambiguous_nul_bytes`, `bytes_measured`, `message_size`) plus a `note`, and the counts say they were measured over the whole source rather than over whatever slice `max_bytes` returned.

- **`source()` returns what Mail has downloaded so far.** For a message still
  arriving that is the headers and a fragment: 838 bytes of a 300 KB message in
  one measurement, with `truncated` (which describes the `max_bytes` slice) saying
  `false`. Every consumer of the raw source inherits it — a truncated attachment on
  disk, a `mime_type` guessed from a filename, a `body_check` against a body that
  has not arrived. The fetch therefore reads `messageSize` (a bulk column, one
  Apple Event, giving the **wire** size) and waits, up to 10s, for
  `source.count + LF count == messageSize` — exact rather than heuristic, because
  every LF in a returned source stands for one CRLF on the wire. What is left is
  reported: `fidelity.complete`, and `mail_save_attachment` refuses rather than
  cutting a file out of a fragment. The size travels back on a `MACMCP-SIZE:<n>`
  line ahead of the source, stripped only when it matches exactly, because the
  source itself is raw bytes on stdout and a second osascript spawn would cost more
  than the fetch.

  **`messageSize` is quoted in one of two units and Mail does not say which.** A message the server holds is quoted in **wire** units — 375 bytes with 19 line breaks reported as 394. A **local draft** is quoted in the units Mail stores it in: `bytes_measured: 1362` against `message_size: 1362`, matching the Maildir's `S=1362` and not its `W=1395`. Counting every LF as a CRLF is what makes the first case come out right and is exactly what hands the second slack: a 1362-byte draft passes at `1362 + 33 >= 1362`, and so would a fragment of it 33 bytes short. `complete_basis` says which reading `complete` rests on — `bytes` when the bytes reach the size on their own (assuming nothing), `wire` when they only reach it once each LF is counted, plus `short`, `unchecked`, `none` — and the note quantifies the slack in the `wire` case. Requiring an exact match on one of the two readings would close the hole and is deliberately not done: it turns any imprecision in `messageSize` into a permanent false `incomplete`, which costs a caller `mail_save_attachment` entirely (#53).

  Two edges of that. **Zero bytes is not a message** — severing the fixture's IMAPS
  proxy mid-fetch produces exactly that, `source()` returning `''` for a message
  Mail sizes at 400595 — so an empty source is never `complete`, is waited for even
  when `messageSize` could not be read, and `mail_get_source` errors rather than
  returning `"source": ""` with `truncated: false`. And **`messageSize` raising is
  not evidence of anything**: `complete` is then "nothing contradicts it" rather
  than a verified match, which `fidelity.message_size: null` and the note both say,
  since that is the one path left by which a fragment could pass for a message.

- **The MIME reader is bounded, and says where it stopped.** Nesting is chosen by
  the sender, and `MIME.parse` used to recurse with no depth bound: a 929 KB
  message nested ~13,000 `multipart/mixed` levels deep exhausted the 8 MB
  main-thread stack and killed macmcp with **signal 11** — no response, no error,
  and all 46 tools gone with it, macmcp being one synchronous stdin loop.
  Reachable from `mail_get_email` *and* `mail_save_attachment`, both of which
  parse raw source; `mail_get_source` was unaffected because it does not parse.
  Measured against the release build: 13,000 levels survived, 40,000 exited 139.
  The parse is now **iterative over an explicit work list** rather than
  recursive-with-a-counter — one descent, one place the limits live, and stack
  usage that does not vary with depth — with `attachments(of:)` and
  `firstPlainTextPart` rewritten the same way, since each was a second walk over
  the same sender-chosen depth. Three ceilings, all reported: `maxDepth` 32
  (`multipart/signed` over `mixed` over `related` over `alternative` over
  `text/html` is the deepest real shape at 5, and forward chains add none because
  nothing descends into `message/rfc822`), `maxParts` 10,000, and
  `maxHeaderBytes` 256 KB (a message with no blank line is all headers on
  purpose, which is what lets a sender make the header block the whole message).
  A part past the cap is **kept unparsed rather than dropped or invented**, and
  `structure` — `parsed_complete`, `parts`, `depth`, plus a note — rides on
  `mail_get_email` and `mail_save_attachment` beside `fidelity`, because the
  visible effect of a limit is a *shorter attachment list*, which is
  indistinguishable from a message with fewer attachments. `mail_save_attachment`
  refuses rather than reporting "has no attachments" for a message it could not
  read to the bottom. Note the cap is not a stack guard any more; it bounds work,
  since every level holds its own copy of the bytes below it.

- **`MACMCP-SIZE:` is macMCP's own line and is always at offset 0.**
  `sourceScriptJXA` writes it before a single byte of the message on every path,
  so `splitSourceSizeMarker` failing *open* — leaving the line in the bytes when
  the value on it did not parse — could never have protected a caller's own first
  line, which is never at offset 0. What it did instead was put
  `MACMCP-SIZE:null` into `save_to` files, `bytes_total`, `sourceFidelity`'s
  counts, and `MIME.parse` as a bogus `macmcp-size:` header. It now fails closed:
  the line is stripped whatever is on it, `-1` is accepted because the script
  writes it itself (the documented "`messageSize()` raised"), and any other value
  is an error naming what was seen — the wait that decides whether the whole
  message arrived ran against that same value, so nothing can say whether the
  bytes are the message or a fragment.

- **Mail rewrites any body set through its scripting interface, and there is no way around it.** Whatever is given as `content` (or `html content`) arrives inside `<blockquote type="cite">` under Mail's `Apple-Mail-URLShareWrapperClass` scaffolding: a sent message's `text/plain` alternative gets `> ` on every line, and a saved draft's `text/plain` part comes out **empty**. Ruled out on Darwin 27 / Mail 16.0 (3864.500.181), each verified against the fixture's Maildir: setting the body at creation, setting it after `resolveOutgoingJXA`, `visible: true`, `html content`, injecting closing tags to escape the blockquote (WebKit rebalances them), `SendFormat = Plain` with a Mail restart, and textbook AppleScript `make new outgoing message with properties {content:…}` — which reproduces it exactly, so this is not something macMCP's compose path chose. A message **typed by hand** in Mail comes out as a clean single-part `text/plain`, so it is specific to the scripting path. `mailto:` compose windows never appear in `outgoing messages`, so that route cannot be driven; `content.paragraphs.push(…)` **kills osascript** (SIGKILL, no output). What is left is not to lie about it: `mail_create_draft` re-reads the saved draft and reports `body_check`, because `rendered_chars` is measured off `msg.content()` before Mail generates the alternatives and will happily report a plausible number for a message whose plain part is empty. `rendered_chars` also counts **whitespace-stripped** characters — `"just one line here"` reports 15, not 18 — which is right for the question it answers ("did Mail render anything visible") and wrong for the one a caller is likely to ask it ("is this my body's length"), so both compose schemas now say which it is.

- **HTML bodies use `html content`,** which Mail's dictionary marks hidden and "does nothing at all (deprecated)" but which in fact still renders (verified on Darwin 27 — produces `multipart/alternative` with a Mail-generated plain-text part). It wins over `content` when both are set, so only one is ever sent. Compose checks the rendered body and errors rather than silently shipping an empty message if a future Mail makes good on the deprecation.

## Build

```bash
swift build              # debug
./build.sh               # release, codesigned, installs to ~/.local/bin, registers with Relay
```

Requires Swift 5.9+, macOS 13+. System frameworks only: EventKit, Contacts, CoreLocation, Foundation, SQLite3, AppKit. The binary embeds an `Info.plist` via `-sectcreate` for macOS permission prompts (Location Services).

## Tests

```bash
swift test
```

`Tests/macMCPTests` tests the executable target directly (`@testable import macmcp`),
so anything under test has to be at least `internal` — several Mail helpers are
deliberately not `private` for that reason, and say so at their declaration.

The suite must stay hermetic: **no test may talk to Mail.app, the network, or the
user's own data.** Two patterns make that possible for a service that is mostly
generated JavaScript:

- **`JXA.run`** executes a script through `osascript -l JavaScript` with `mail`
  bound to `MailStubJS`'s fake object graph instead of `Application('Mail')`.
  Nothing calls `Application(...)`, so no Apple Event is sent and no TCC prompt
  can appear — osascript is just a JavaScript engine. This is how the generated
  scripts themselves (which is where the real logic lives) get tested.
- **Pure seams.** Byte-level behaviour that used to be inline in a handler —
  source decoding, truncation, attachment typing, the timeout message — is
  factored into small `static` functions that take data and return data, so the
  regression can be pinned without a mailbox.

The one exception is `MailSourceOnDiskTests`, which is in the suite and has to
be: byte-identity claims cannot be substantiated by a test that synthesises its
own input with the transform under test, which is how two real deviations went
unnoticed for a release. It skips with instructions unless pointed at the
fixture, and needs Mail.app and an Automation grant:

```bash
cd ~/source/barelyworkingcode/testMail && ./testmail.sh start
MACMCP_MAIL_FIXTURE=$HOME/source/barelyworkingcode/testMail \
    swift test --filter MailSourceOnDiskTests
```

It delivers a message carrying every byte value except CR/LF straight into the
Maildir, fetches it back through `mail_get_source`, compares the bytes with the
file on disk, and moves the probe to Trash afterwards. ~5s.

Other end-to-end checks against the fixture live outside this repo
(`~/source/barelyworkingcode/testMail`); the ground truth for anything mail-shaped
is the Maildir on disk, never a tool's own success return.

## Adding a Service

1. Create `Sources/macMCP/Services/FooService.swift`
2. Define `enum FooService` with `static func register(_ registry: ToolRegistry)`
3. Register tools using `registry.register(MCPTool(...)) { params in ... }`
4. Use `schema()`, `stringProp()`, `boolProp()`, etc. from `ToolRegistry` for input schemas
5. Return results via `textResult()`, `errorResult()`, or `jsonResult()`
6. Call `FooService.register(registry)` in `main.swift`
