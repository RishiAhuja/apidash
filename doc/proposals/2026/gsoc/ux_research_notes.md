# UX Research & Improvement Plan — Protocol Support for API Dash

> Research notes for pivoting the idea doc from architecture/spec focus → UX/DX focus.
> Based on analysis of Postman (WS, MQTT, gRPC), MQTTX, grpcui, and our current PoC.

---

## The Core Problem with the Current PoC

The reviewer's feedback distilled: **"We are a UX/DX focused org. I don't care about architecture understanding. Chat-style interface is bad. Need real features like search and filtering."**

The current PoC treats protocol support as a *plumbing problem* (transport, state, encoding) and the UI as an afterthought. The result is generic chat bubbles that look like a messaging app, not a professional API debugging tool. Every competitor has moved beyond this.

### What "Professional" Looks Like (vs. What We Have)

| Aspect | Professional Tools (Postman/MQTTX) | Current PoC |
|--------|-------------------------------------|-------------|
| Message display | Compact log rows — direction icon, timestamp, payload preview, click to expand | Chat bubbles — sent right, received left, max-width 70-75% |
| Finding messages | Search bar across all payloads + filter by direction | Nothing — scroll manually |
| Message reuse | Saved Messages library for debugging templates | Type from scratch every time |
| Payload inspection | Format toggle (JSON/Hex/Base64/Plaintext/CBOR), JSON tree view | Raw text only (SelectableText) |
| Data insights | Visualization tab with real-time per-topic charts (Postman MQTT) | Nothing |
| Message actions | Copy, expand, pin, export | Nothing (just SelectableText) |
| Export | JSON/CSV download of entire message history | Nothing |
| Connection health | Stats bar (duration, msg count, bytes), auto-reconnect | Basic status text only |
| Keyboard workflow | Cmd+Enter to send (MQTTX), Tab between fields | Mouse-only |

---

## Detailed Research by Competitor

### Postman — WebSocket

- Compose area with message type selector (Text, JSON, Binary, HTML)
- **Message timeline** (not chat bubbles) — reverse-chronological, each row shows direction + timestamp + payload preview
- Click to expand full message
- Clean connect/disconnect toggle
- Params, Headers, Settings tabs on request side

### Postman — MQTT

- **Message stream tab** with timeline of published/received messages
- **Search bar** — find specific content across all messages
- **Filter by sent/received** — toggle to show only published or only subscribed messages
- **Clear Messages** button + **Restore** to bring them back
- **Visualization tab** — graphical format for telemetry data:
  - Per-topic windows
  - Line charts / bar charts for numeric JSON fields
  - Real-time updates as messages arrive
- **Saved Messages** — create, save, and reuse message templates for debugging workflows
- **Message types**: Text, JSON, Base64, Hexadecimal
- **Per-message options**: Topic Alias, Response Topic, Correlation Data, Message Expiry Interval, Content Type, Payload Format Indicator

### Postman — gRPC Streaming

- **Message stream** — sent and received messages arranged in reverse chronological order (latest on top)
- **Expand/collapse** each message in the stream
- **Search** text box to find specific messages
- **Message filter** — toggle between All / Sent / Received
- **Clear Messages** — hide messages with Restore option
- **Connection status** — active/streaming indicator
- **Response tabs**: Response body, Metadata, Trailers, Test Results
- **Status code + Time** prominently displayed
- **Save Response** as reusable examples
- **Wrap lines** toggle for long response bodies
- **Beautify** button for JSON formatting
- **Use Example Message** — auto-generate request from protobuf schema

### MQTTX

- **Chat-style** display but with professional additions:
  - Topic label on every message
  - Direction indicators (published/subscribed)
  - QoS badge
- **Topic-based filtering** — click a subscription in the sidebar to see only that topic's messages
- **Color-coded subscriptions** — each topic gets a customizable color for visual distinction
- **Topic aliases** for readability
- **Right-click context menu** on subscriptions: Edit / Disable / Enable
- **Payload format conversion**: Base64, Hex, JSON, Plaintext, CBOR, MsgPack
- **Protobuf/Avro** decoding via Schema tab
- **Keyboard shortcut**: Cmd+Enter / Ctrl+Enter to send
- **Data simulation** — built-in scenarios for IoT testing
- **Full logging** — track and debug MQTT communications

### grpcui

- **Dynamic HTML form** from protobuf schema — each field renders an appropriate input widget
- **Well-known type support**: `google.protobuf.Timestamp` → date picker, `StringValue` → simple text box
- **Form tab + JSON tab + Response tab** layout
- **Streaming requests**: Multiple messages shown as repeated form fields (add/remove)
- **Response display**: Headers table, Data table (structured, nested), Trailers table
- **Service/method dropdown** selectors at top

---

## Proposed Changes — By Feature

### 1. Message Log (Replace Chat Bubbles) — WS, MQTT, gRPC Streaming

**The single most important change.** Replace chat-style `_WsMessageBubble` and `MqttMessageBubble` with a compact, professional message log.

