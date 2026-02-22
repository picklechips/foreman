# Foreman — Implementation Plan

---

## Project Summary

Foreman is a mobile app (iOS & Android) that presents an iMessage-style chat interface for interacting with Claude Code agents running on a personal machine. It is not a cloud service — there is no backend, no third-party relay, and no data leaves your network. All communication flows over Tailscale (WireGuard) from your phone to your machine.

The goal is to replicate the async, notification-driven experience of a messaging app while giving full access to multiple persistent Claude Code agent sessions.

---

## Architecture Overview

```
┌─────────────────────────────────────────────┐
│              Mobile App (React Native)       │
│                                             │
│  ┌──────────────┐  ┌──────────┐  ┌───────┐  │
│  │   Tailscale  │  │ WS Client│  │ ntfy  │  │
│  │  (OS-level)  │  │(reconnect│  │ push  │  │
│  └──────┬───────┘  └────┬─────┘  └───┬───┘  │
└─────────┼───────────────┼────────────┼───────┘
          │ WireGuard      │            │ internet
          │ (Tailscale)    │            │ (ntfy.sh)
          ▼                ▼            ▼
┌─────────────────────────────────────────────┐
│          Host Machine (your Mac/Linux)       │
│                                             │
│  ┌─────────────────────────────────────┐    │
│  │         Relay Daemon (Node.js)       │    │
│  │  binds: tailscale-ip:7821           │    │
│  │  auth:  Bearer token                │    │
│  │                                     │    │
│  │  ┌──────────┐  ┌──────────────────┐ │    │
│  │  │ Session  │  │  Transcript Store│ │    │
│  │  │ Router   │  │  ~/.foreman/     │ │    │
│  │  └────┬─────┘  └──────────────────┘ │    │
│  └───────┼─────────────────────────────┘    │
│           │                                  │
│  ┌────────┼──────────────────────────────┐  │
│  │ tmux   │                              │  │
│  │  ├─ foreman-session-frontend  ←─────┐ │  │
│  │  ├─ foreman-session-backend   ←───┐ │ │  │
│  │  └─ foreman-session-infra     ←─┐ │ │ │  │
│  └─────────────────────────────────┘ │ │ │  │
│                                    FIFO pipes│
└─────────────────────────────────────────────┘
        │
        ▼ outbound only
   ntfy.sh (push notifications)
```

**Key design decisions:**
- The relay daemon **only binds to the Tailscale interface**. It is never reachable from LAN or the public internet.
- The mobile app connects via **Tailscale** (WireGuard VPN, handled at the OS level) — no SSH library required in the app.
- Each Claude Code session runs in its own **tmux window** with a **named FIFO pipe** for stdin and a **log file** for stdout. This means the relay daemon can restart without killing Claude sessions.
- Push notifications go out via `ntfy.sh` — outbound-only, no inbound surface.

---

## Security Model

### Threat Model

| Threat | Mitigation |
|---|---|
| Unauthorized access to relay daemon | Daemon binds to Tailscale interface only; not reachable from internet or LAN |
| Unauthorized Tailscale device | Tailscale device authorization + MFA on Tailscale account |
| Man-in-the-middle | WireGuard encryption at OS level; Tailscale handles key management |
| Relay auth bypass | Bearer token required on every WebSocket connection (defense in depth beyond Tailscale) |
| Prompt injection via agent response | App treats all agent output as untrusted display content, never eval'd |
| Runaway agent (infinite loop, high spend) | Per-session message rate limit in relay; Anthropic spend cap configured separately |
| ntfy topic enumeration | Topic name is a 32-byte random hex string, treated as a secret |
| Session fixation | Session IDs are UUIDs generated server-side, not client-controlled |
| Path traversal in session cwd | `cwd` validated against server-side allowlist before use; symlinks resolved before check |

### Security Rules for Implementation
1. Relay daemon **must** validate Bearer token before processing any message
2. Session `cwd` paths **must** be validated against an allowlist of directories set at daemon startup — the mobile client cannot specify arbitrary paths
3. All `sessionId` values used in file paths **must** be sanitized (alphanumeric + hyphen only, max 64 chars)
4. Claude process stdout is treated as untrusted data — parsed as JSON, never executed
5. The FIFO stdin pipe **must** have a write timeout — a hung Claude process cannot block the relay
6. Timing-safe comparison (`crypto.timingSafeEqual`) must be used for Bearer token validation

