# macMCP

Standalone Swift MCP server exposing macOS-native tools via stdio. 41 tools across 11 services. No external dependencies.

## Tools

### Calendar
| Tool | Description |
|------|-------------|
| `calendars_list` | List all calendars |
| `calendars_list_events` | List events within a date range |
| `calendars_create_event` | Create a new event |

### Contacts
| Tool | Description |
|------|-------------|
| `contacts_list` | Search or list contacts |
| `contacts_get` | Get a contact by identifier |
| `contacts_create` | Create a new contact |
| `contacts_update` | Update an existing contact |
| `contacts_delete` | Delete a contact |
| `contacts_list_groups` | List all contact groups |
| `contacts_create_group` | Create a contact group |
| `contacts_add_to_group` | Add a contact to a group |
| `contacts_remove_from_group` | Remove a contact from a group |
| `contacts_search_by_phone` | Search contacts by phone number |

### Reminders
| Tool | Description |
|------|-------------|
| `reminders_list` | List reminders, optionally filtered by list |
| `reminders_create` | Create a new reminder |
| `reminders_complete` | Mark a reminder as complete |

### Location
| Tool | Description |
|------|-------------|
| `location_get_current` | Get current coordinates |
| `location_geocode` | Address to coordinates |
| `location_reverse_geocode` | Coordinates to address |

### Maps
| Tool | Description |
|------|-------------|
| `maps_search` | Search for places or addresses |
| `maps_open` | Open a location in Apple Maps |
| `maps_get_directions` | Get directions URL between two points |

### Capture
| Tool | Description |
|------|-------------|
| `capture_screenshot` | Take a screenshot |
| `capture_audio` | Record audio from default input |

### Mail
| Tool | Description |
|------|-------------|
| `mail_list_accounts` | List configured mail accounts |
| `mail_list_mailboxes` | List mailboxes for an account |
| `mail_get_emails` | Get emails from a mailbox |
| `mail_get_email` | Get a single email with full body |
| `mail_search` | Search by subject or sender |
| `mail_send` | Send an email |
| `mail_move` | Move an email to another mailbox |
| `mail_mark_read` | Mark as read/unread |

### Messages
| Tool | Description |
|------|-------------|
| `messages_list_chats` | List recent conversations |
| `messages_get_chat` | Get messages from a chat |
| `messages_send` | Send an iMessage |

### Shortcuts
| Tool | Description |
|------|-------------|
| `shortcuts_list` | List available shortcuts |
| `shortcuts_run` | Run a shortcut by name |

### Utilities
| Tool | Description |
|------|-------------|
| `utilities_play_sound` | Play an audio file |

### Weather
| Tool | Description |
|------|-------------|
| `weather_current` | Current conditions for a location |
| `weather_forecast` | Daily forecast |
| `weather_hourly` | Hourly forecast |

## Requirements

- macOS 13+
- Swift 5.9+
- No external dependencies (system frameworks only)

### Permissions

Grant these in System Settings > Privacy & Security as needed:

- **Contacts** -- Contacts access
- **Calendar** -- Calendars access
- **Reminders** -- Reminders access
- **Location** -- Location Services
- **Messages** -- Full Disk Access (reads `chat.db` directly)
- **Mail** -- Automation permission for Mail.app (uses JXA)

## Build & Install

```bash
swift build              # debug
./build.sh               # release, codesigned, installs to ~/.local/bin, registers with Relay
```

`build.sh` installs the binary to `~/.local/bin/macmcp` and registers it with Relay (if installed).

## Configuration

### With Relay (recommended)

`build.sh` handles registration automatically. To register manually:

```bash
relay mcp register --name macMCP --command ~/.local/bin/macmcp
```

### Standalone

Add to your MCP client config (e.g. `claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "macmcp": {
      "command": "~/.local/bin/macmcp"
    }
  }
}
```

## Ecosystem

macMCP is part of the Relay ecosystem. Each project works independently, but together they provide LLMs with secure access to macOS.

- **[Relay](https://github.com/barelyworkingcode/relay)** -- MCP orchestrator. Proxies macMCP tools through token-authenticated connections with per-tool permissions.
- **[fsMCP](https://github.com/barelyworkingcode/fsmcp)** -- File system MCP server (read, write, edit, glob, grep, bash). Complements macMCP's macOS-native tools.
- **[Eve](https://github.com/barelyworkingcode/eve)** -- Browser-based LLM frontend.
- **[relayLLM](https://github.com/barelyworkingcode/relayLLM)** -- LLM engine service.
- **[relayScheduler](https://github.com/barelyworkingcode/relayScheduler)** -- Task scheduler for automated LLM prompts.

## Acknowledgements

Special thanks to [mattt/iMCP](https://github.com/mattt/iMCP) for the inspiration.