**Design:**
```
┌─────────────────────────────────────────────────────────────────┐
│ [Search 🔍] [Filter: All ▾] [Export ↓] [Clear 🗑]    42 msgs │
├─────────────────────────────────────────────────────────────────┤
│ → 14:23:01.234  {"action":"subscribe","channel":"btc_usd"}     │
│ ← 14:23:01.456  {"status":"ok","channel":"btc_usd"}            │
│ ← 14:23:02.100  {"price":42150.50,"vol":1.23}   [148 B]       │
│ ← 14:23:03.100  {"price":42151.20,"vol":0.87}   [148 B]       │
│ → 14:23:05.000  {"action":"unsubscribe","channel":"btc_usd"}   │
└─────────────────────────────────────────────────────────────────┘
```

Each row:
- **Direction icon**: → (sent, tinted primary) / ← (received, tinted secondary)
- **Timestamp**: HH:mm:ss.SSS, compact
- **Payload preview**: Single line, truncated with ellipsis
- **Size badge**: `[148 B]` for messages over a certain size
- **Click to expand**: Full payload with JSON syntax highlighting, copy button, format toggle
- **For MQTT**: Also shows topic label + QoS badge inline

**Why this matters:** Developers scanning a message stream need to quickly spot anomalies — a status change, an error response, a missing message. Chat bubbles waste 30-40% of horizontal space on alignment and force large vertical spacing. The log view is information-dense and scannable.

**Files to change:**
- `ws_response_pane.dart` — Replace `_WsMessageBubble` + `ListView.builder` with `MessageLogView` widget
- `mqtt_response_pane.dart` — Replace `MqttMessageBubble` with same `MessageLogView`
- `grpc_response_pane.dart` — Adapt card layout to use `MessageLogView` for streaming calls
- New shared widget: `lib/widgets/message_log_view.dart`

### 2. Message Search

**Text search** across all message payloads in the current session.

**Design:**
- Search icon in the toolbar — click to reveal search field
- As you type, messages that don't match are dimmed or filtered out
- Match count shown: "3 of 42 messages"
- Up/Down arrows to jump between matches
- Search should be across payload content, topic names (MQTT), and status messages

**Why this matters:** When debugging a WebSocket connection with 200+ messages, manually scrolling for a specific payload is painful. Every professional tool has this.

### 3. Message Filtering

**Direction filter** (All / Sent / Received) + **Topic filter** (MQTT only).

**Design:**
- Dropdown or segmented control: `All | → Sent | ← Received`
- For MQTT: Additional topic chip/pills — click a topic to filter messages to just that topic
- Visual indicator when filter is active (badge count, highlight)
- Combine with search: search within filtered results

**Postman does this.** MQTTX does this (click subscription to filter). We have nothing.

### 4. Payload Format Toggle

Support multiple payload viewing formats, not just raw text.

**Formats:**
- **Pretty JSON** — syntax highlighted, collapsible tree (like the existing `json_explorer` package in the monorepo!)
- **Raw Text** — current default
- **Hex** — hex dump view for binary payloads
- **Base64** — base64 encoded view
- **Table view** — for array-of-objects JSON payloads, render as a table

**Where it applies:**
- WS: Per-message and compose area
- MQTT: Per-message and compose area (MQTTX supports CBOR, MsgPack, Protobuf/Avro too)
- gRPC: Response messages (already JSON, but add tree view + beautify)

**Note:** The monorepo already has `packages/json_explorer/` — we should use it for collapsible JSON tree views in the response pane.

### 5. Saved Messages (Message Templates)

Allow users to save, name, and reuse frequently-sent messages.

**Design:**
- "Save" icon next to the send button — saves current message as a named template
- "Templates" dropdown/panel — quick-pick from saved messages
- Templates are per-protocol, stored in Hive alongside request data
- For MQTT: Template includes topic + QoS + payload (not just payload)
- For gRPC: Template includes method + message body

**Why this matters:** When testing a WebSocket API, you often send the same auth/subscribe/unsubscribe messages repeatedly. Typing them from scratch every time is a DX failure. Postman's "Saved Messages" feature directly addresses this.

### 6. Data Visualization (MQTT — Stretch Goal)

Real-time charts for numeric telemetry data arriving on MQTT topics.

