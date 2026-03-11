# macMCP

Standalone Swift MCP server exposing macOS-native tools via stdio. 41 tools across 11 services. No external dependencies.

## Architecture

Single-threaded stdin/stdout MCP server. Newline-delimited JSON-RPC 2.0. Protocol version `2024-11-05`.

```
main.swift           Stdin loop, JSON-RPC dispatch (initialize, tools/list, tools/call)
JSONRPCTypes.swift   Wire types, JSONValue enum, MCPTool, result helpers
ToolRegistry.swift   Tool registration map + JSON schema builder helpers
Services/            One file per service, each a caseless enum namespace
```

Entry point reads stdin line-by-line, dispatches to `ToolRegistry`, writes JSON to stdout. No async, no concurrency -- all async APIs bridged via `DispatchSemaphore`.

## Services

| Service | Tools | Backend |
|---------|-------|---------|
| Calendar | 3 | EventKit `EKEventStore` |
| Contacts | 10 | `CNContactStore` |
| Reminders | 3 | EventKit `EKEventStore` |
| Location | 3 | CoreLocation (semaphore, 15s timeout) |
| Maps | 3 | `CLGeocoder` + `NSWorkspace` URL schemes |
| Capture | 2 | `/usr/sbin/screencapture`, `/usr/bin/afrecord` |
| Mail | 8 | JXA via `/usr/bin/osascript -l JavaScript` |
| Messages | 3 | SQLite3 on `~/Library/Messages/chat.db` (read), AppleScript (send) |
| Shortcuts | 2 | `/usr/bin/shortcuts` CLI |
| Utilities | 1 | `/usr/bin/afplay` |
| Weather | 3 | `api.open-meteo.com` (free, no key) |

## Key Patterns

- **Service = caseless enum** with `static register(_ registry: ToolRegistry)` and private static handlers `(JSONObject?) -> MCPCallResult`.
- **Sync-over-async** -- semaphores bridge EventKit/CoreLocation/URLSession to synchronous. Safe because single-threaded.
- **Permissions re-requested** on every tool call. macOS caches the grant, so this is idempotent.
- **No throws across service boundary** -- all errors returned as `MCPCallResult(isError: true)`.
- **Messages reads require Full Disk Access** (direct SQLite on `chat.db`).
- **Mail uses JXA** because Mail.app has no public framework API. String escaping is manual.

## Build

```bash
swift build              # debug
./build.sh               # release, codesigned, installs to ~/.local/bin, registers with Relay
```

Requires Swift 5.9+, macOS 13+. System frameworks only: EventKit, Contacts, CoreLocation, Foundation, SQLite3.

## Adding a Service

1. Create `Sources/macMCP/Services/FooService.swift`
2. Define `enum FooService` with `static func register(_ registry: ToolRegistry)`
3. Register tools using `registry.register(MCPTool(...)) { params in ... }`
4. Use `schema()`, `stringProp()`, `boolProp()`, etc. from `ToolRegistry` for input schemas
5. Return results via `textResult()`, `errorResult()`, or `jsonResult()`
6. Call `FooService.register(registry)` in `main.swift`

## Ecosystem

macMCP is part of the Relay ecosystem. It complements fsMCP's file system tools with macOS-native capabilities.

- `../relay/` -- MCP orchestrator. Proxies macMCP tools through token-authenticated connections with per-tool permissions.
- `../fsMCP/` -- TypeScript MCP server with 6 file system tools. Complements macMCP's macOS-native tools.
