# AGENTS.md — Boltty

Rules and hard-won facts for anyone, human or agent, changing this code. Read
it before non-trivial work. [ARCHITECTURE.md](ARCHITECTURE.md) is the gentler
overview; [CONTRIBUTING.md](CONTRIBUTING.md) is how to build and test.

## What Boltty is

A native macOS client for the agent CLIs the person already has installed.
Two features:

- **Boltty AI** — a floating panel on ⌥Space (rebindable). Return starts a
  conversation in the background; the same panel is the chat list and the
  open chat.
- **Ask Boltty** — hold ⌃⌥⌘, ask about the screen out loud, circle what you
  mean; the agent's face answers beside the pointer, in typed words and
  blips, and can point and draw.

Settings and a small permissions window are the only windows. There is a menu
bar item and a face beside the notch.

Five adapters, each behind `AgentClient`, each over the interface its CLI
really offers:

| Agent | How Boltty drives it |
|---|---|
| **OpenCode** | the user's `opencode serve --service` when running, else a managed `opencode serve`; HTTP for requests, SSE for events |
| **Claude Code** | one `claude --print` process per conversation, stream-json both ways, the SDK control channel for permissions |
| **Codex** | one `codex app-server`, JSON-RPC over stdio, threads and turns |
| **Grok** | one `grok --permission-mode default agent stdio`, ACP JSON-RPC over stdio |
| **Antigravity** | one `agy --print=` process per conversation, stream-json, permissions through Boltty's own hook |

**Every adapter reads history from the CLI's own record** — Claude Code's
`.jsonl`, Codex's rollout, Grok's `chat_history.jsonl`, Antigravity's
conversation `.db`, OpenCode's database through the server. The process is for
*doing* things: starting a turn, answering a permission. Never ask a process to
replay history.

**What each agent can do is declared, not assumed.** `AgentCapabilities` is
what the UI reads. A model menu, a permission card, an attach button and a stop
button each appear only where the adapter can carry the action out. A control
the CLI cannot honour is the specific failure this prevents.

**Boltty is not a terminal emulator and must not become one.** No VT engine,
PTY, panes, shell integration or terminal renderer. Never restore one to make
an old test compile; delete the test. Metal is fine: the mascot, the voice glow
and the panel's shader effects are Metal renderers by design.

### Names

The panel is **Boltty AI**; the screen-and-voice feature is **Ask Boltty**.
They used to be *Ask Boltty* and *Talk*, and **stored keys keep the old
spelling**: `boltty.askBoltty.*` and `boltty.askBolttyHotkey*` (the panel),
`boltty.talk.*`, the shortcut id `askBoltty`, `Conversation`'s `"isTalk"` key,
the Settings page raw value `"talk"`, the `talk-` prefix of screenshot files.
Never call the panel "Spotlight" in UI text. An agent's own name is used only
where Boltty names that agent (a picker row, a status line, an error).

## Architecture

| Layer | Where |
|---|---|
| Conversation model | `Chat/Model/` |
| Store, ordering, persistence | `Chat/Store/Conversation{Store,Persistence}.swift` |
| Engine — the one seam between store and adapters | `Chat/Store/ConversationEngine.swift` |
| Adapter protocol, capabilities, registry | `Chat/Agent/AgentClient.swift`, `AgentCapabilities.swift`, `AgentRegistry.swift` (`FakeAgentClient` drives tests) |
| Line-protocol plumbing | `Chat/Agent/JSONLineProcess.swift`, `OneShotCommand.swift`, `JSONObject.swift` |
| Adapters | `Chat/OpenCode/`, `Chat/ClaudeCode/`, `Chat/Codex/`, `Chat/Grok/`, `Chat/Antigravity/` |
| CLI records, transcript readers, usage stats | `Chat/Native/` |
| Panel ↔ conversations | `Chat/BolttyAIConversations.swift` (implemented by `ChatWorkspaceCoordinator`) |
| Panel | `UI/AgentPalette*`, metrics in `UI/AgentPaletteMetrics.swift` |
| Notch face | `UI/NotchMascotController.swift` |
| Mascot | `Chat/UI/ConversationAvatar.swift`, `MascotRenderer.swift`, `MascotShaders.metal`; `Models/MascotShape.swift`, `MascotPalette.swift`, `MascotLook.swift` |
| Screen selection | `Services/ScreenRegionCapture.swift`, `Models/ScreenSelection.swift`, `UI/ScreenSelectionOverlay.swift` |
| Shader effects | `UI/Effects/` |
| First run | `UI/FirstRunShowController.swift`, `UI/Settings/SetupWindow.swift` |
| Permissions window | `Services/AccessPermissions.swift`, `UI/Settings/AccessPermissionsWindow.swift` |
| Settings | `UI/Settings/` |
| Ask Boltty | `AskBolttyController.swift`, `Chat/AskBoltty/`, `UI/AskBolttyOverlayController.swift`, `UI/AskBolttyTrailLayer.swift`, `UI/AskBolttyDrawingLayer.swift` |
| Dictation, speech, sounds | `Services/` (`BilingualDictationEngine`, `SpeechOutput`, `InterfaceSounds`), sounds rendered by `scripts/render-sounds.py` |
| Updates, login item, releases | `Services/AppUpdater.swift`, `Services/LoginItem.swift`, `scripts/release.sh`, `scripts/bump-version.sh` |

**A provider is added behind `AgentClient` or not at all**: an adapter, and one
line in `AgentRegistry.live()`. The store, engine, panel and Settings speak that
protocol and nothing below it. Pi and Gemini are discoverable on PATH but have
no adapter; never offer a toggle for them.

## Locked decisions