---

## Repository Structure

```
foreman/
├── shared/                  # Shared TypeScript types (API contract)
│   └── src/types.ts
├── relay/                   # Node.js relay daemon
│   ├── src/
│   │   ├── main.ts          # Entry point
│   │   ├── server.ts        # WebSocket server + auth
│   │   ├── sessions.ts      # Session lifecycle manager
│   │   ├── claude.ts        # Claude Code process wrapper (FIFO + log tail)
│   │   ├── tmux.ts          # tmux session management
│   │   ├── transcript.ts    # Transcript persistence (JSONL)
│   │   ├── hooks-server.ts  # HTTP server for Claude Code hook callbacks
│   │   └── config.ts        # Config loading + Zod validation
│   ├── package.json
│   └── tsconfig.json
├── app/                     # React Native app (Expo)
│   ├── src/
│   │   ├── ws/              # WebSocket client + reconnection logic
│   │   ├── store/           # Zustand state (sessions, messages)
│   │   ├── screens/
│   │   │   ├── ConnectionSetup.tsx
│   │   │   ├── SessionList.tsx
│   │   │   └── Conversation.tsx
│   │   ├── components/
│   │   │   ├── ChatBubble.tsx
│   │   │   ├── ToolCallCard.tsx
│   │   │   ├── ThinkingIndicator.tsx
│   │   │   └── SessionStatusDot.tsx
│   │   └── notifications/
│   │       └── ntfy.ts
│   ├── ios/
│   ├── android/
│   └── package.json
└── scripts/
    ├── server-setup.sh      # One-command server setup
    └── gen-token.sh         # Generate relay auth token
```

---

## WebSocket API Contract

Defined in `shared/src/types.ts`. **Both relay and app must be built against this — finalize before parallel work begins.**

### Client → Server (Requests)

```typescript
// All requests have: { type, id }
// All responses have: { type: "response", id, ok, result?, error? }

{ type: "session.list", id: string }

{ type: "session.create", id: string,
  name: string,            // alphanumeric + hyphen, max 32 chars
  cwd: string,             // must be in server-side allowlisted dirs
  model?: string }         // default: claude-opus-4-6

{ type: "session.message", id: string,
  sessionId: string,
  text: string }           // max 32000 chars

{ type: "session.interrupt", id: string,
  sessionId: string }      // sends SIGINT to Claude process

{ type: "session.destroy", id: string,
  sessionId: string }

{ type: "session.history", id: string,
  sessionId: string,
  limit?: number }         // default 100, max 500
```

### Server → Client (Events)

```typescript
// Pushed at any time, not tied to a request
{ type: "event", sessionId: string, event: ClaudeEvent }

type ClaudeEvent =
  | { type: "assistant_text", text: string }
  | { type: "thinking", text: string }
  | { type: "tool_use", tool: string, input: Record<string, unknown> }
  | { type: "tool_result", tool: string, ok: boolean, summary: string }
  | { type: "stop", reason: "end_turn" | "interrupted" | "error" }
  | { type: "waiting_input", message: string }
  | { type: "session_status", status: SessionStatus }

type SessionStatus = "idle" | "thinking" | "waiting_input" | "error" | "dead"
```

### Session State Machine

```
idle → thinking → (tool_use → tool_result)* → idle
                                             → waiting_input → [user responds] → thinking
                                             → error
```

---

## Implementation Plan

### Phase 0 — Foundation *(sequential, unblocks everything)*

These tasks must complete before parallel work can begin.

---

**Task 0.1 — Monorepo Setup**

*Description:* Initialize the monorepo with pnpm workspaces, TypeScript, and shared tooling.

*Steps:*
1. `pnpm init` at root, configure `pnpm-workspace.yaml` with `packages: [shared, relay, app]`
2. Root `tsconfig.base.json` with strict mode, `NodeNext` module resolution
3. `shared/` package: `package.json` with name `@foreman/shared`, export `src/types.ts`
4. `.gitignore`, `.nvmrc` (Node 22), root `README.md`

*Acceptance:* `pnpm install` succeeds; `tsc --noEmit` passes in all packages.

