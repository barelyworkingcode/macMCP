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

  **Columns from one mailbox must be checked for alignment before they are paired.** Each is a separate Apple Event and the scan walks them by index, so a mailbox that changes between two of them pairs one message's id with another message's subject — and the id is the handle `mail_move`, `mail_mark_read` and `mail_get_email` act on. Mail orders the collection by date received, so an arrival is spliced into the *middle*: moving a message into Alice's INBOX between two fetches produced `ids=9 subjects=10` with the new message at index 8 of 10, i.e. row 8 carrying id 412 under subject "Contract 2024-118". It is not theoretical — a scan run while a probe was arriving handed `mail_get_source` an id whose message measured 405 bytes against the probe's 300599. The scan therefore re-reads the id column after the others and requires it to come back identical (plus every column being the same length), retries the mailbox up to three times, and reports it in `unstable_mailboxes` with no rows rather than guessing. Cost is one extra id column fetch per mailbox, the cheapest of them.

  Message bodies cost ~1.2s each individually *and* in bulk, so body search is a capped second pass (`body_scan_limit`), never a full scan. Scans run one `osascript` per account so a wedged account degrades to a `failed_accounts` entry instead of losing the request; per-mailbox processes would cost more in spawn overhead (~150ms each) than the scan itself.

- **Mail composition binds by id, then verifies.** The reference `mail.OutgoingMessage()` returns is not reliably the message `outgoingMessages.push()` added: with other compose messages present it can resolve to one of those instead. This shipped a real send to the recipient of an unrelated open window. Compose therefore re-finds the message by its read-only `id` in the live collection, sends invisibly (`visible: false` — a frontmost compose window is another thing Mail can act on in place of the script's reference), and reads the recipients and subject back off the message immediately before `send`/`save`, aborting on any mismatch. Note `close({saving: 'no'})` does *not* remove an entry from `outgoingMessages`; they accumulate until Mail restarts, which is why binding cannot rely on position or on the collection being empty.

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

  **Mail's attachment list is not authoritative even after the message arrives.** The severed message's list stayed empty *permanently* once the download finished (`mailAttachments()` = 0 against a 400574-byte source declaring one), while `mail_save_attachment` extracted the attachment byte-exactly. The list is therefore reconciled with the message source, and anything the source declares that Mail does not list is added with `listed_by_mail: false`. Inline parts are excluded — Mail deliberately does not list a body image, and turning `has_attachments` true for every HTML message with a logo would be a new wrong answer in place of the old one.

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

  Two edges of that. **Zero bytes is not a message** — severing the fixture's IMAPS
  proxy mid-fetch produces exactly that, `source()` returning `''` for a message
  Mail sizes at 400595 — so an empty source is never `complete`, is waited for even
  when `messageSize` could not be read, and `mail_get_source` errors rather than
  returning `"source": ""` with `truncated: false`. And **`messageSize` raising is
  not evidence of anything**: `complete` is then "nothing contradicts it" rather
  than a verified match, which `fidelity.message_size: null` and the note both say,
  since that is the one path left by which a fragment could pass for a message.

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