| | |
|---|---|
| Stack | Swift, AppKit; SwiftUI only in `UI/Settings/`. No web view, no embedded terminal |
| Platform | macOS 26.0+, hardened runtime in Release. Universal DMG on GitHub releases, GPL-3.0-or-later. Not the App Store (private API, no sandbox) |
| Return in the panel | Starts a conversation **in the background**: no window raised, no `NSApp.activate`. An empty Return starts nothing and plays the system alert |
| Agent choice | ⇧Tab on the first screen walks ready, enabled agents (`AgentHistory.tabOrder`); `nil` is automatic routing (the preferred agent). Fixed once the conversation has a session. A chosen agent that stops being ready is refused out loud, never swapped |
| Tab on the first screen | Walks folder → microphone → text; Space presses the focused icon |
| Working folder | New chats start in `$HOME`. Chosen with the folder chip until the session exists, then fixed |
| Persistence | Conversations persist and are never replayed or re-executed. A chat stored mid-turn comes back `interrupted`, not `idle` |
| One writer | `ConversationPersistence` takes a `flock` on `owner.lock`; a second Boltty runs read-only and the tray says so |
| Closing | Closing a window backgrounds it. ⌘Q is **Close Boltty**: windows go, Boltty drops to `.accessory`, work continues. A real quit is only *Quit Boltty* (tray or app menu), with no chord; it stops every turn and adapter on an 8 s deadline |
| Dock click | Brings Settings forward, never the panel |
| Launch order | Hotkey, menu, tray, `.accessory` — then load conversations, so ⌥Space works from the first moment |
| Execution states | `idle`, `working`, `waiting`, `failed`, `interrupted`, `rateLimited` |
| Progress words | `Working`, `Thinking`, `<verb> <object>` for tool events, `Needs your approval`, `Needs your answer`, `Listening`. Reasoning traces are never shown |
| Auto-approve | Off by default; chosen per agent in Settings › Agents › Permissions and copied into each new chat; the composer's Ⓐ (`a.circle`) switches it per chat. `acceptEdits`-level, never a full bypass (except Antigravity's flag, behind Boltty's gate) |
| History | Boltty's own conversations only. CLI sessions started in a terminal are not listed or adopted |
| Settings holds only what exists | A stored value with no control is removed. Removed keys stay inert on disk: never rewritten, never deleted |
| Updates | Asked, then installed by Boltty's own `UpdateInstaller`. No installer framework, no signing key to guard |
| Packages | None. A dependency is asked about first |

## Invariants (the linter fails on each)

`scripts/lint-architecture.sh`:

- Execution does not belong to a view. `AppDelegate` owns store, engine and
  coordinator; nothing under `UI/` mentions `Process(`, `JSONLineProcess` or a
  `*Client`. The palette controller holds only a `weak` reference to the
  conversations.
- Hiding the panel never touches a process. Only
  `applicationShouldTerminate` → `prepareForTermination` ends CLIs.