---

**Task 0.2 — API Contract (`shared/src/types.ts`)**

*Description:* Write the complete TypeScript types for the WebSocket API. This file is the contract both sides build against.

*Steps:*
1. Define all request types as discriminated union `ClientMessage`
2. Define all event types as discriminated union `ClaudeEvent`
3. Define all response types as `ServerResponse<T>`
4. Define `Session` type: `{ id, name, cwd, model, status, createdAt, lastActiveAt }`
5. Export Zod schemas for runtime validation of incoming messages (used by relay)

*Acceptance:* No `any` types; all discriminated unions are exhaustive; Zod schemas match TypeScript types.

---

**Task 0.3 — Server Setup Script (`scripts/server-setup.sh`)**

*Description:* A script the user runs once on their host machine to install dependencies and configure the daemon.

*Steps:*
1. Check for Node 22+, tmux, claude CLI — print clear error if missing
2. Create `~/.foreman/` directory structure:
   ```
   ~/.foreman/
   ├── config.json          # allowed_dirs, port, model, ntfy_topic
   ├── token                # 32-byte hex bearer token (chmod 600)
   ├── transcripts/         # per-session JSONL transcript files
   ├── pipes/               # named FIFOs for Claude stdin
   └── logs/                # per-session stdout logs
   ```
3. Generate bearer token: `openssl rand -hex 32 > ~/.foreman/token && chmod 600 ~/.foreman/token`
4. Write default `config.json`:
   ```json
   { "port": 7821, "allowed_dirs": ["~/projects"], "model": "claude-opus-4-6", "ntfy_topic": "" }
   ```
5. Install Claude Code hooks in `~/.claude/settings.json` pointing to relay's hook endpoint (port 7822)
6. Print Tailscale IP and token for use in the mobile app

*Acceptance:* Running the script twice is idempotent (does not overwrite existing token or config).

---

### Phase 1 — Parallel Implementation Tracks

All tracks start after Phase 0. Tracks A and B are fully independent. Tracks C and D are independent of everything.

---

### Track A — Relay Daemon

**Task A.1 — Claude Process Wrapper (`relay/src/claude.ts`)**

*Description:* Manages a single Claude Code process via FIFO stdin + log file stdout.

*Steps:*
1. `spawnClaudeSession(opts: { sessionId, cwd, model, logPath, pipePath })`:
   - Create named FIFO at `pipePath` via `mkfifo`
   - Spawn tmux: `tmux new-session -d -s foreman-{sessionId} bash -c "claude --output-format stream-json < {pipePath} >> {logPath} 2>&1"`
2. `ClaudeProcess` class:
   - `send(text: string): Promise<void>` — writes `text + "\n"` to FIFO, 5s timeout
   - `interrupt(): Promise<void>` — `tmux send-keys -t foreman-{sessionId} C-c`
   - `isAlive(): boolean` — `tmux has-session -t foreman-{sessionId}`
   - `destroy(): Promise<void>` — kill tmux session, remove FIFO and log
3. `tailLog(logPath, onLine)` — streams new lines from log file via `fs.watchFile`; calls `onLine` for each

*Acceptance:* Unit tests (mock tmux/fifo): `send()` writes correctly; `isAlive()` returns false after `destroy()`; `tailLog` calls `onLine` per new line.

---

**Task A.2 — Stream JSON Parser (`relay/src/claude.ts`)**

*Description:* Parses raw lines from Claude's `--output-format stream-json` stdout into `ClaudeEvent` objects.

Claude stream-json line shapes:
```json
{"type":"assistant","message":{"content":[{"type":"text","text":"..."}]}}
{"type":"tool_use","name":"Write","input":{"file_path":"..."}}
{"type":"tool_result","content":[{"type":"text","text":"..."}],"is_error":false}
{"type":"result","subtype":"success"}
{"type":"result","subtype":"error_during_execution","error":"..."}
```

