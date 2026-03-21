# Protocol DX Improvements — Feature Analysis

> Branch: `ux/protocol-dx-improvements` (based on `feat/grpc-support`)
> Date: 2025-01-XX
> Author: Rishi

---

## Overview

This document analyzes the complete UI/UX overhaul of the WebSocket, MQTT, and gRPC response panes in API Dash. The previous chat-bubble interface was replaced with a professional, compact message-log view inspired by **Postman's WebSocket interface**, **MQTTX's topic management**, and **grpcui's method inspection**.

All three protocols now share a single `MessageLogView` widget (~1,100 lines) that provides a unified, professional experience across the application.

---

## Feature Matrix

| Feature | WebSocket | MQTT | gRPC | Implementation |
|---------|-----------|------|------|----------------|
| Compact message log | ✅ | ✅ | ✅ | `MessageLogView` widget |
| Full-text search | ✅ | ✅ | ✅ | `MessageLogToolbar` search field |
| Direction filter (All/Sent/Recv) | ✅ | ✅ | ✅ | `SegmentedButton<DirectionFilter>` |
| Topic filter | — | ✅ | — | `PopupMenuButton` dropdown |
| Topic color-coding | — | ✅ | — | 10-color auto-assigned palette |
| Payload format toggle | ✅ | ✅ | ✅ | Text / Pretty JSON / Hex / Base64 |
| Per-message copy | ✅ | ✅ | ✅ | `Clipboard.setData` on expand |
| Per-message bookmark | ✅ | ✅ | ✅ | Pin/unpin toggle |
| Resend message | ✅ | ✅ | — | Replays sent payload |
| Expand/collapse detail | ✅ | ✅ | ✅ | `MessageLogRow` tap to expand |
| Connection stats bar | ✅ | ✅ | ✅ | `ConnectionStatsBar` widget |
| Message export (JSON/CSV) | ✅ | ✅ | ✅ | `MessageExporter` utility |
| Keyboard: ⌘+Enter to send | ✅ | ✅ | ✅ | `CallbackShortcuts` on request pane |
| Keyboard: ⌘+L to clear | ✅ | ✅ | ✅ | `CallbackShortcuts` on response pane |
| Keyboard: ⌘+F to search | ✅ | ✅ | ✅ | Focus search field in `MessageLogView` |
| Saved message templates | ✅ | ✅ | — | `SavedMessagesPanel` widget |
| Auto-reconnect | ✅ | — | — | Exponential backoff in WsStateNotifier |
| Metadata toggle | — | — | ✅ | Collapsible headers/trailers section |
| Keyboard hint badge | ✅ | ✅ | ✅ | `⌘↵` text next to send button |

---

## Architecture

### Shared Components (`lib/widgets/message_log_view.dart`)

The entire message log system lives in one file with clear internal organization:

```
message_log_view.dart (~1,100 lines)
├── LogMessage              — Protocol-agnostic message model
├── MessageDirection        — Enum: sent, received, status, error
├── PayloadFormat           — Enum: text, prettyJson, hex, base64
├── DirectionFilter         — Enum: all, sent, received
├── MessageLogToolbar       — Search + filter + export + clear + count
├── _DirectionFilterChips   — SegmentedButton for direction filtering
├── _TopicFilterDropdown    — PopupMenuButton for MQTT topic filtering
├── ConnectionStatsBar      — Status dot + timer + msg count + bytes
├── MessageLogRow           — Compact single-line log entry
├── _ExpandedDetail         — Detail panel with format toggle + actions
├── _FormatChip             — Inline chip for format selection
├── MessageLogView          — Main composable StatefulWidget
├── SavedMessageTemplate    — Model for saved message templates
├── SavedMessagesPanel      — Slide-out panel for saved templates
└── MessageExporter         — JSON/CSV export utility
```

### Protocol → LogMessage Conversion Pattern

Each protocol-specific response pane converts its native message model to `LogMessage`:

**WebSocket:**
```dart
LogMessage(
  content: wsMessage.content,
  direction: switch (wsMessage.type) {
    WsMessageType.sent     => MessageDirection.sent,
    WsMessageType.received => MessageDirection.received,
    WsMessageType.error    => MessageDirection.error,
    _                      => MessageDirection.status,
  },
  timestamp: wsMessage.timestamp,
)
```

**MQTT:**
```dart
LogMessage(
  content: mqttMessage.payload,
  direction: mqttMessage.isPublished
      ? MessageDirection.sent
      : MessageDirection.received,
  timestamp: mqttMessage.timestamp,
  label: mqttMessage.topic,          // Shows as colored chip
  badge: mqttMessage.qos.label,      // Shows as "QoS 0" etc.
  retained: mqttMessage.retained,     // Shows orange "Retained" tag
  topicColor: _colorForTopic(topic), // Auto-assigned from palette
)
```

**gRPC:**
```dart
// Each GrpcCallResult produces:
// 1. Status LogMessage (direction: status or error)
// 2. One LogMessage per response message (direction: received)
// 3. Error LogMessage if result.error != null
```

### Auto-Reconnect (`lib/providers/ws_providers.dart`)