- SwiftUI state lives only in `UI/Settings/`.
- One home each for `NSPanel` (`UI/KeyablePanel.swift`), `NSStatusItem`
  (`StatusBarController`), `RegisterEventHotKey` (`GlobalHotkeyService`), and
  `CGEventTap` (`Services/ModifierHotkeyMonitor.swift`, for the opt-in ⌥⌘ chord
  and Ask Boltty's ⌃⌥⌘).
- Resume only by stored id: `--resume <id>`; never `--last` or `--continue`.
- No `bypassPermissions`. `--dangerously-skip-permissions` appears only in
  `AntigravityClient`, beside its gate.
- The shell is called in one place: `JSONLineProcess.locate`'s `command -v`
  fallback. Prompts go down stdin, never through `sh`.

A check that could not run is not a check that passed: both linters fail when
a directory they guard is missing or a rule's regex does not compile.

## A child process can die at any moment

- Boltty ignores `SIGPIPE` (`main.swift`); a write to a dead CLI throws `EPIPE`
  and the adapter's exit path takes over.
- Writes to one child are serialised (`JSONLineProcess.writeLock`).
- An actor that suspends while starting publishes its start task first, so a
  second caller does not start a second server.
- The exit report carries the CLI's last stderr line, read non-blocking before
  reporting the exit. A CLI that refuses its arguments says why on stderr and
  exits; `createSession` throws `serverStartFailed` with that line.
- An exit handler checks it is still current before clearing state.
- A deadline is a timer, not a check in a read loop. A timer inside a task group
  is not a deadline (the group waits for every child). Model scans race a timer
  per agent (`ConversationEngine.modelList`, 30 s).
- A blocking call never runs inside an actor. Every one-shot CLI read
  (`--version`, `login status`, `opencode models`, `command -v`) goes through
  `OneShotCommand`: handlers, a deadline, SIGTERM then SIGKILL, and no waiting on
  a grandchild that holds the pipe.
- A provider that has forgotten a session is recoverable: the engine drops the
  dead id and opens a new session, once per send (`ConversationEngine.deliver`).
- Work per token is coalesced: tray rebuilds on a changed snapshot, preview
  observers once per run-loop turn, the SSE parser resumes its scan.

## Boltty is a wrapper

An agent launched through Boltty can do what the same CLI does from the
person's terminal. App Sandbox is off by design. **"Boltty lets the agent see or
do X" is not a finding.** A finding is Boltty *widening* what the CLI had, or
something Boltty generates escaping where it should not. So the environment is
inherited whole (filtering breaks `gh` and `git push` and removes no
capability); what Boltty generates stays its own — `OPENCODE_SERVER_PASSWORD`
goes to its own server's process only. Boltty controls what the agent *does*
(approvals, working folder, permission mode), not what it can reach.

## Adapter facts

Each of these was measured against the installed CLI, and most produced a wrong
implementation first. Versions say what was measured.

### Claude Code

- `--session-id` takes a UUID Boltty mints and nothing else; anything else is
  refused with exit 1 before stdout. Session id format belongs to the adapter
  (`AgentClient.makeSessionID()`).
- The `initialize` control request returns the model list (with effort levels),
  the account, slash commands and permission mode, at no token cost; `probe()`
  and `availableModels()` use a throwaway process for it. That process runs with
  `--strict-mcp-config` and `--settings {"disableAllHooks":true}` so it starts
  none of the person's MCP servers or hooks.
- An expired login still answers `initialize` with an `account`:
  `{"tokenSource": "none", "apiProvider": "firstParty"}`, no email (2.1.296;
  `claude auth status` says "Login: Expired"). `ClaudeCodeClient.isSignedIn`
  reads that; `probe()` drops the cached handshake so a new sign-in is seen.
- `--permission-prompt-tool stdio` is what makes it ask; without it print mode
  decides alone.
- A `deny` answer to `can_use_tool` carries a `message`, which the model reads
  as the tool's result; Boltty frames the person's words as theirs
  (`ClaudeCodeClient.denialMessage`).
- Text arrives twice (`stream_event` deltas, then the whole `assistant` frame):
  take text and thinking from `stream_event`, tool calls from `assistant`.
- Words written to stdin mid-turn join that turn (2.1.296) — that is ⌘Return
  (`steer`). Send no `priority`. The CLI files them as an `attachment` of type
  `queued_command`; the transcript reader reads that as the user's message.
- A command left running in the background can end after its turn; the CLI then
  opens a turn of its own (`system init` while idle, a reply, a `result`).
  Fixture: `Fixtures/claude-background-wake.jsonl`.
- History is `~/.claude/projects/<mangled-cwd>/<session-id>.jsonl`. The folder
  name is lossy; take `cwd` from the records.
- Read-only chats run with `--tools Read,Glob,Grep` (variadic flag: another
  flag must follow it).

### Codex

- `codex app-server` is the surface (JSON-RPC over stdio, one server, every
  thread). `codex app-server generate-json-schema --out DIR` writes the schema;
  read it instead of guessing.
- A local picture is `localImage` with a `path`.
- Approval decisions are `accept` / `acceptForSession` / `decline` (and
  amendments, `cancel`). None carries words, so a refusal in words is decline,
  `turn/interrupt`, and the words as the next message.
- `item/tool/requestUserInput` is a real multiple-choice question; the answer
  maps question id to the option's `label`.
- A turn is the message: one bubble per turn.
- `thread/resume` writes to the rollout, so threads are **read** off the rollout
  (`CodexRolloutTranscript`) and resumed only to send, with `excludeTurns: true`.
- Unread notification methods are refused at `initialize`
  (`optOutNotificationMethods`); a method Boltty starts handling comes off the
  list.
- An idle thread is unsubscribed after 10 minutes so its MCP servers stop.
- Boltty runs its own app-server over stdio and does not use the terminal's
  shared daemon.
- Requests sent with files or from the in-app browser wrap the typed words under
  `## My request for Codex:`; `CodexRolloutTranscript.request(in:)` unwraps it
  *after* dropping scaffolding (the reviewer's wrapper carries the heading too).
- Read-only chats use `sandbox: read-only`.

### Grok

- `grok agent stdio` is the surface (ACP). Not `headless`, `serve` or `leader`.
- **Start it as `grok --permission-mode default agent stdio`**: otherwise the
  person's `~/.grok/config.toml` decides and may be `always-approve`. The flag
  is global, before `agent`. `acceptEdits` changes nothing over ACP.
- The native installer puts `grok` in `~/.grok/bin`, which is in
  `ExecutableLookup.searchDirectories` (a GUI launch has a short PATH).
- Grok mints session ids (`session/new`). `session/load` replays history as
  notifications into the asking process and is **not** a read; read
  `chat_history.jsonl` (`GrokChatHistoryTranscript`). `send` loads a session it
  has not seen (`ensureLoaded`).
- `session/prompt` returns only when the turn ends; streaming is
  `session/update`. `session/cancel` is a notification, not a request.
- `session/set_config_option` takes `configId`; `reasoning_effort` is the one
  that matters. The model catalogue, with per-model efforts, is in
  `initialize`'s `_meta.modelState` (1.0.52); a throwaway `session/new` is the
  fallback only, because it starts MCP servers.
- Pictures: `initialize` says `image: false`, but an ACP `image` block reaches
  the model (1.0.50). The adapter declares `.images`.
- Typed text sits inside `<user_query>`, beside `<image_files>` and
  `<user_info>`; the reader takes it out with `InjectedText.inside`.
- Permissions are `session/request_permission`, answered with a response by
  option `kind`. An edit offers allow-for-session / allow-once / reject-once;
  a command also offers always-allow / reject-always. `reject_once` ends the
  turn (`stopReason: cancelled`), so a refusal in words is reject,
  `session/cancel`, and the words as the next message.
- Permission mode is process-wide; Auto Mode is Boltty answering `edit` asks
  "allow once"; commands still ask.
- Questions are `x.ai/ask_user_question` (from t3code's adapter, not yet seen
  live); plans are `x.ai/exit_plan_mode` with `planContent`, answered
  `approved` / `cancelled` (+ `feedback`) / `abandoned`. A plan is
  `PendingInteraction.Kind.plan`, drawn as the turn's text with Approve /
  Request changes / Quit.
- `_x.ai/billing` gives the plan's `creditUsagePercent`.

### Antigravity

Measured on agy 1.3.4 and 1.4.0 (`AntigravityClient`, `AntigravityTranscript`,
`AntigravityLiveTests` with `BOLTTY_LIVE_AGY=1`).

- `--print=` (empty, attached, last); a bare `-p` swallows the next flag.
- Input is only `{"event": "user", "message": {"content": "…"}}`; output is
  NDJSON on `event`: `init`, `step_update`*, `result`. Take text from
  `text_delta` only; `result.response` repeats it.
- `content` stays a string: any non-text block ends the run. So it declares
  `.attachments` not `.images`; pictures go as paths and `agy` opens them with
  `read_file` / `view_file`. Print mode refuses reads outside the folder, so
  the gate lets through reads of exactly the files a message carried
  (`AntigravityToolPolicy.readGrants`).
- A turn can succeed with nothing said (e.g. it tried a refused command to read
  a picture).
- `init` arrives before any prompt and names the conversation; Antigravity mints
  the id. `--conversation <id>` resumes.
- **Print mode cannot ask**, so Boltty asks through a `PreToolUse` hook
  (`AntigravityPermissionGate`). The hook can deny but not allow, so the
  process runs with `--dangerously-skip-permissions` and the gate decides
  every call. The flag is allowed only there (linter rule 7).
  - The hook fails closed: crash, garbage, `{}`, timeout all block. Exit 0 with
    empty stdout lets the call through, so the script exits 1 unless its answer
    file is non-empty.
  - Installed in `~/.gemini/config/hooks.json` under the key
    `boltty-permission-gate` (other keys untouched; non-JSON files left alone),
    on the first Antigravity start. Outside Boltty (no `BOLTTY_AGY_GATE`) it
    answers `ask`, which changes nothing.
  - Hand-over is files in the folder `BOLTTY_AGY_GATE` names: `<id>.req`, then
    `<id>.ans`, watched with `DispatchSource`. Plain `sh`, no `nc` or Python.
  - Policy (`AntigravityToolPolicy`): reads inside the chat folder, inside
    `~/.gemini/antigravity-cli`, and of files a message carried go quietly;
    everything else, every command, edit, browser, MCP and unknown tool asks.
    Auto Mode lets edits inside the folder through. "Always allow" lasts for the
    chat while Boltty runs.
  - Ask Boltty's read-only prompt tells it to open the screenshot when the
    picture did not come with the message, and that the read is allowed; told
    only "do not use tools", `agy` answered without looking.
- Plan limits: `agy -p=/usage --output-format json` (~4 s, no model call);
  groups of weekly buckets, each labelled (`AgentUsageWindow.title`).
- SIGINT stops a turn (`result` with `error: "interrupted"`, exit 1): declared
  `.interrupt`, not `.terminableTurn`.
- Effort is part of the model id (`gemini-3.8-flash-high`); `--model` takes the
  base and `--effort` the level.
- The record is SQLite in WAL: open `mode=ro` while `agy` runs, `immutable=1`
  after it exits.
- Steps are protobuf without a schema (`ProtoFields`): `step_type` 14 is the
  person (text 19.2), 15 the reply (text 20.1, thinking 20.3 never shown, calls
  20.7), 17 an error (24.3.1); status 7 refused/failed, 3 done; call id 5.4.1,
  time 5.1; 101 is scaffolding. Usage: tokens at 5.9 (2 in, 3 out, 5 cached),
  model at 5.9.1.

### OpenCode

OpenCode 2.0 renamed much of its API; one build of Boltty speaks both 2.0 and
1.18, and the code accepts both spellings. **Take the version from
`opencode --version` when measuring.**

- **Use `/api/*`**, not the legacy routes: it accepts caller ids and has a
  durable per-session sequence (sent-exactly-once, reconnect without
  duplicates). The OpenAPI document is `GET /openapi.json` on 2.0.
- Live events are `session.*` (2.0) / `session.next.*` (1.18), never
  `message.*`. A turn ends with `session.step.ended` `finish: "stop"`, then
  `session.execution.succeeded` on 2.0. `OpenCodeLiveEventShapeTests` pins it.
- 2.0 field renames: `ordinal` instead of `textID`/`reasoningID`, `id` for
  `callID`, the tool name only on `session.tool.input.started`, user messages as
  `inboxID` + `item.payload`, `permission.*` instead of `permission.v2.*`.
- An interrupted turn is `aborted` on 2.0 (`MessageAbortedError` on 1.18);
  `MessageFailure.isAbort` takes both.
- No event marks a reply complete; the store stamps the last reply finished when
  the turn goes idle.
- 2.0 content parts have no `id`; every field in `OpenCodeDTO` is optional.
- Prompt body on 2.0 is flat `{id, text, files}`; `delivery: "steer"` (2.0.27)
  joins the running execution — that is ⌘Return.
- Permission answers are `decision` on 2.0 (`reply` on 1.18). Send 2.0's and, on
  a 400 only, retry with 1.18's. A gone permission is `404
  PermissionNotFoundError` → `requestGone`.
- **"Always" is Boltty's rule for the chat** (`OpenCodeAllowances`): OpenCode
  saves `always` for the whole project on a shared service, so Boltty answers
  `once` and remembers the save patterns for the session.
- Questions are forms on 2.0 (`form.created` / `form.replied` /
  `form.cancelled`, `POST …/form/{id}/reply` with `{"answer": {key: value}}`,
  `DELETE` to cancel). **A field's answer is in its type**: string, boolean,
  number, `true` for external, an array only for `multiselect`. The `question`
  tool's form always allows a typed answer (`custom: true`). An already settled
  form answers `409` → `requestGone`.
- Auth is Basic with user `opencode`; Boltty's own server gets a fresh
  `OPENCODE_SERVER_PASSWORD`, never logged. The port is read from the server's
  stdout (`--port 0`).
- **Boltty uses the user's background service when it runs** (`opencode serve
  --service`, url and password in `~/.local/state/opencode/service.json`), and
  never starts, stops or reconfigures it. A refused connection or a 401 makes
  `OpenCodeServer` re-read the file (upgrades replace the process). With no
  service, Boltty starts and owns its own server, reaped after a crash from a
  ledger in Application Support (tests use their own ledger).
- The model catalogue is `/api/model` on 2.0 (`/provider` on 1.18); free models
  have `settings.apiKey == "public"`.
- **The free tier refuses a session whose id is not in OpenCode's own
  spelling** (`FreeTierError`, measured 2.0.12–2.0.27). Free-model sessions are
  therefore server-named; minting OpenCode's spelling in
  `AgentSessionID.opaque()` would let them be caller-named again. Do not report
  this upstream on the person's behalf.
- `GET /session/{id}/message` caps `limit` at 200; page with
  `order=desc&limit=200`, then `cursor=` alone (never with `order`), up to
  `transcriptMessageCap` (1 000).
- A reconnect asks `GET /api/session/{id}/history?after=<seq>` what was missed;
  only a definite "nothing" skips the re-read.
- OpenCode labels foreign errors `type: "unknown"` with the real JSON nested in
  the message; `OpenCodeMapper.unwrapProviderEnvelope` reads it out.
- A bare `OpenCodeClient` subscribed to `/api/event` hears nothing in tests;
  drive OpenCode through `ConversationEngine`.
- `"\r\n"` is one `Character` in Swift; the SSE parser is byte-based.

## Reading the CLIs' records

Where each CLI keeps sessions (private formats — read defensively):

| CLI | Where | What Boltty reads |
|---|---|---|
| Codex | `~/.codex/sessions/YYYY/MM/DD/rollout-…-<id>.jsonl` | the rollout; `session_index.jsonl` only for titles (it is not an index) |
| Claude Code | `~/.claude/projects/<mangled cwd>/<uuid>.jsonl` | the file |
| Antigravity | `~/.gemini/antigravity-cli/conversations/<id>.db` | `steps` rows |
| Grok | `~/.grok/sessions/<encoded cwd>/<id>/` | `summary.json`, `chat_history.jsonl` |
| OpenCode | `~/.local/share/opencode/opencode.db` | `session_v2` plus 1.18 `session` rows v2 never copied (and only those with messages); read-only, named columns — the file also holds credentials |

- One timestamp reader, `ISO8601Stamp` (a scan; `ISO8601DateFormatter` per
  stamp is ~3000× slower).
- Transcripts are read from the end (`FileTail`, scanned with `memchr`); rows
  from the head (`FileHead`).
- Absent is `sessionNotFound`, unreadable is `transport`. A session running here
  that the CLI has not written yet is answered from what is live.
- Every CLI files scaffolding under `role: user`. `InjectedText` holds the
  measured tag lists per CLI — named tags, never a `<` or `#` prefix test.
  Claude Code also files image bookkeeping (`[Image: source: …]`) as separate
  user records.
- Directory names are lossy; paths come from the records.
- Nothing in Boltty deletes a CLI's session. Boltty's own Delete and Clear
  History trash Boltty's records only.
- Two sweeps check the readers against every chat on the machine
  (`TEST_RUNNER_BOLTTY_SWEEP=<dir> ./scripts/test.sh NativeTranscriptSweep`,
  `TEST_RUNNER_BOLTTY_OPENCODE_SWEEP=<dir> … OpenCodeTranscriptSweep`): nothing
  invented, no assistant turn lost, and a histogram of what is shown as the
  user. The ground truth is a second reader written in the sweep. Write
  fixtures from real files, not from what the parser expects.

## The panel

The loop that must keep working:

```
⌥Space → the panel (drips out of the notch)
  → optionally drag across the screen to ask about a region
  → type or dictate, Return → conversation starts in the background
  → the shell morphs into the open chat
  → follow up in the same composer; ↓ lists saved chats
  → Escape: chat → (list if it came from there) → first screen → hidden
  → a click outside or the hotkey hides it without stopping work
  → reopened within a minute it returns to the chat it left
  → notify when the agent needs attention or finishes
```

- **One shell, one spring.** Prompt, list, chat and listening orb are states of
  one glass shell (`PaletteGlassHost`), morphing on a critically damped spring
  (`surfaceResponse` 0.3). Content is never scaled. Under Reduce Motion
  geometry settles directly.
- **It drips out of the notch** (or the top edge): the shell itself, on its own
  retargeted spring (`beginDrip` / `beginDripOut`, `PaletteDrip`). Keyframes on
  a glass view's layer do not move the glass; the view's frame does. Never put
  the shell in an `NSGlassEffectContainerView` (it draws the glass above the
  host and ignores its clip). The prompt takes keys from the first frame. Off in
  the unit-test host.
- **Locked to the top centre** (`lockedTopGap`), never movable. The open chat
  and the list resize by sides, foot and an iPadOS-style corner grabber; the
  centre stays put. The cursor reaches the screen from a non-activating panel
  through `BackgroundCursor` (private `CGSSetConnectionProperty`, looked up with
  `dlsym`). Sizes are kept in `BolttyAISurfaceSizes`.
- **Sizes:** first screen 540 × 85 capsule, grows up to five lines; list five
  rows; chat 584 × 680 default. They reserve their space; short content does
  not shrink them.
- **Return while a turn runs queues** (one slot, shown, cancellable).
  **⌘Return** steers where the agent declares `.steering`. **⌘.** stops where it
  declares `.interrupt` or `.terminableTurn`; the Send slot turns into Stop.
- **Key hints after the typed text** read like Siri's "ds — Ask Siri": an em
  dash, then the first hint in secondary ink at the typed size, with no capsule
  and no key ("— Ask Claude", "— Queue"). Only ever that one: a second hint
  read as a second answer, so neither ⇧Tab's next agent nor ⌘Return or ⌘. is
  suggested (the Send slot turning into Stop says the last). They appear after a 1 s rest, drop from the end when short of room, and
  stand on the typesetter's baseline, never a glyph's location (a chip's
  baseline is its capsule's foot).
- **A chip is the owner's glass picture**: one PNG per kind in
  `Resources/ChipGlass` (a folder reference), its word drawn in it — "file",
  "image", "text". `PromptChipCell.picture(for:)` draws it at the capsule's
  height, as wide as its aspect. So a chip names its kind, not its item; what
  each holds is under the pointer (`PromptChipPreview`). The tinted capsule with
  a symbol is only the fallback for a kind with no picture. Not a thumbnail of
  the file: the glass is the point.
- **The black ramp** is worn by the first screen only, and only once the state
  has settled (`applySurfaceStyle` defers changes *to* a wash to the end of the
  turn).
- Refreshing rows never orders the window forward or steals first responder.
- **Clicking outside** (a click, not a drag) hides; the panel takes every press
  on the screen, so a click outside does not reach the window below.

### The transcript

- The question is a white bubble with black text; the answer is prose on the
  glass, Codex's proportions (headings 1.5/1.25/1.125×, line 24 on 15).
- **Tool calls are rows, folded into one pill per run of work**
  (`PaletteActivityGroupView`), said in one line ("Thought • Read 3 files •
  Edit config.ts"). Messages with no words of their own join the next
  (`PaletteTranscript.joined`), so every agent's turn draws alike.
- A finished turn with work gets "Worked for …" and folds to its last prose. A
  running turn, the first one included, shows the transcript and under it a
  working line with the agent's face.
- Streaming prose: finished paragraphs are rendered as markdown; the paragraph
  still growing is plain text with words fading in through the agent's light
  (`MascotPalette.arrivalLight`).
- Only files a turn **made** get cards; reads and searches leave rows only.
  Pictures get Quick Look thumbnails that resolve out of a blur.
- What the person sent with chips is shown as file cards over their words
  (`Conversation.sentFiles`, `SentFile.lift`), stored on the conversation
  because providers re-file requests under their own ids.
- A failure belongs to the turn that produced it; once the agent speaks again
  it draws no card. A failure is never a bubble.
- The answer text view is contiguous layout: non-contiguous layout drew long
  answers blank when first shown at their foot.
- Block borders are filled, never stroked (wide strokes hit Core Animation's
  wide-line renderer, which can hand Metal a zero-instance draw). A Debug build
  stopped on a Metal assertion is paused, not hung — `sample <pid>` it.
- Sizes are arithmetic: the same function measures and draws.

### The permission card

- Asked the way a Mac asks: the sentence as title ("Run this command?"), what
  it is about verbatim in a well (tool name as a label, command in mono, long
  commands cut at six lines with "Show N More Lines"), the answers as dialog
  buttons, right to left from the default. The reach of "Always allow" is a
  caption over the buttons.
- **Return confirms the first answer**, as the CLIs do. Do not change this
  without a new reason.
- **Words typed on a permission card refuse it and go to the agent**
  (`.permissionMessage` where the protocol carries them; otherwise refuse,
  stop, and queue the words). A refusal this press did not deliver stops and
  queues nothing and keeps the words.
- Questions: digits answer on an empty composer (not on a permission); a
  question that takes typed answers says so.
- An ask that is gone (`requestGone`) takes its card away, raises no notice and
  re-reads the conversation.
- All cards that ask or wait share one scale and one set of gaps
  (`serviceEyebrow*`, `service*Gap`).

### The chat list

- Boltty's conversations only, grouped by day, with tabs: **All** (stored and
  coded as Latest) then one per adapter in `AgentHistory.tabOrder`, always all
  present. All wears the faces of enabled agents, arranged like die pips.
- Only the chosen tab's face is alive; the live face wakes out of, and returns
  to, the still picture (`handOver`, `awake`) so switching never jumps.
- Rows are built lazily near the viewport (`ResultsListView`); a filtered row is
  hidden in place. A row's preview stops at 400 characters.
- A row's title is the first request, cleaned of brackets and Boltty's paths
  (`ChatTitle`). Unread rows have a blue dot and a semibold title; working rows
  have a hairline in the agent's gradient orbiting the pill.
- The order holds while the list is open.
- The foot holds two glass discs, apart on purpose (a shared capsule would
  say they act on one thing): **New Chat** (+, ⌘N) lower right opens the first
  screen on the chosen tab's agent — All on automatic routing; a tab whose
  agent cannot take a prompt keeps it disabled — and **Settings** (gear) lower
  left, 18 from the foot and side (`historyFootDiscInset`). They stand inside
  the corner resize grips, which give way on a disc; the rows dissolve under
  them.
- Right click: Open Chat, Show in Finder, Delete Chat… (Boltty's own; to the
  Trash, after asking, no Return on the destructive button). No pin.
- Typing after ↓ searches. `/` is plain text; there is no command menu.

### Selecting the screen

On the first screen only, a press on empty glass that moves past 4 pt draws a
region. ScreenCaptureKit freezes the display (Boltty's windows excluded), the
outside dims to 40%, the border is light in the agent's gradient
(`ScreenSelectionGlowView`), and the shell stands beside the region. The
pointer stays an arrow; only handles show resize cursors. On Return the region
is cut off the main thread: the region at display pixels, the whole screen at
1568 with the region outlined, the app and window under it, and Vision's text in
`<screen-text>` — to every agent. Pictures go as pictures where the adapter can
take them (≤ 3.75 MB), otherwise as paths. Screen Recording is asked the first
time; refusals are said in the panel.

### The folder chip

Home is the folder glyph alone; elsewhere the folder's name (and git branch,
read from the repo's files without running `git`) on a light pill. A click opens
a menu: Show in Finder, Copy Path, Open on GitHub, No Folder, Recent (up to
five, from Boltty's chats), Open Folder…. Once a chat has a session, only the
actions remain.

### Listening

Pressing the microphone on the first screen collapses the shell into an orb of
the face's colours, drawn **on top of** the glass (the glass frosts what is
under it); it grows into a capsule round this take's words. At rest the orb is
near black with a faint lit rim. **The light lives at the edge, not the
middle**: the voice (on a square root, so an ordinary word is already bright)
fills the rim unevenly — how far in it reaches swells in waves running round
the edge — and sends ripples in from it that die before the middle. Its colour
walks the face's own gradient (`orbWalk`), so two colours meet through the
stops between them. Anything that follows the angle round the edge fades out
toward the middle, where every angle meets (`rimward`), or it draws a
pinwheel (`orbGradient`). In an open chat a
non-empty draft keeps the composer. Enter is ✓, which waits for the engine's
final text. A long silence sends, but only after speech was heard.

## Ask Boltty

- **The chord** (`ModifierHoldMonitor`): exactly ⌃⌥⌘ held 0.25 s begins; releasing
  any of the three sends; a key, a click or a fourth modifier cancels. Needs
  Input Monitoring, asked when Ask Boltty is switched on. Escape stops an answer
  and clears its drawings.
- While held: the chat and session warm up, the screen is frozen, the pointer's
  path is drawn as a soft, short-lived line (`AskBolttyTrailLayer`, curves
  through midpoints, runs of 20 points), and speech is recognised and shown
  beside the face as it comes (the latest words, up to three lines).
- Sent: the whole screen at 1568 px with a ring at the pointer and the traced
  line, the window under the pointer, and `AskBolttyPrompt.bracket` (answer in
  one or two sentences, in the asker's language, point and draw with tags).
  Nothing said is nothing sent, and leaves no chat.
- Tags: `<point x y label/>`, `<circle>`, `<box>`, `<arrow>`, `<line>`,
  `<path d>`, `<label>`, `<board>…</board>`, coordinates 0–1000 of the picture.
  Each is shown when the reading reaches its sentence; drawings stay until the
  next question, a click or Escape. The chat card strips the tags.
- At most two sentences of an answer are said, one at a time: a new sentence
  takes the last one's place (`captionSentences`, `answerSentences`).
- The answer types out beside the face with blips (`AskBolttyBlips`, rendered on
  Core Audio's thread — its block is made `nonisolated`). Reading aloud
  (`SpeechOutput`, only Siri's 19 languages) exists behind
  `AskBolttySession.speaksAloud`, off.
- The overlay is one `PassivePanel`; frames are snapped to pixels so the face's
  drawable never reallocates.
- Ask Boltty chats raise no banner, unread mark or notch line, are never listed,
  and are forgotten (record, screenshots, session released via
  `AgentClient.release`) ten minutes after the last answer unless working or
  waiting. A chat waiting on the person opens the panel on it.
- Read-only by default (`Conversation.readOnly`): the engine refuses every
  permission, and Claude Code and Codex start without write tools.
- Who answers: the chosen agent and model if ready, else Claude Code on Haiku,
  else the first ready agent that takes pictures.
- Holding the chord again while an answer runs stops the voice **and the
  agent's turn** (`stopTurn`), so the old turn doesn't keep spending the plan.
- **Escape calls an answer off** while it thinks or answers: it stops the turn
  (`ConversationEngine.stop`) and takes the face, its words and its drawings
  away. It arrives through the chord's own tap (`ModifierHoldMonitor.onEscape`
  — the one key that tap reads by code, alone and outside a hold), so it needs
  nothing beyond Ask Boltty's Input Monitoring; the overlay itself takes no
  keys.

## Other surfaces

- **Notch face** (`NotchMascotController`): a black circle beside the camera
  housing, one face per agent with something to say (up to four, most urgent
  nearest the notch). It speaks a line ("Needs your approval · Claude",
  "Done · <chat>"); approvals and questions hold their line, others fold after
  6 s. No circle when there is nothing to say. Never key, never activates.
- **Permissions window**: four rows (Microphone + Speech, Screen Recording,
  Notifications, Finder Automation), each Allow / spinner / check / Open
  Settings…, re-read every 1.5 s. Allow All asks in order, Screen Recording
  last. Permission callbacks are never main-actor isolated (TCC calls them on
  its own queue).
- **First run**: a show over a sunset (`SunsetView`, `ShowSpace` maps 1800 × 1169
  slides to the screen; one face carried through every scene; its own clock,
  `ShowClock`), then the setup card (agents, faces, keys, permissions) on the
  panel's glass. `-boltty.replayIntro YES`, `-boltty.skipShow YES`,
  `-boltty.setup.step N` in Debug. Launch with `open`, never the binary from a
  shell (TCC would attribute the request to the shell's app).
- **Settings**: a sidebar of pages (General, Agents, Usage, Voice, Ask Boltty,
  Shortcuts), standard parts only. The selected page is
  `boltty.settings.page` (`-boltty.settings.page agents` opens a page). The
  sidebar highlight is its own `@State`; the window is sized after its view
  controller is set; the sidebar width modifier is last on its column.
- **Usage**: plan windows per agent, 14 days of activity, and an overview counted
  off every CLI's own records (`AgentStatisticsReader`, cached per file in
  `Application Support/Boltty/Usage/statistics.json`). Never summed across
  agents' different units. Signing in happens in a terminal, so the page asks
  every CLI again whether it is signed in before reading limits: when shown,
  when its window comes forward (at most every 30 s), and on Refresh. A
  signed-out agent's row is its face, name and `AgentId.signInCommand`
  (`claude auth login`, `codex login`, `grok login`); its old limits are
  dropped.
- **Reading aloud** (`SpeechOutput`): Siri's voices are listed to every app
  but spoken only for Apple's; Boltty's process gets compact Samantha in their
  place, silently. They are left out of the list. Settings › Voice picks the
  reading voice for the Mac's language (stored in `boltty.speech.voiceByLanguage`),
  Automatic being the best installed: quality, then the Mac's reading voices
  before Eloquence and novelty ones (`SpeechVoice.standing`).
- **Dictation**: Apple's engine only, optional second language as a second
  recognizer on the same audio (`BilingualDictationEngine`), decided per phrase
  by confidence (`BilingualTranscript`). `fastResults` lowers confidence, so with
  two languages the transcriber is built from options.
- **Sounds**: send (system sound, three variants), done and needs-you (the
  banner's own sound), and the system alert for an empty Return. All synthesized
  by `scripts/render-sounds.py`. One switch silences all. No sound on hover or
  click.
- **Banners**: title = chat name, body = `<status> · <agent>`, never the reply.
  Xcode registers every build product with LaunchServices; unregister scratch
  builds (`lsregister -u`) or banners show a stale icon.

## The mascot

- A ray-marched plush solid (`MascotShaders.metal`): six outlines (`MascotShape`,
  stored as `bloom`, `capsule`, `daisy`, `hex`, `orb`, `triangle`), stuffed by a
  harmonic-distance field computed once per outline; eyes and smile are black
  plugs set into the cloth; matte soft-touch lighting in Oklab under a written
  studio of four softboxes; finishes velvet and fur.
- Six gradients (`MascotPalette`), mixed in Oklab; `lagoon` and `slate` are the
  stored ids of Mist and Lilac. Retired ids still load.
- **Every agent wears its own face**, chosen in Settings › Agents; no two alike
  (`MascotRoster`). Stored as names in `boltty.mascotByProvider`. Where no agent
  speaks, the preferred agent's face is used; Boltty has no face of its own.
- One `MTKView` per face, one shared pipeline, drawn on demand from the shared
  60 Hz `MascotClock` timer (a display link measured worse). `currentDrawable`
  only inside `draw(in:)`. Nothing on the canvas may force an offscreen pass (no
  filter, mask, `masksToBounds`). Two rays a pixel live, four for stills; extra
  rays only where a 2×2 quad disagrees; `shadeSolid` is `noinline`; the march is
  bounded by a box.
- Motion is Boltty's own (`MascotMotion`): layered attention, breathing and one
  action at a time; pokes pick a different reaction each time. Signs: yaw right,
  positive pitch up, roll clockwise, lift down.
- Judge looks from the contact sheets (`TEST_RUNNER_BOLTTY_CONTACT_SHEET=<dir>`),
  which draw into sRGB on purpose. `half` is a type in Metal.

## The voice glow and shader effects

- The glow (`UI/Voice/`) is a Metal view **under** the shell's glass: rays of the
  face's colours whose angle-noise streams outward, moved by an integrated
  `flow` so speed changes never jump. Nothing in it has an edge. Reduce
  Transparency puts it over the shell. Never `presentsWithTransaction` (it
  starved the run loop).
- The listening orb is drawn by a second view on top of the glass.
- `UI/Effects/`: a thumbnail's reveal out of a blur, a sent chip's whip toward
  its card, the selection border's light. Each always ends by a timer, is made
  through `make` (a failable `NSView` init crashes), and uploads textures as
  8-bit sRGB.

## Design contract (AppKit)

- **Glass is the system's**, in four kinds: the shell (`PaletteGlassHost`, bare
  regular glass; only the first screen adds a black ramp), controls (the same
  glass), glass buttons (`NSButton` with `.glass` bezel — `GlassCircleButton`,
  `GlassPillLabelButton`), and the selected history tab. Density goes *over* the
  glass, never into its tint. The system's Tinted/Clear setting is respected.
  A glass host's corner must be set again whenever its size changes.
- The shell casts two shadows: a tight contact one and a broad pool behind the
  glass with the shell's shape cut out.
- The transcript dissolves under floating controls (a gradient mask, and in the
  history a private `variableBlur` filter); the scroll indicator bends round the
  shell's corners (`PaletteCornerScrollIndicator`).
- **Type**: five sizes in `AgentPaletteMetrics` — 18, 15 (`typeSecondary` and
  `typeChat`), 13, 11; the first screen's 20 is the exception (key hints
  take the typed size). Whole points only, SF Pro Rounded everywhere, no `.kern`.
- **Colour**: `PaletteInk` — system label colours (dynamic) and fills written as
  values (they end up as `CGColor`). Pure white only for primary-action fills.
- **Spacing**: numbers read off a mock go through `fromMock` / `fromHistoryMock`,
  snapped to the half-point grid. The shell's inset is 12, and nested corners are
  concentric (`outer = inner + inset`). The composer's content stands 16 from
  its rim, measured to the ink.
- **Motion**: `Motion.quick`, `.standard`, `emphasizedCurve`, `standardCurve`,
  `pressSpring`; springs as duration + bounce. The panel appears at once. A
  keystroke is answered, not animated. New clocks read `Motion.now` so
  `-boltty.slowMotion N` slows them.
- **Buttons**: every control has hover, press and disabled states;
  `PaletteIconButton`, system glass buttons, or rows. Presses scale about the
  centre (`MotionPreferences.springScale`). A control in a faded surface is not
  under the pointer (`isOutOfSight`). A wrapping label that is a control's face
  sets `isSelectable = false`.
- A shut card holds nothing required that has a size (unsatisfiable-constraint
  logs cost minutes against the debug dylib).
- Forbidden (the design linter fails): literal `layer.cornerRadius`,
  `NSVisualEffectView`, `CIGaussianBlur`, component colour constructors,
  `NSFont.systemFont(ofSize:)`. `scripts/lint-baseline.txt` may only shrink.
- **Help tags** are drawn like a menu row inside the panel, above the control,
  450 ms delay, instant when moving between controls.

## Keyboard shortcuts and the hotkey

- The launch chord is Carbon (`GlobalHotkeyService`), needs no permission, and
  registers first at launch. The tray prints the applied chord, not the stored
  one. `applyHotkey` keys idempotence on the last *attempt*, so a refused chord
  stays retryable. Never leave the app with no working hotkey.
- The recorder probes Carbon before storing (`probe`, throwaway id `0xFFFF`) and
  refuses in place, naming the chord. Carbon never says who holds a chord; never
  word a message that names the holder.
- `HotkeyValidation`: no bare key except F-keys and Escape (F-key codes are not
  contiguous); no ⌘ plus one bare key. `reservedBySystem` stays small.
- A default nobody chose gives way: if ⌥Space is taken and the person never
  chose a chord, the first free `HotkeySuggestions.fallbacks` entry is stored.
- ⌥⌘ alone is an opt-in chord through the event tap (Input Monitoring), fired on
  release, spoiled by any key, click, third modifier or a hold over 1 s; while
  access is pending the previous chord stands in.
- Key names are Latin on every layout (`HotkeyBinding.keyLabel`).
- Menu chords route through `BolttyShortcutRouter` to the main menu first; every
  rebindable row must reach a live `NSMenuItem` (a DEBUG assertion checks).
  Shortcut ids are a storage format. `BuiltInKeyCatalog` lists every non-menu
  key; a key added to the panel is added there in the same change.
- Never use `Date.FormatStyle`: on a locale with a regional override
  (`en_US@rg=uazzzz`) it returns empty strings. Use `DateFormatter` built from
  templates.

## Releasing

- `scripts/release.sh` builds the **last commit** in a temporary worktree,
  universal, into `.release/DerivedData`, signs inside out, and writes
  `Boltty.dmg` and its `.sha256` to `apps/macos/.release/<version>/`. It refuses
  an uncommitted version bump and a version not above the latest release. It
  **publishes nothing**: it prints the `git tag` and `gh release create` for the
  maintainer to run. `--local` builds the working tree for this Mac and installs it
  into /Applications.
- The DMG window is written onto the disk, not asked of Finder (Finder on macOS
  27 drops AppleScript-set icon size, order and background):
  `scripts/make-dmg-layout.py` writes `.DS_Store` into the writable image, using
  `ds_store` and `mac_alias` (pinned, in `.release/dmg-venv`, release-only). The
  background alias names the volume, so it is written on every build. The
  background is `Resources/DMG/background.png` and `@2x`, drawn by
  `scripts/render-dmg-background.swift` until a designed one replaces it.
- Signing: with `BOLTTY_SIGN_IDENTITY` (Developer ID) and
  `BOLTTY_NOTARY_PROFILE`, hardened runtime, notarized, stapled — written,
  never yet run. Otherwise the self-signed "Boltty Development" identity
  (`setup-local-signing.sh`), else ad hoc; not notarized, so the first open needs
  Open Anyway. A stable identity keeps microphone, Input Monitoring and
  Automation grants across versions. Debug builds sign with the same identity
  (`Config/Signing.local.xcconfig`) with hardened runtime off (library
  validation refuses the debug dylib). A grant pinned to an ad hoc build needs
  `tccutil reset … com.boltty.app`.
- Entitlements: `device.audio-input`, `automation.apple-events`, in every build.
- Fixed by the first release: repository `ruslan-enko/boltty`, bundle id
  `com.boltty.app`, asset name `Boltty.dmg`, tag `v<MARKETING_VERSION>`.
  `scripts/bump-version.sh X.Y.Z` sets the version and bumps the build number.
- `LICENSE` and `THIRD_PARTY_NOTICES.md` ship in every copy.
- The README's pictures (`.github/readme/`) are the real panel and overlay over
  Boltty's own sunset, taken by `ReadmeShotsOnScreen`
  (`TEST_RUNNER_BOLTTY_README_SHOTS=<dir>`; it takes the screen for about
  40 s). The recordings become animated WebP with `magick` (GIFs of the sunset
  run to 20 MB).
- **Updates** (`AppUpdater`): `GET api.github.com/repos/ruslan-enko/boltty/releases/latest`
  at launch and hourly when a day has passed, switchable in Settings. A newer
  version turns *Check for Updates…* into *Install Boltty X…*; nothing is
  installed until the person says *Install and Relaunch*. `UpdateInstaller`
  takes only this repository's `Boltty.dmg` and `Boltty.dmg.sha256` assets,
  checks the digest, mounts with `hdiutil`, copies with `ditto` beside the
  running bundle, and swaps it in only if it satisfies the **running copy's
  designated requirement** (same identity, so TCC grants carry over; an ad hoc
  copy can never update itself). It relaunches with `-boltty.updatedFrom <pid>`
  and the new copy waits in `main.swift` for the old one to quit (one writer).
  A release without both assets, or any failure, falls back to the release
  page; the running copy is left as it was. Copies before 0.2.3 only notify.
- **Open at login** (`LoginItem`): `SMAppService.mainApp`; the system's list is
  the only store.

## How to work

1. Read this file, and `.scratch/<feature>/` if work is in flight (gitignored).
2. TDD for pure logic.
3. **Run no tests until the maintainer asks.** Build to check it compiles,
   install with `release.sh --local`, and stop; the maintainer judges by eye. When tests are
   asked for, `apps/macos/scripts/test.sh` picks the suites that name the changed
   types; `--all` once at the end. UI tests only when named.
4. Commit when asked. "Push" means commit on `main` and push. Other sessions
   may be editing the same checkout: check before committing, and commit only
   your own files.
5. A resource folder is a folder reference: in both `project.yml` and the
   pbxproj. `Resources/Sounds` is listed file by file on purpose (banners look
   sounds up at the bundle's top level).
6. UI tests name key positions, never characters
   (`UITestKeyboard.key(kVK_ANSI_C, fallback: "c")`); paste text instead of
   `typeText`.
7. Record a CLI rather than imagine it (`scripts/record-cli.py`, replayed by
   `Fixtures/replay-cli.py`). Strip personal data from recordings.
8. Test defaults are `isolatedDefaults(…)`, never `UserDefaults(suiteName:)`.
9. A failing XCTest looks like a hang; `sample` the test host.
10. The unit-test host launches nothing of the product
    (`AppDelegate.isHostingUnitTests`) and runs as `.accessory`. Live tests shut
    down any CLI they start.
11. Comments say why. Who decided and when belongs in git.
12. **Keep this file current in the same change** that makes it stale. Where this
    file and the code disagree and it's unclear which is right, ask.
13. Never publish anything outside the repo (issues, comments, releases) on the
    maintainer's behalf.

## Build environment

- One DerivedData: `apps/macos/.derivedData` (Xcode is pointed at it too).
- The root `Makefile` wraps the scripts (`make run`, `install`, `dmg`, `test`,
  `lint`). CI (`.github/workflows/ci.yml`) runs both linters and a Debug build
  on GitHub's `xcode-27` image, unsigned; its jobs are skipped while the
  repository is private.
- `project.yml` is the source of truth; `xcodegen generate` (2.46) reproduces the
  checked-in Xcode 27 project except `LICENSE`'s `lastKnownFileType` (keep
  Xcode's line). It rewrites the shared scheme — restore it with `git checkout`.
  Xcode's recommended settings live in `project.yml`.
- No Swift packages.
- `scripts/run-isolated.sh` runs a build with a throwaway `HOME` and a re-stamped
  bundle id, reaping any OpenCode server it started (by `HOME`, never by name —
  the user's service is never touched).

## Communication

The maintainer often writes in Ukrainian; answer in the language you're addressed in.
Code, identifiers and commits are in English. Product name **Boltty**; features
**Boltty AI** and **Ask Boltty**.

## Docs

| File | For |
|---|---|
| `README.md` | people who want to use Boltty |
| `CONTRIBUTING.md` | building, testing, sending changes |
| `ARCHITECTURE.md` | how the pieces fit |
| `CHANGELOG.md` | what changed per release |
| `AGENTS.md` | the rules and facts above |
| `SECURITY.md` | reporting a vulnerability, what counts |
| `THIRD_PARTY_NOTICES.md` | licences of what ships |

Work in flight lives in `.scratch/<feature>/` (gitignored) and moves here, if
still true, when it lands. Do not create a `docs/` folder of specs.
