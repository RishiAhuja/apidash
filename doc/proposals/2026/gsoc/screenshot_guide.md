# Screenshot Guide — Protocol DX Improvements

> Use this guide to capture screenshots for the GSoC proposal.
> Each screenshot has precise instructions on what to show, where to draw red rectangles, and what text annotations to add.
> Tool recommendation: macOS Screenshot (⌘+Shift+4) + Preview.app for annotations.
> Red rectangle: 2-3px stroke, bright red (#FF0000), no fill.

---

## Setup Before Taking Screenshots

1. Run the app: `flutter run -d macos`
2. Resize window to ~1400×900 for consistent framing
3. Use **light theme** for primary screenshots (add dark theme variants if desired)
4. Pre-populate with test data:
   - WebSocket: Connect to `wss://echo.websocket.org` or local echo server, send 5-8 messages
   - MQTT: Connect to `test.mosquitto.org:1883`, subscribe to `test/topic1` and `test/sensor/temp`, publish a few messages
   - gRPC: Connect to a local gRPC server (or the grpcbin demo), invoke a method with a response

---

## Screenshot 1: WebSocket — Message Log Overview

**What to show:** Full application window with a WebSocket request active, showing the message log with multiple sent/received messages.

**Setup:**
- Connect to a WebSocket echo server
- Send 5+ messages of varying lengths (including a JSON payload)
- Have at least 1 message expanded to show the detail panel

**Red rectangles + annotations:**

| # | Rectangle Location | Annotation Text |
|---|---|---|
| 1 | Around the `ConnectionStatsBar` (top bar with green dot, duration, msg count) | "Live connection stats — status, uptime, message count, total bytes" |
| 2 | Around the search field in the toolbar | "Full-text search across all message payloads" |
| 3 | Around the `SegmentedButton` (All / Sent / Recv) | "Direction filter — instantly filter by sent or received" |
| 4 | Around one compact log row (showing ↑ icon, timestamp, payload preview) | "Compact log row — direction icon, timestamp, payload preview, size" |
| 5 | Around the expanded detail panel (format chips + payload + copy button) | "Expand any message — format toggle, copy, bookmark, resend" |

---

## Screenshot 2: WebSocket — Payload Format Toggle

**What to show:** An expanded message with the format chips visible, showing Pretty JSON formatting.

**Setup:**
- Send a JSON message like `{"sensor": "temp", "value": 23.5, "unit": "celsius"}`
- Click on the message row to expand it
- Click "PRETTYJSON" format chip

**Red rectangles + annotations:**

| # | Rectangle Location | Annotation Text |
|---|---|---|
| 1 | Around the 4 format chips (TEXT / PRETTYJSON / HEX / BASE64) | "Payload format toggle — view as text, pretty JSON, hex dump, or base64" |
| 2 | Around the formatted JSON output (indented with syntax) | "Auto-formatted JSON with proper indentation" |
| 3 | Around the copy/bookmark/resend icons | "Quick actions — copy to clipboard, bookmark, resend" |

---

## Screenshot 3: WebSocket — Keyboard Shortcut Hint

**What to show:** The request pane bottom bar with the Send button and the ⌘↵ hint.

**Setup:**
- Have the WebSocket request pane visible with the message tab active
- Type something in the message field

**Red rectangles + annotations:**

| # | Rectangle Location | Annotation Text |
|---|---|---|
| 1 | Around the Send button + ⌘↵ text | "Send via button or ⌘+Enter keyboard shortcut" |

---

## Screenshot 4: MQTT — Topic Color-Coding & Filtering

**What to show:** MQTT response pane with messages from multiple topics, showing different topic colors.

**Setup:**
- Connect to MQTT broker
- Subscribe to 3+ topics (e.g., `sensor/temp`, `sensor/humidity`, `device/status`)
- Publish and receive messages on each topic
- Have messages from all topics visible in the log

**Red rectangles + annotations:**

| # | Rectangle Location | Annotation Text |
|---|---|---|
| 1 | Around 2-3 topic label chips (different colors on different rows) | "Auto-assigned topic colors — each topic gets a unique color" |
| 2 | Around the topic filter dropdown button | "Filter by topic — show only messages from a specific topic" |
| 3 | Around a message row showing QoS badge and "Retained" tag | "QoS level and retained message indicators" |
| 4 | Around the ConnectionStatsBar showing pub/sub counts | "Connection stats — published ↑ vs subscribed ↓ message counts" |

---

## Screenshot 5: MQTT — Topic Filter Active

**What to show:** The MQTT message log with a specific topic filter selected, showing only messages from that topic.

**Setup:**
- Click the topic filter dropdown
- Select one topic (e.g., `sensor/temp`)
- Log should show only messages for that topic

**Red rectangles + annotations:**

| # | Rectangle Location | Annotation Text |
|---|---|---|
| 1 | Around the topic filter button (now highlighted with active topic name) | "Active filter: showing only 'sensor/temp' messages" |
| 2 | Around the message count in toolbar (showing reduced count) | "Filtered message count updates in real-time" |

---

## Screenshot 6: MQTT — Search in Action

**What to show:** The MQTT message log with a search query active, showing filtered results with match count.

**Setup:**
- Type a search term that matches some messages (e.g., "temp" or "23.5")
- Some messages should be filtered out

**Red rectangles + annotations:**

| # | Rectangle Location | Annotation Text |
|---|---|---|
| 1 | Around the search field with the query text and "X found" badge | "Search with live match count" |
| 2 | Around the remaining visible messages (showing they match the query) | "Only matching messages shown — searches payloads and topic labels" |

---

## Screenshot 7: gRPC — Response Log with Metadata

**What to show:** gRPC response pane with a completed call showing the message log and the expanded metadata section.

**Setup:**
- Connect to a gRPC server
- Invoke a method (unary or server-streaming)
- Expand the metadata toggle to show headers/trailers
- Have at least one response message expanded in the log

**Red rectangles + annotations:**

| # | Rectangle Location | Annotation Text |
|---|---|---|
| 1 | Around the ConnectionStatsBar showing service count | "Connection stats with discovered service count" |
| 2 | Around the Metadata toggle area (expanded, showing headers/trailers) | "Collapsible response headers and trailers" |
| 3 | Around a log entry showing "OK (125ms)" status | "Per-call status with response time" |
| 4 | Around an expanded response message with format chips | "Response message with format toggle — same controls as WS/MQTT" |

---

## Screenshot 8: gRPC — Invoke Keyboard Shortcut

**What to show:** The gRPC request pane bottom bar with Service/Method dropdowns and the Invoke button with ⌘↵ hint.

**Setup:**
- Have a gRPC connection with services discovered
- A service and method should be selected

**Red rectangles + annotations:**

| # | Rectangle Location | Annotation Text |
|---|---|---|
| 1 | Around the Service dropdown | "Service selector — auto-discovered via reflection" |
| 2 | Around the Method dropdown | "Method selector" |
| 3 | Around the Invoke button + ⌘↵ text | "Invoke via button or ⌘+Enter keyboard shortcut" |

---

## Screenshot 9: Export & Clear Buttons

**What to show:** Close-up of the message log toolbar showing the export and clear buttons.

**Setup:**
- Have some messages in any protocol's log
- Hover over the export button to show tooltip

**Red rectangles + annotations:**

| # | Rectangle Location | Annotation Text |
|---|---|---|
| 1 | Around the download/export icon button | "Export all messages as JSON to clipboard" |
| 2 | Around the trash/clear icon button | "Clear all messages (also via ⌘+L)" |
| 3 | Around the message count text ("42 msgs") | "Total message count" |

---

## Screenshot 10: Direction Filter — Sent Only

**What to show:** Message log with "Sent" filter active, showing only outgoing messages.

**Setup:**
- Have a mix of sent and received messages in WS or MQTT
- Click the "Sent" segment in the direction filter

**Red rectangles + annotations:**

| # | Rectangle Location | Annotation Text |
|---|---|---|
| 1 | Around the SegmentedButton with "Sent" highlighted | "Filter active: showing only sent messages" |
| 2 | Around the visible messages (all showing ↑ arrows) | "All displayed messages are outgoing (↑)" |

---

## Screenshot 11: Empty State

**What to show:** The response pane when not connected, showing the empty state with helpful instructions.

**Setup:**
- Create a new WebSocket or MQTT request but don't connect

**Red rectangles + annotations:**

| # | Rectangle Location | Annotation Text |
|---|---|---|
| 1 | Around the entire empty state (icon + text) | "Contextual empty state with clear next-step instructions" |

---

## Screenshot 12: Before/After Comparison

**What to show:** Side-by-side comparison of the old chat-bubble UI and the new message log UI.

**Setup:**
- Take a screenshot of the old UI from the `feat/grpc-support` branch (checkout, run, capture)
- Take the equivalent screenshot from the `ux/protocol-dx-improvements` branch
- Place them side by side (left = before, right = after)

**Red rectangles + annotations:**

| # | Rectangle Location | Annotation Text |
|---|---|---|
| 1 | Large rectangle around the left (old) screenshot | "BEFORE: Chat-bubble UI — limited features, no search/filter" |
| 2 | Large rectangle around the right (new) screenshot | "AFTER: Professional message log — search, filter, format toggle, stats" |

---

## Proposal Integration Notes

When adding these screenshots to the proposal:

1. **Order:** Start with Screenshot 12 (before/after) as the hero image — it immediately shows impact
2. **Group by protocol:** After the hero, show WS screenshots (1-3), then MQTT (4-6), then gRPC (7-8), then shared features (9-11)
3. **Caption format:** Each screenshot should have:
   - A short title (e.g., "WebSocket: Compact Message Log with Search")
   - A 1-2 sentence description of what the screenshot demonstrates
4. **Size:** Keep screenshots at ~800px width in the document for readability
5. **Consistency:** Use the same window size, theme, and similar test data across all screenshots

### Suggested Proposal Section Structure

```
## Implementation Showcase

### Before / After
[Screenshot 12]

### WebSocket DX Improvements
[Screenshot 1] — Overview of the new message log
[Screenshot 2] — Payload format toggle (Pretty JSON)
[Screenshot 3] — Keyboard shortcut integration

### MQTT DX Improvements
[Screenshot 4] — Topic color-coding and filtering
[Screenshot 5] — Active topic filter
[Screenshot 6] — Full-text search

### gRPC DX Improvements
[Screenshot 7] — Response log with metadata
[Screenshot 8] — Invoke shortcut and service discovery

### Shared Features
[Screenshot 9]  — Export and clear
[Screenshot 10] — Direction filtering
[Screenshot 11] — Contextual empty states
```
