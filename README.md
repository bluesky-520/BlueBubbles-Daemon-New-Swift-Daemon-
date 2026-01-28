# BlueBubbles Daemon

Swift/Vapor daemon for macOS that reads the Messages database, sends messages
via AppleScript, and exposes a local HTTP API for the Node.js bridge.

## What it does

- Reads chats and messages from the local Messages database.
- Sends messages using AppleScript.
- Provides a local HTTP API for the bridge at `http://127.0.0.1:8081`.
- Polls for new messages on a short interval.

## Requirements

- macOS 12 or newer.
- Swift 5.9 toolchain (Xcode or swift.org toolchain).
- Full Disk Access for the daemon or the terminal you run it from.

## Setup

1. Grant Full Disk Access to the terminal app or the compiled daemon binary.
2. Ensure Messages.app has been opened at least once for the current user.

## Configuration

Settings live in `Sources/BlueBubblesDaemon/Utils/Config.swift`:

- `httpHost` / `httpPort` (default `127.0.0.1:8081`)
- `messagesDBPath` (default `~/Library/Messages/chat.db`)
- `pollInterval` (seconds)
- `logLevel`

## Build and run

Development build:

```
swift build
swift run BlueBubblesDaemon
```

Release build:

```
swift build -c release
.build/release/bluebubbles-daemon
```

## HTTP API

Base URL: `http://127.0.0.1:8081`

Health:

- `GET /ping` → HTTP 200
- `GET /health` → status, timestamp, database availability, uptime

Chats:

- `GET /chats` → list chats
- `GET /chats/:chatGuid` → chat details
- `GET /chats/:chatGuid/messages?limit=50&before=TIMESTAMP`

Messages:

- `GET /messages/updates?since=TIMESTAMP` → new messages since timestamp

Send:

- `POST /send` → `{ chat_guid, text }`
- `POST /typing` → `{ chat_guid, is_typing }`

## Notes and limitations

- The updates endpoint currently scans all chats per request and returns empty
  typing/read-receipt arrays.
- Authentication is not enforced by default; this daemon is intended to be bound
  to localhost and used by the Node.js bridge.

## Related projects

- Node.js bridge: `../BlueBubbles-Compatible Python Bridge`