*Steps:*
1. `parseClaudeLine(raw: string): ClaudeEvent | null` — return null on parse failure (log, don't throw)
2. Map each Claude output type to the corresponding `ClaudeEvent` from `shared/src/types.ts`
3. Handle multi-content blocks (Claude may return multiple text chunks per message)
4. `result.subtype === "success"` → `{ type: "stop", reason: "end_turn" }`
5. `result.subtype` starting with `"error"` → `{ type: "stop", reason: "error" }`

*Acceptance:* Unit tests cover all event types; malformed JSON returns null without throwing.

---

**Task A.3 — Session Manager (`relay/src/sessions.ts`)**

*Description:* Full lifecycle management for multiple Claude sessions with persistence.

*Steps:*
1. `SessionManager` class with in-memory `Map<string, Session>` + disk persistence
2. On startup: scan `~/.foreman/transcripts/` for existing sessions; check tmux liveness; set status accordingly
3. `createSession(name, cwd, model)`:
   - Validate `cwd` against `config.allowed_dirs` (resolve symlinks before check)
   - Validate `name` matches `/^[a-zA-Z0-9-]{1,32}$/`
   - Generate UUID for `sessionId`
   - Spawn Claude process via A.1; start log tail; pipe parsed events to subscribers
   - Persist `~/.foreman/transcripts/{sessionId}/meta.json`
4. `sendMessage(sessionId, text)`:
   - Validate session exists and status is `idle`
   - Append to transcript JSONL
   - Set status → `thinking`; call `process.send(text)`
   - On `stop` event → set status → `idle`
5. Pub/sub: `onEvent(sessionId, callback)` / `offEvent`

*Acceptance:* Integration test: create session, send message (mocked process), receive events, verify status transitions.

---

**Task A.4 — WebSocket Server (`relay/src/server.ts`)**

*Description:* The WebSocket server — connections, auth, message routing, event fan-out.

*Steps:*
1. Use `ws` npm package. Bind to `{tailscaleIp}:{config.port}` (never `0.0.0.0`)
2. On connection: expect `{ type: "auth", token }` within 5s; compare with `crypto.timingSafeEqual`; close if wrong or timeout
3. Route incoming requests to `SessionManager` methods by `type` field
4. Subscribe new connection to all session events; forward to WebSocket client
5. On `session.history`: read transcript JSONL, return last N entries
6. On disconnect: clean up event subscriptions
7. Graceful shutdown on `SIGTERM`/`SIGINT`

*Acceptance:* Connection without valid token rejected within 5s. Two simultaneous clients both receive events for the same session.

---

**Task A.5 — Hooks HTTP Server (`relay/src/hooks-server.ts`)**

*Description:* Receives Claude Code hook callbacks (`Stop`, `Notification`) and translates them to session events and push notifications.

*Steps:*
1. HTTP server on `127.0.0.1:7822` (loopback only — only Claude Code hooks call this)
2. `POST /hook/stop`:
   - Check `stop_hook_active` — return immediately if true (prevent infinite loop)
   - Send ntfy push: `curl -s -d "Done: {last_assistant_message.slice(0,80)}" https://ntfy.sh/{config.ntfy_topic}`
3. `POST /hook/notification`:
   - Emit `waiting_input` event to matching Foreman session
   - Send ntfy push with `Title: Foreman — needs input` header
4. Claude Code hooks configured by `server-setup.sh` (Task 0.3):
   ```json
   {
     "hooks": {
       "Stop": [{ "hooks": [{ "type": "command",
         "command": "curl -s -X POST http://127.0.0.1:7822/hook/stop -d @-" }] }],
       "Notification": [{ "hooks": [{ "type": "command",
         "command": "curl -s -X POST http://127.0.0.1:7822/hook/notification -d @-" }] }]
     }
   }
   ```

*Acceptance:* Mock `Stop` payload triggers ntfy push (verified with test topic). `stop_hook_active: true` input returns without pushing.

---

**Task A.6 — Relay Entry Point (`relay/src/main.ts`, `relay/src/config.ts`)**

*Description:* Wire everything into a runnable daemon with config loading and graceful shutdown.

*Steps:*
1. `config.ts`: Load `~/.foreman/config.json` with Zod validation; expose typed config
2. `main.ts`: Load config → read token → start `SessionManager` → start WebSocket server → start hooks HTTP server → handle `SIGTERM`/`SIGINT`
3. `relay/package.json` bin: `"foreman-relay": "./dist/main.js"`
4. `scripts/server-setup.sh` generates launchd plist (macOS) or systemd unit (Linux)

*Acceptance:* `node relay/dist/main.js` starts, accepts a WebSocket connection, handles a full send/receive cycle end-to-end.

---

### Track B — Mobile App

**Task B.1 — Project Scaffold**

*Tech stack:*
- React Native 0.76+ with Expo (managed workflow)
- React Navigation (stack + tab)
- Zustand (state management)
- `expo-secure-store` (credential storage)
- `expo-notifications` (local push)
- `react-native-markdown-display` (message rendering)

*Steps:*
1. `npx create-expo-app app --template blank-typescript`
2. Install navigation, state, and storage dependencies
3. Set up navigation: `ConnectionSetup` (first run) → `SessionList` → `Conversation`
4. Configure iOS entitlements for local network access
5. Set up `@foreman/shared` workspace dependency

*Acceptance:* App runs in Expo Go on iOS and Android simulator; navigation between all three screens works.

---

**Task B.2 — WebSocket Client (`app/src/ws/`)**

*Description:* Persistent WebSocket client with auth handshake, reconnection, and event dispatch.

*Steps:*
1. `ForemanClient` class:
   - `connect(host, port, token)`: open `ws://{tailscaleIp}:7821`, send `{ type: "auth", token }` as first message
   - Auto-reconnect with exponential backoff (1s, 2s, 4s, 8s, max 30s) on disconnect
   - Request/response matching by `id` (UUID per request, matched on response)
   - `onEvent(callback)` for server-pushed events
2. Connection state machine: `disconnected → connecting → authenticating → connected → disconnected`
3. `useForeman()` React hook exposing `{ connected, status, sendMessage, createSession, listSessions, interruptSession, destroySession }`

*Acceptance:* On disconnect, client enters reconnecting state with backoff. In-flight requests fail cleanly with error. Auth timeout closes connection.

---

**Task B.3 — State Store (`app/src/store/`)**

*Steps:*
1. `sessionStore` (Zustand):
   ```typescript
   { sessions: Session[], activeSessionId: string | null,
     setSession, setActiveSession, updateStatus }
   ```
2. `messageStore` (Zustand):
   ```typescript
   { messages: Record<sessionId, Message[]>, appendMessage, clearSession }
   type Message = { id, role, content, ts, toolCall?, toolResult? }
   ```
3. Wire `ForemanClient.onEvent` to dispatch into stores on app startup
4. Persist last 200 messages per session to AsyncStorage for offline viewing

*Acceptance:* Messages persist across app restarts. Status updates immediately reflected in session list.

---

**Task B.4 — Session List Screen (`app/src/screens/SessionList.tsx`)**

*Steps:*
1. List of sessions with name, last message preview, and `SessionStatusDot`
2. Pull-to-refresh calls `session.list`
3. "New Session" FAB → modal: name input, directory picker (from relay's allowed dirs), model selector
4. Swipe-to-delete calls `session.destroy` with confirmation
5. Offline banner when WebSocket is disconnected

---

**Task B.5 — Conversation Screen (`app/src/screens/Conversation.tsx`)**

*Steps:*
1. Inverted `FlatList` of messages (newest at bottom), virtualized
2. Input bar with `TextInput` + send button; disabled when session status is `thinking`
3. Interrupt button (stop icon) visible during `thinking` — calls `session.interrupt`
4. `KeyboardAvoidingView` for keyboard handling
5. Auto-scroll to bottom on new message

---

**Task B.6 — Chat Components (`app/src/components/`)**

**`ChatBubble.tsx`:**
- User messages: right-aligned, tinted
- Assistant text: left-aligned, `react-native-markdown-display` for rendering
- Timestamp on long-press

**`ToolCallCard.tsx`:**
- Inline card showing tool name + key params (e.g. "Write → src/auth/login.tsx")
- Expands on tap to show full input/output
- Blue = in-progress, green = success, red = error

**`ThinkingIndicator.tsx`:**
- Animated three-dot indicator, left-aligned, shown when status is `thinking`

**`SessionStatusDot.tsx`:**
- Green (idle), amber pulse (thinking), red (waiting_input), grey (dead)

---

### Track C — Push Notifications

**Task C.1 — ntfy Integration (`app/src/notifications/ntfy.ts`)**

*Steps:*
1. User enters ntfy topic (from server setup output) in Connection Setup screen; stored in AsyncStorage
2. Subscribe to `https://ntfy.sh/{topic}/sse` while app is backgrounded
3. On notification received: surface via `expo-notifications` as local push
4. Relay sends `X-Tags: {sessionId}` header in ntfy POST — notification carries session context
5. On notification tap: deep link to `Conversation` screen for that session

**Task C.2 — Deep Link Handling**

*Steps:*
1. Register URL scheme `foreman://session/{sessionId}`
2. `Linking.addEventListener` + `expo-notifications` response listener both route to `Conversation` with correct `sessionId`

---

### Track D — Connection Setup UX

**Task D.1 — Connection Setup Screen (`app/src/screens/ConnectionSetup.tsx`)**

*Steps:*
1. Step 1 — Host details: Tailscale IP (or hostname), port (default 7821)
2. Step 2 — Auth token: paste the token printed by `server-setup.sh`; stored in `expo-secure-store`
3. Step 3 — Test connection: attempt WebSocket connect + auth, show success/failure with diagnostic
4. Step 4 — ntfy topic: paste topic from server setup output
5. Step 5 — Save `ConnectionProfile` to AsyncStorage
6. Support multiple profiles for multiple machines

---

### Phase 2 — Integration & Testing *(sequential after Phase 1)*

**Task E.1 — End-to-End Integration Test**

Full user journey:
1. Run relay daemon on dev machine
2. Connect app via Tailscale
3. Complete connection setup
4. Create session, send "Write a hello world in Python"
5. Verify: `ThinkingIndicator` → `ToolCallCard` (Write tool) → assistant text → session goes idle
6. Kill Tailscale, verify disconnect banner
7. Restore Tailscale, verify reconnection and event resume

**Task E.2 — Error Handling Hardening**

Paths to cover:
- Claude process dies → session status `dead`, show retry option
- FIFO write timeout → session status `error`, relay logs diagnostic
- Message exceeds 32000 chars → relay rejects with descriptive error
- `cwd` outside allowlist → relay rejects `session.create` with descriptive error
- ntfy unreachable → push fails silently; in-app state still correct
- Wrong bearer token → connection closed, app shows auth error

**Task E.3 — Background Connection Management**

*Steps:*
1. Expo Background Fetch / iOS Background Task to maintain ntfy SSE subscription when backgrounded
2. Re-establish WebSocket on app foreground if connection dropped
3. Android: persistent local notification "Listening for agent notifications" (required to keep service alive)

---

### Phase 3 — Polish *(parallelizable)*

| Task | Description |
|---|---|
| F.1 | Haptic feedback on send and on notification received |
| F.2 | Code block syntax highlighting in assistant messages |
| F.3 | Session rename (tap header in Conversation screen) |
| F.4 | Export conversation transcript via share sheet |
| F.5 | Per-connection ntfy topic (for multiple machines) |
| F.6 | Relay daemon version check on startup |

---

## Parallelization Map

```
Phase 0 (0.1 → 0.2 → 0.3)
           ↓
    ┌──────┴──────────────────────┐
  Track A                      Track B          Tracks C & D
  A.1 → A.2                    B.1              (independent)
     ↓                         B.2
    A.3                        B.3
     ↓                         B.4
    A.4                        B.5
     ↓                         B.6
    A.5
     ↓
    A.6
    └──────────────┬────────────┘
                Phase 2
              E.1 → E.2 → E.3
                   ↓
                Phase 3
```

Tracks A and B can run fully in parallel after Phase 0. Tracks C and D are independent of each other and of A/B, requiring only the Connection Setup screen (B.1) as a prerequisite for their UI integration points.

---

## Key Technical Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Transport | Tailscale (WireGuard) | No viable SSH library for React Native; better security posture than in-app SSH |
| Mobile framework | React Native + Expo | Single codebase, managed builds, good ecosystem |
| State management | Zustand | Minimal boilerplate, works well for this data shape |
| Claude communication | `--output-format stream-json` + FIFO | Structured output, survives relay restarts |
| Session persistence | tmux | Sessions survive relay daemon restarts |
| Push notifications | ntfy.sh | Free, open source, no account required, self-hostable |
| Relay auth | Bearer token (timing-safe compare) | Defense-in-depth layer beyond Tailscale |