The `WsStateNotifier` now supports automatic reconnection with exponential backoff:

- **State fields:** `autoReconnect` (bool), `reconnectAttempt` (int)
- **Maximum attempts:** 5 before giving up
- **Backoff formula:** `min(2^attempt, 30)` seconds
- **Behaviour:** On disconnect/error → schedule reconnect → show status message → retry
- **Cancel triggers:** Manual `disconnect()`, `setAutoReconnect(false)`, or widget disposal
- **Status messages:** Each attempt adds a visible log entry ("Auto-reconnect: attempt 2 in 4s…")

### Keyboard Shortcuts

| Shortcut | Context | Action |
|----------|---------|--------|
| `⌘+Enter` / `Ctrl+Enter` | Request pane (all protocols) | Send message / Publish / Invoke |
| `⌘+L` / `Ctrl+L` | Response pane (all protocols) | Clear all messages |
| `⌘+F` / `Ctrl+F` | Message log view | Focus search field |

---

## Files Changed

### New Files
| File | Lines | Description |
|------|-------|-------------|
| `lib/widgets/message_log_view.dart` | ~1,100 | Shared message log widget system |

### Modified Files
| File | Change | Description |
|------|--------|-------------|
| `lib/widgets/widgets.dart` | +1 line | Added export for `message_log_view.dart` |
| `lib/screens/.../ws_response_pane.dart` | Rewritten | Chat bubbles → MessageLogView + ConnectionStatsBar |
| `lib/screens/.../mqtt_response_pane.dart` | Rewritten | Chat bubbles → MessageLogView with topic colors |
| `lib/screens/.../grpc_response_pane.dart` | Rewritten | Card layout → MessageLogView + metadata toggle |
| `lib/screens/.../request_pane_ws.dart` | Modified | Added ⌘+Enter shortcut + keyboard hint |
| `lib/screens/.../request_pane_mqtt.dart` | Modified | Added ⌘+Enter shortcut + keyboard hint |
| `lib/screens/.../request_pane_grpc.dart` | Modified | Added ⌘+Enter shortcut + keyboard hint |
| `lib/providers/ws_providers.dart` | Enhanced | Added auto-reconnect with exponential backoff |

### Net Change
- **+2,228 lines** added, **–841 lines** removed
- **10 files** changed total

---

## Design Decisions

### 1. Single shared widget vs. per-protocol widgets
**Decision:** One `MessageLogView` widget shared across all three protocols.
**Rationale:** Consistent UX across protocols, reduce code duplication (~3x less code), easier to maintain. Protocol-specific features (topics, QoS badges, retained tags) handled via optional `LogMessage` fields.

### 2. Compact log rows vs. chat bubbles
**Decision:** Compact single-line rows like Postman/MQTTX.
**Rationale:** Higher information density, better scannability, supports search/filter natively. Chat bubbles waste horizontal space and don't scale to high message volumes.

### 3. Reverse-chronological listing
**Decision:** `ListView.builder(reverse: true)` — newest messages at top.
**Rationale:** Matches Postman, VS Code terminal, and browser DevTools behaviour. Users care about the latest messages first.

### 4. Topic color auto-assignment (MQTT)
**Decision:** 10-color palette, assigned per unique topic in arrival order.
**Rationale:** Matches MQTTX's approach. Stable within a session but not persisted — deliberate to keep the state lightweight.

### 5. Payload format toggle per-message
**Decision:** Each expanded message has its own format state (Text/JSON/Hex/Base64).
**Rationale:** Users often need different formats for different messages in the same session. JSON pretty-print with graceful fallback to raw text for non-JSON.

### 6. gRPC flattened log vs. card-per-call
**Decision:** Flatten each `GrpcCallResult` into individual log entries with a collapsible metadata toggle above.
**Rationale:** Consistent with WS/MQTT message log UX. Headers/trailers shown on demand. Better for streaming calls where multiple response messages should be individually searchable.

---

## Comparison with Professional Tools

### vs. Postman WebSocket
- ✅ Same compact log layout with direction indicators
- ✅ Same search and filter
- ✅ Added: payload format toggle (Postman lacks this)
- ✅ Added: bookmarking (Postman lacks this)

### vs. MQTTX
- ✅ Topic-based color coding
- ✅ Topic filtering
- ✅ QoS and retained badges
- ✅ Added: full-text search across payloads (MQTTX lacks this)
- ✅ Added: export to JSON/CSV (MQTTX only exports via file)

### vs. grpcui
- ✅ Visual status indicators per call
- ✅ Metadata (headers/trailers) displayed
- ✅ Added: searchable message log (grpcui lacks this)
- ✅ Added: payload format toggle (grpcui only shows raw or JSON)

---

## Performance Considerations

- **ListView.builder with reverse:** Only builds visible rows. Efficient for 10,000+ messages.
- **Search:** Filters on `setState` — O(n) per keystroke. For very large message volumes (>50k), could add debouncing or indexed search. Acceptable for typical usage.
- **Topic color map:** O(1) lookup per message. Palette cycles after 10 unique topics.
- **Export:** Builds full JSON/CSV in memory. For extreme message volumes, could stream to file instead.