**Design (inspired by Postman's Visualization tab):**
- A "Visualization" tab in the MQTT response pane
- Auto-detects numeric JSON fields in incoming messages
- Per-topic line chart — plots values over time
- User can select which JSON field to chart
- Useful for IoT sensor data (temperature, pressure, voltage) where visual trends matter more than raw numbers

**This is a differentiator.** Postman has it. MQTTX doesn't. It's a strong signal that we're thinking about what developers actually *need*, not just displaying data.

### 7. Per-Message Actions

Actionable buttons on each message in the log.

**Actions:**
- **Copy payload** — one-click copy to clipboard (currently users must manually select text)
- **Copy as cURL/wscat/mqtt command** — generate CLI equivalent
- **Expand/Collapse** — toggle between preview and full view
- **Pin/Bookmark** — mark important messages for reference (visual indicator)
- **Resend** (for sent messages) — quick resend with one click

### 8. Export Message History

Export the full session message history.

**Formats:**
- **JSON** — structured export with timestamps, direction, payloads
- **CSV** — tabular export for spreadsheet analysis
- **HAR-like** — for WebSocket, extend HAR format (the monorepo already has `packages/har/`)

**Trigger:** Export button in the toolbar, or right-click → "Export all messages"

### 9. Connection Stats Bar

Persistent status bar showing connection health metrics.

**Design:**
```
┌─ Connected ─ 12m 34s ─ 142 msgs (87 ↓ / 55 ↑) ─ 24.5 KB total ─┐
```

- **Status**: Connected / Disconnected / Connecting / Reconnecting
- **Duration**: Time since connection established
- **Message count**: Total, with breakdown by direction
- **Bytes**: Total transferred
- **For MQTT**: Also show subscribed topic count
- **For gRPC**: Show call type + method name

### 10. Auto-Reconnect

Configurable automatic reconnection for connection drops.

**Design:**
- Toggle in Settings tab: "Auto-reconnect on disconnect"
- Configurable: max retries, backoff interval (linear/exponential)
- Visual indicator during reconnection attempts
- Notification when reconnection succeeds/fails

### 11. Keyboard Shortcuts

- **Cmd+Enter / Ctrl+Enter** — Send message (MQTTX has this, we should too)
- **Cmd+L / Ctrl+L** — Clear messages
- **Cmd+F / Ctrl+F** — Focus search
- **Escape** — Close search / clear filter

### 12. Topic Color Coding (MQTT)

Like MQTTX — each subscription gets a color indicator.

**Design:**
- Color dot next to each topic in the subscription table
- Same color appears on messages from that topic in the log view
- Auto-assigned colors, with ability to customize
- Makes it instantly visual which topic a message belongs to

### 13. gRPC-Specific Improvements

From Postman and grpcui research:

- **Beautify JSON** button in the message compose area (Postman has this)
- **Use Example Message** — auto-generate a request body from the protobuf schema, pre-filled with default values (Postman has this, grpcui has this via its form)
- **Well-known type rendering** — `google.protobuf.Timestamp` shown as human-readable datetime, not raw seconds (grpcui does this with a date picker)
- **Service method badges** — show call type (Unary/Server Stream/Client Stream/Bidi) as colored badges (we partially have this)
- **Response streaming timeline** — use the same `MessageLogView` widget with expand/collapse, search, and filter (matching Postman's gRPC streaming response UI)

---

## Priority Matrix

| Priority | Feature | Impact on DX | Effort | Competitor Coverage |
|----------|---------|-------------|--------|---------------------|
| **P0** | Message Log (replace bubbles) | Critical — most visible change | Medium | All competitors |
| **P0** | Message Search | Critical — basic debugging need | Low | Postman, MQTTX |
| **P0** | Message Filtering | Critical — direction + topic | Low | Postman, MQTTX |
| **P1** | Payload Format Toggle | High — JSON tree alone is huge | Medium | Postman, MQTTX |
| **P1** | Per-Message Actions (copy, expand) | High — basic usability | Low | Postman, MQTTX |
| **P1** | Connection Stats Bar | High — always-visible health | Low | Postman, MQTTX |
| **P1** | Keyboard Shortcuts | High — power user efficiency | Low | MQTTX |
| **P2** | Saved Messages | Medium-High — workflow optimization | Medium | Postman |
| **P2** | Export | Medium — occasional need but important | Medium | Postman |
| **P2** | Topic Color Coding | Medium — visual clarity | Low | MQTTX |
| **P2** | Auto-Reconnect | Medium — reliability | Medium | Postman, MQTTX |
| **P2** | gRPC Example Message | Medium — onboarding | Medium | Postman, grpcui |
| **P3** | Data Visualization | Medium — differentiator for IoT | High | Postman only |
| **P3** | gRPC Well-Known Types | Low-Medium — niche | High | grpcui only |

---

## How This Changes the Idea Doc

The current doc structure:
1. Problem → spec table → video → architecture diagram
2. Per-protocol: spec reading story → implementation details → code snippets → bug stories
3. Design decisions (all architectural)

**New structure should be:**
1. Problem → **what developers suffer through today** (UX pain, tool-switching, clunky workflows)
2. Per-protocol: **what the user experience will be** → feature matrix → mockup/wireframe description → how we improve on competitors
3. PoC as evidence of feasibility (brief, not the star)
4. Technical approach (compact, supporting the UX story)
5. Timeline organized by **user-facing milestones** ("Week 2: users can search and filter messages") not internal milestones ("Week 2: implement StateNotifier")

**The fundamental shift:** Instead of "here's what I know about the protocol spec", it should be "here's what a developer testing WebSocket APIs will be able to do that they can't do today in any free tool."
