# BlueBubbles Daemon

Swift/Vapor daemon for macOS that reads the Messages database (`chat.db`), sends messages via AppleScript, and exposes a local HTTP API for the Node.js bridge.

## What it does

- **Reads** chats and messages from `~/Library/Messages/chat.db`
- **Sends** messages using AppleScript (Messages.app)
- **Exposes** HTTP API at `http://127.0.0.1:8081` for the Node.js bridge
- **Polls** for new messages and pushes them over SSE
- **Contacts** from the system Address Book (optional vCard export)

## Requirements

- macOS 12 or newer
- Swift 5.9+ (Xcode or swift.org toolchain)
- **Full Disk Access** for the process that runs the daemon (Terminal or the binary)

## Setup

1. Grant **Full Disk Access** to Terminal (or the app that will run the daemon):  
   System Settings → Privacy & Security → Full Disk Access
2. Open **Messages.app** at least once for the current user so `~/Library/Messages/chat.db` exists

## Configuration

Edit `Sources/BlueBubblesDaemon/Utils/Config.swift`:

| Setting          | Default                    | Description                    |
|------------------|----------------------------|--------------------------------|
| `httpHost`       | `"127.0.0.1"`             | Bind address                   |
| `httpPort`       | `8081`                    | HTTP port                      |
| `messagesDBPath` | `~/Library/Messages/chat.db`| Messages database path (computed from home dir) |
| `pollInterval`   | `1.0`                     | New-message poll interval (s)  |
| `logLevel`       | `"info"`                  | `trace` / `debug` / `info` / `warning` / `warn` / `error` |

## Build and run

**Development:**

```bash
swift build
swift run bluebubbles-daemon
```

**Release:**

```bash
swift build -c release
.build/release/bluebubbles-daemon
```

**Run as a service (launchd):**  
Use the provided `com.bluebubbles.daemon.plist` and point `WorkingDirectory` and executable path to your build.

## HTTP API

Base URL: **`http://127.0.0.1:8081`**

### Health

| Method | Path      | Description |
|--------|-----------|-------------|
| GET    | `/ping`   | 200 OK      |
| GET    | `/health` | JSON: status, timestamp, databaseAccessible, uptime |

### Chats

| Method | Path                    | Description |
|--------|-------------------------|-------------|
| GET    | `/chats`                | List all chats |
| GET    | `/chats/:chatGuid`      | Single chat by GUID (404 if not found) |
| GET    | `/chats/:chatGuid/messages` | Messages for chat. Query: `limit` (default 50), `before` (optional timestamp) |

**Chat GUID:** Use the exact `guid` from `GET /chats` (e.g. `SMS;-;+13108771635`). If the path contains `;` or `+`, URL-encode: `;` → `%3B`, `+` → `%2B`.  
Example: `GET /chats/SMS%3B-%3B%2B13108771635/messages?limit=10`

### Messages & updates

| Method | Path                    | Description |
|--------|-------------------------|-------------|
| GET    | `/messages/updates`     | New messages, typing, read receipts since `since`. Query: `since` (ms since Unix epoch or Apple nanoseconds; values &lt; 10¹⁵ treated as ms) |
| GET    | `/attachments/:guid/info` | Attachment metadata only |
| GET    | `/attachments/:guid`    | Stream attachment file (Content-Type, Content-Disposition set; Range supported) |

### Statistics

| Method | Path                    | Description |
|--------|-------------------------|-------------|
| GET    | `/statistics/totals`    | JSON: `handles`, `messages`, `chats`, `attachments`. Query: `only` (comma-separated subset, e.g. `only=messages,chats`) |
| GET    | `/statistics/media`     | JSON: `images`, `videos`, `locations`. Query: `only` (comma-separated subset) |

### Send & actions

| Method | Path           | Body | Description |
|--------|----------------|------|-------------|
| POST   | `/send`        | `{ "chat_guid": "...", "text": "...", "temp_guid?", "attachment_paths?" }` | Send message (AppleScript) |
| POST   | `/typing`      | `{ "chat_guid": "...", "is_typing": true/false }` | Typing indicator |
| POST   | `/read_receipt`| `{ "chat_guid": "...", "message_guids": ["..."] }` | Mark messages read; returned once in `GET /messages/updates` |

### Contacts

| Method | Path              | Description |
|--------|-------------------|-------------|
| GET    | `/contacts`       | List contacts. Query: `limit`, `offset`, `extraProperties` (e.g. `avatar`) |
| GET    | `/contacts/vcf`   | Contacts as vCard string |
| GET    | `/contacts/changed` | JSON: `lastChanged` timestamp (Unix seconds, for polling) |

### Events (SSE)

| Method | Path     | Description |
|--------|----------|-------------|
| GET    | `/events`| Server-Sent Events: `connected`, `contacts_updated`, `new_message` (sent and incoming) |

## Implementation notes

- **Messages by chat:** The daemon resolves the chat by GUID to a `chat.ROWID`, then queries messages by that integer to avoid string-binding issues with GUIDs containing `;` and `+`.
- **Updates:** `GET /messages/updates` scans all chats; typing is acknowledged in memory; read receipts are stored in memory and returned once on the next poll.
- **Auth:** Not enforced by default; daemon is intended to listen on localhost and be used only by the Node.js bridge.

## Related

- **Node.js bridge:** `../BlueBubbles-Compatible Python Bridge` (talks to this daemon on port 8081)
- **curl examples:** See workspace `CURL_TEST_COMMANDS.md` for copy-paste test commands
