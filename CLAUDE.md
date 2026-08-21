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

  Message bodies cost ~1.2s each individually *and* in bulk, so body search is a capped second pass (`body_scan_limit`), never a full scan. Scans run one `osascript` per account so a wedged account degrades to a `failed_accounts` entry instead of losing the request; per-mailbox processes would cost more in spawn overhead (~150ms each) than the scan itself.

- **Mail composition binds by id, then verifies.** The reference `mail.OutgoingMessage()` returns is not reliably the message `outgoingMessages.push()` added: with other compose messages present it can resolve to one of those instead. This shipped a real send to the recipient of an unrelated open window. Compose therefore re-finds the message by its read-only `id` in the live collection, sends invisibly (`visible: false` — a frontmost compose window is another thing Mail can act on in place of the script's reference), and reads the recipients and subject back off the message immediately before `send`/`save`, aborting on any mismatch. Note `close({saving: 'no'})` does *not* remove an entry from `outgoingMessages`; they accumulate until Mail restarts, which is why binding cannot rely on position or on the collection being empty.

- **Mail destinations resolve inside one account.** Every account owns an `Archive`, `Drafts`, `Sent`, `Trash` and `Junk`, so resolving a mailbox by name across all accounts returns whichever account Mail lists first — which has nothing to do with the message. `mail_move` therefore resolves `target_mailbox` inside `foundAccount` (where `findMessageJXA` located the message) and refuses rather than borrowing another account's mailbox of the same name; crossing an account boundary requires an explicit `target_account`. It then reads the message back out of the destination by RFC Message-ID, because `moved` on its own says nothing about where it went. Note the reference is dead the instant `msg.mailbox` is assigned — every property read on it afterwards raises "Invalid index" — so identifiers must be captured before the move, and the numeric id does not survive an IMAP re-file.

- **A mail timeout is checked against TCC before Mail is blamed.** A consent-blocked `osascript` is indistinguishable from a wedged Apple Event from the outside, and the old message answered both with "narrow the scope" — advice `mail_list_accounts` (empty input schema) cannot act on. `runJXAData` now takes the automation grant with `AEDeterminePermissionToAutomateTarget(..., askUserIfNeeded: false)` **before** running the script, and `scopable` says whether the calling tool has anything to narrow. The order matters: that check answers in ~10ms normally but **blocks while a consent prompt is on screen** (measured 12s and 73s, still blocked 20s after the script had been killed), so it is bounded by a 2s deadline and a blocked check is itself reported as a pending decision rather than as ignorance. `permissions_check` reports `automation (Mail)` for the same reason — it is the one TCC service macMCP hangs on rather than merely being refused by.

- **Mail escapes every non-ASCII character** as `\uXXXX` when generating JXA. The script reaches osascript as an `-e` argument, decoded using the process locale, and the MCP server's host need not set one — raw UTF-8 em dashes and Hebrew come out mangled. U+2028/U+2029 must go for a second reason: they terminate a JS string literal.

- **Mail's own attachment APIs are unusable.** `save` on a `mail attachment` fails with -10004 for every destination including `~/Downloads` (Mail's sandbox, not Full Disk Access), and the `MIME type` property raises "AppleEvent handler failed" on any message that has an attachment. `source` works, so `mail_save_attachment` fetches raw RFC 822 and decodes it in `MIME.swift`; types are inferred from the filename via `UTType`.

- **`source()` arrives one encoding layer removed.** Mail builds the string for `found.source()` by decoding the message's raw bytes as **ISO-8859-1**, and osascript writes that string to stdout as UTF-8, so every byte above 0x7F comes back UTF-8 double-encoded. `decodeSourceBytes` undoes it (UTF-8 in, Latin-1 out) and also drops the single newline osascript appends after any result. Both halves are guarded: invalid UTF-8, or a scalar above U+00FF (what a Mail that decoded the source *correctly* would emit), returns the bytes untouched rather than mangling them again. A NUL byte does not survive the text channel at all — it reaches stdout as U+0080 — and is not recoverable. Base64 attachments hid this for a long time because base64 is pure ASCII; the bug only shows on `Content-Transfer-Encoding: 8bit`.

- **Mail rewrites any body set through its scripting interface, and there is no way around it.** Whatever is given as `content` (or `html content`) arrives inside `<blockquote type="cite">` under Mail's `Apple-Mail-URLShareWrapperClass` scaffolding: a sent message's `text/plain` alternative gets `> ` on every line, and a saved draft's `text/plain` part comes out **empty**. Ruled out on Darwin 27 / Mail 16.0 (3864.500.181), each verified against the fixture's Maildir: setting the body at creation, setting it after `resolveOutgoingJXA`, `visible: true`, `html content`, injecting closing tags to escape the blockquote (WebKit rebalances them), `SendFormat = Plain` with a Mail restart, and textbook AppleScript `make new outgoing message with properties {content:…}` — which reproduces it exactly, so this is not something macMCP's compose path chose. A message **typed by hand** in Mail comes out as a clean single-part `text/plain`, so it is specific to the scripting path. `mailto:` compose windows never appear in `outgoing messages`, so that route cannot be driven; `content.paragraphs.push(…)` **kills osascript** (SIGKILL, no output). What is left is not to lie about it: `mail_create_draft` re-reads the saved draft and reports `body_check`, because `rendered_chars` is measured off `msg.content()` before Mail generates the alternatives and will happily report a plausible number for a message whose plain part is empty.

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

End-to-end checks against the local `testMail` fixture live outside this repo
(`~/source/barelyworkingcode/testMail`); the ground truth for anything mail-shaped
is the Maildir on disk, never a tool's own success return.

## Adding a Service

1. Create `Sources/macMCP/Services/FooService.swift`
2. Define `enum FooService` with `static func register(_ registry: ToolRegistry)`
3. Register tools using `registry.register(MCPTool(...)) { params in ... }`
4. Use `schema()`, `stringProp()`, `boolProp()`, etc. from `ToolRegistry` for input schemas
5. Return results via `textResult()`, `errorResult()`, or `jsonResult()`
6. Call `FooService.register(registry)` in `main.swift`
