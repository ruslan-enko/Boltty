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
- **Ask Boltty** — select an area of the screen and ask about it out loud:
  open the panel with its usual key, drag a region, speak; the
  agent's face answers beside the pointer, in typed words and blips, and can
  point and draw.

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

**Model lists are read from each CLI, never written down**: at launch, as Settings
opens, on Scan for Agents, and as the panel opens once an hour has passed
(`refreshModelsIfStale`, in the background). A list that did not come leaves the
last one standing. A chosen model the list no longer has gives way to the agent's
default for new chats, and Settings says so; the stored choice stays, in case it
comes back. A chat already started keeps its model, and what the CLI says about it
is a failure on that turn. A CLI updated under a process kept running (Codex's
app-server, Grok's stdio, Boltty's own OpenCode server) restarts it once nothing of
its is running or waiting (`restartOutdatedProcesses`, by `--version`).

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
| What comes with the words | `UI/Prompt/PromptAttachmentStrip.swift`, `PromptAttachmentCard.swift`, `Models/PromptDraft.swift`, `Services/PasteboardIngest.swift` |
| Notch face | `UI/NotchMascotController.swift` |
| Mascot | `Chat/UI/ConversationAvatar.swift`, `MascotRenderer.swift`, `MascotShaders.metal`; `Models/MascotShape.swift`, `MascotPalette.swift`, `MascotLook.swift` |
| Screen selection | `Services/ScreenRegionCapture.swift`, `Models/ScreenSelection.swift`, `UI/ScreenSelectionOverlay.swift` |
| Boltty's icons | `UI/BolttyIcon.swift`, `Resources/Icons` |
| Brand colours | `UI/Appearance/BolttyBrand.swift`, [BRAND.md](BRAND.md) |
| Shader effects | `UI/Effects/` |
| Chat backdrops | `UI/Backdrop/`, `Models/ChatBackdrop.swift`, picker in `UI/Settings/ChatBackdropPicker.swift` |
| First run | `UI/FirstRunShowController.swift`, `UI/Settings/SetupWindow.swift` |
| Permissions window | `Services/AccessPermissions.swift`, `UI/Settings/AccessPermissionsWindow.swift` |
| Settings | `UI/Settings/` |
| Ask Boltty | `AskBolttyController.swift`, `Chat/AskBoltty/`, `UI/AskBolttyOverlayController.swift`, `UI/AskBolttyDrawingLayer.swift`; the region is the panel's (`AgentPaletteController.beginScreenAsk`) |
| Dictation, speech, sounds | `Services/` (`BilingualDictationEngine`, `SpeechOutput`, `InterfaceSounds`), sounds rendered by `scripts/render-sounds.py` |
| Local voice models | `Services/LocalVoice/` (`LocalModelStore`, `LocalVoiceModel`, `LocalVoiceCatalog` written by `scripts/pin-local-model.py`); Supertonic in `Supertonic/` (`SupertonicText`, `SupertonicSynthesizer`, `SupertonicSpeaker`) |
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
| Working folder | New chats start in `$HOME`, or, opened over Finder, in its front window's folder (`FinderSelectionService.frontFolder`, with Settings › General's Finder switch). Boltty is a Siri replacement first, not a tool for one repository. Chosen with the folder chip until the session exists, then fixed |
| Persistence | Conversations persist and are never replayed or re-executed. A chat stored mid-turn (working or waiting) comes back `interrupted`, not `idle`, with its open cards expired |
| One writer | `ConversationPersistence` takes a `flock` on `owner.lock`; a second Boltty runs read-only and the tray says so. It starts no session or turn (`ConversationEngine.secondCopyRefusal`) and never stores a fallback chord |
| Closing | Closing a window backgrounds it. ⌘Q is **Close Boltty**: windows go, Boltty drops to `.accessory`, work continues. A real quit is only *Quit Boltty* (tray or app menu), with no chord; it stops every turn and adapter on an 8 s deadline, waiting for each turn's stop (3 s timer), not the first to answer |
| Dock click | Brings Settings forward, never the panel |
| Launch order | Hotkey, menu, tray, `.accessory` — then load conversations, so ⌥Space works from the first moment |
| Execution states | `idle`, `working`, `waiting`, `failed`, `interrupted`, `rateLimited` |
| Progress words | `Working`, `Thinking`, `<verb> <object>` for tool events, `Needs your approval`, `Needs your answer`, `Listening`. Reasoning traces are never shown |
| Auto-approve | Off by default; chosen on each agent's page in Settings › Agents and copied into each new chat; the composer's word **Auto** (white when on) switches it per chat. Edits only (commands still ask), except Codex (its sandbox, no asking) and Claude Code (its own `auto` mode: its classifier decides edits and commands). Never a full bypass (except Antigravity's flag, behind Boltty's gate) |
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
  `CGEventTap` (`Services/ModifierHotkeyMonitor.swift`, for the opt-in ⌥⌘
  chord).
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
- Auto is `--permission-mode auto` (and `set_permission_mode` `auto` mid-chat):
  the CLI's classifier decides; `ls`, `rm -rf ./junk` and `git push --force`,
  each asked for, ran with no `can_use_tool` (2.1.296, Haiku).
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
- **The service cannot open Desktop, Documents, Downloads, iCloud or
  `/Volumes`** (launchd starts it, so no app answers for it to TCC; 2.2.0
  answers the first prompt with an empty HTTP 500 and logs
  `DirectoryAccessDeniedError`). A session in such a folder runs on Boltty's own
  server beside the service (`OpenCodeClient.isPrivacyProtected`), which
  reaches what Boltty was allowed. Both share one database; every
  `/api/session/<id>/…` request goes to the session's server, placed by the
  folder on its record, and the second server's events come on a second stream.
- The model catalogue is `/api/model` on 2.0 (`/provider` on 1.18); free models
  have `settings.apiKey == "public"`.
  `GET /api/model/default` names what a session made without a model starts with
  (2.2.5); that one is the list's default.
- Reasoning levels are a model's `variants` (`[{id, settings: {reasoningEffort}}]`,
  2.2.5); the chosen one goes as `model.variant` when the session is made.
- Auto Mode is Boltty answering `edit` asks "once"; a file outside the folder
  asks `external_directory` first, and commands still ask.
- **The free tier refuses a session whose id is not in OpenCode's own
  spelling** (`FreeTierError`, measured 2.0.12–2.0.27; on 2.2.5 it is a 429
  `provider.free-limit`, "Free usage limit reached", which reads as a spent
  plan but is not). Free-model sessions are therefore server-named, and so is a
  session made without a model (the server's default, Big Pickle on 2.2.5, is
  free); a free model switched onto a caller-named session fails the same way.
  Minting OpenCode's spelling in
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
  → or drag across the screen: that is Ask Boltty (select, speak,
    answered beside the face; the panel hides)
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
- **Sizes:** first screen 540 × 85 capsule; once the draft wraps or holds a
  card it widens to 680 (until emptied) and grows up to five lines, with the
  cards' band over them; list five rows; chat 584 × 680 default. They reserve their space; short content does
  not shrink them.
- **Return while a turn runs queues** (one slot, shown, cancellable).
  **⌘Return** steers where the agent declares `.steering`. **⌘.** stops where it
  declares `.interrupt` or `.terminableTurn`; the Send slot turns into Stop.
- **A composer button has its own key**, shown as keycaps on its help tag:
  ⌘D the microphone, ⌘O the folder, ⇧⌘A attach (`ComposerChord`, through
  the field's `performKeyEquivalent`). A hidden or disabled button's key does
  nothing.
- **A chat's composer foot is two groups.** Left, what shapes the request:
  + (attach), Auto, folder — the folder last, so a long name moves nothing.
  Right, what is read and pressed: the usage ring, the microphone, Send. Send
  is a white disc with Return in black (the composer's one pure-white fill;
  the glass's fill while there is nothing to send, a filled stop square while
  it stops). Auto Mode is the word "Auto" in the group's inks, white when
  on — no glyph, never filled. The ring is thin, from twelve o'clock
  clockwise, in the group's inks. The first screen keeps ring, folder and microphone together on the
  right; the folder's slot moves between the two stacks
  (`placeDirectorySlot`).
- **Key hints after the typed text** read like Siri's "ds — Ask Siri": an em
  dash, then the first hint in secondary ink at the typed size, with no capsule
  and no key ("— Ask Claude", "— Queue"). Only ever that one: a second hint
  read as a second answer, so neither ⇧Tab's next agent nor ⌘Return or ⌘. is
  suggested (the Send slot turning into Stop says the last). They appear after a 1 s rest, drop from the end when short of room, and
  stand on the typesetter's baseline.
- **What comes with the words stands over them as cards, never in the
  sentence** (`PromptAttachmentStrip`, `PromptAttachmentCard`): 100 × 100, side
  by side, scrolling sideways (a mouse's wheel too), the ends dissolving only
  where there is more. A picture or a region fills its card. A file says where
  it is (`~/Desktop/Upload 1.mp4`, the leading folders giving way first, so the
  name always shows) over a tag saying what it is (`MP4`, `Folder`): video and
  PDF too, with no thumbnail. Pasted text says how it begins. The tag is a filled
  capsule, since borders are never stroked. The × comes with the pointer and
  stands past the corner; a press is Quick Look; Backspace with nothing before
  the caret takes the last card and ⌘Z brings it back. A link is not a card: it
  stays words, drawn as a link. Dropped anywhere on the panel it goes through
  `PasteboardIngest`: the field takes no drags of its own, or a file dropped on
  the words became its path in words.
- **The agent reads the words, then the files** (`PromptDraft.separated`,
  `PromptExpansion`): a blank line, then the paths in the cards' order, with
  a space between. A draft stored while files stood in the sentence is read into
  this shape, losing the space either side of each. So nothing is said about
  which file a word meant but the order of the cards.
- **The strip's band comes out of the shell's foot on the first screen**, whose
  top is held under the notch: the line under it and the strip go down with the
  foot (`rideAttachmentBand`, one constraint on the spring's clock), the strip
  uncovered from under the shell's top. Moved at once, the line stood below a
  foot that had not got there, and the mask cut it away. Cards hold the width
  at 680 until the last goes. In a chat the band comes out of the transcript, at
  once. The band is 120 on the first screen (corner 22.5) and 116 in a chat
  (corner 13), both concentric with their shells; it is nothing while the list
  is up. The placeholder stands beside cards: `isEmptyPrompt` means no words,
  `isWhollyEmpty` nothing at all.
- **The black ramp** (`bolttyAIPrompt`) is worn by the shell in every state
  — first screen, listening, list and chat — never by the composer, and only
  once the state has settled (`applySurfaceStyle` defers changes *to* a wash to
  the end of the turn).
- Opened over Finder with an empty first screen, the panel attaches the files
  selected there (`FinderSelectionService`, Finder Automation). Settings ›
  General › Finder switches it (`boltty.finderSelection.enabled`, on).
- Refreshing rows never orders the window forward or steals first responder.
- **Clicking outside** (a click, not a drag) hides; the panel takes every press
  on the screen, so a click outside does not reach the window below.

### The transcript

- The question is a white bubble with black text; the answer is prose on the
  glass, Codex's proportions (headings 1.5/1.25/1.125×, line 24 on 15). A
  turn's last answer always has Copy and, where it can be read, the speaker
  under it; a question's row shows under the pointer.
- **Selecting never takes the keyboard from the composer.** A press in an
  answer gives focus back as it ends, the words staying selected
  (`returnFocusAfterReadingPress`), and ⌘C copies them while the composer has
  nothing selected. A selectable label loses its selection with the focus, so
  it keeps the focus until a key goes to the composer
  (`routeKeyFromReadingText`).
- **Tool calls are rows, folded into one line per run of work**
  (`PaletteActivityGroupView`), said in one line ("Thought • Read 3 files •
  Edit config.ts") with a small chevron after its last word. No box: opened,
  the rows hang off a hairline thread at the leading edge, and an opened
  row's output sits in a filled well. Messages with no words of their own join the next
  (`PaletteTranscript.joined`), so every agent's turn draws alike. A tool
  id with no description of its own is read as words (`run_command` → "Run
  command"); Antigravity's calls fall back to their command and file.
- A finished turn with work gets "Worked for …" and folds to its last prose. A
  running turn, the first one included, shows the transcript and under it a
  working line with the agent's face.
- Streaming prose: finished paragraphs are rendered as markdown; the paragraph
  still growing is plain text with words fading in through the agent's light
  (`MascotPalette.arrivalLight`). A face of one hue (Ember, Mist, Lilac)
  has its light fanned 80° round that hue: lifted as it was, it was one
  pastel and read as no light at all.
- Only files a turn **made** get file rows (`PaletteFileRowView`, with their
  actions in reach); reads and searches leave activity rows only. Pictures get
  Quick Look thumbnails that resolve out of a blur.
- What the person sent stands over their words as the cards it came as, in rows
  from the right (`AgentPaletteMetrics.sentCardFrames`; `Conversation.sentFiles`,
  `SentFile.lift`), stored on the conversation because providers re-file requests
  under their own ids. Pasted text too: its words go inline, and a file written
  beside them is what its card stands on. A card flies there from the strip
  without changing shape. Right click: Quick Look, Show in Finder, Use in Follow-up.
- A failure belongs to the turn that produced it; once the agent speaks again
  it draws no card. A failure is never a bubble.
- The answer text view is contiguous layout: non-contiguous layout drew long
  answers blank when first shown at their foot.
- Block borders are filled, never stroked (wide strokes hit Core Animation's
  wide-line renderer, which can hand Metal a zero-instance draw). A Debug build
  stopped on a Metal assertion is paused, not hung — `sample <pid>` it.
- Sizes are arithmetic: the same function measures and draws.
- **The card stands in the panel at its width before it measures a chat**
  (`enterAddressing`). Measured with no width, the words wrapped narrow, the floor
  stayed that tall, and the first long chat since launch opened on the blank under
  its end. A new width wraps the words in a pass after the card's own, so the
  floor and the place at the end are worked out again once it has
  (`scheduleReflowSettle`).

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
  coded as Latest) then one per agent that is switched on and on this Mac
  (`AgentHistory.listed`; signed out still counts). With one there is no All, and
  its tab stands alone at its own size in the middle. An agent not listed is gone
  from the tabs, the rows and the search, and from Usage, until it is switched on
  again; its chats stay on disk, and one still working is reached from the tray
  and the notch. Settings › Agents lists every agent, since that is where one is
  switched on. All wears the faces of enabled agents, arranged like die pips.
- **Nothing offers a choice with nothing to choose among.** With one agent there is
  no All, no agent menu on Usage, no ⇧Tab or ←/→ in Settings › Shortcuts and none
  suggested when it is not ready, no Preferred in Settings › Agents, and the first
  run's list and its walk do the same. Any number from two to five is All and that
  many tabs, sharing the strip.
- Only the chosen tab's face is alive; the live face wakes out of, and returns
  to, the still picture (`handOver`, `awake`) so switching never jumps.
- Rows are built lazily near the viewport (`ResultsListView`); a filtered row is
  hidden in place. A row's preview stops at 400 characters.
- A row's title is the first request, cleaned of brackets and Boltty's paths
  (`ChatTitle`). Unread rows have a blue dot and a semibold title. A working
  row's second line is the step it is on ("Reading upscale.py", "Thinking…",
  `BolttyAISessionList.liveStep`; "Working…" between steps), with a band of the
  agent's light sweeping across those words, as the CLIs' shimmer does. Nothing
  runs round the pill: an orbiting outline read as a border and a second
  selection.
- The order holds while the list is open.
- **The chosen row is a flat fill, no edge.** A row works out its colours
  again once it stands in the panel: lit before, it took Light's black on a
  light Mac. ↑/↓ scroll the least they must, a day's
  first row brings its heading, and a chosen row never stands under the strip
  or the foot's discs. ⌘↑/⌘↓ (Home/End) take the ends, Page Up/Down a page;
  Tab and ⇧Tab do nothing here (Tab used to type into the field and turn the
  list into a search). A new tab starts at its top.
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

Selecting an area and asking about it is Ask Boltty, and there is one way in:
the panel's first screen, where a press on empty glass that moves past 4 pt
draws a region. Nothing switches it on. A chord of its own (⌃⌥⌘) was tried and
removed: one key to remember is the point. ScreenCaptureKit freezes the display (Boltty's windows excluded), the
outside dims to 40%, the border is light in the agent's gradient
(`ScreenSelectionGlowView`), and the shell stands beside the region. The
pointer stays an arrow; only handles show resize cursors. While a drag
would select, the pointer resting on the empty glass gets "Drag to ask about
an area" beside it ("Drag to add an area" over a chat;
`ScreenSelectionPointerHint`, help-tag style, after the help tag's rest),
following it until it reaches the shell or presses. Three regions drawn
(`boltty.selection.regionsDrawn`) and it has done its work: shown for good, it
stood over the page each time the panel opened.

Once a region is drawn the shell is the face, the words and the microphone:
no folder chip or usage ring, and ↓ ↑ Tab do nothing (↓ used to open the
list over the region). ⇧Tab still changes the agent; it wears Ask
Boltty's (`regionAgent`) from the selection's first frame, and the first
screen gets its agent back afterwards. **Escape or a click off the region lets
go of the whole question** (`letGoOfRegion`): the microphone stops first (left
running, its silence sent the words as a chat with the first screen's agent),
what was said goes, the prompt is as it was before the region, and the panel
closes. The microphone opens by itself — select, then
speak — and a typed key takes over from it. Return, ✓, a silence after
speech sends. The region is cut off the main thread (the
region at display pixels, the whole screen at 1568 with the region outlined,
the app and window under it, Vision's text) and goes with the words to
`AskBolttySession.ask`.

**It is one movement.** The shell stands at the corner of the region where the
drag ended, on that side if the prompt fits there (`shellAnchor`), and is the
orb from the first frame (`awaitsRegionVoice`, until the microphone is up or 2 s
pass), growing out of a speck on the region's edge on the shell's spring
(`regionSeed`); the face does not fly in, since the prompt it would come from
was never seen. The edge by the region and the shell's top hold as it grows
with the words. Sent, the turn starts at once and the shell closes into the orb
round the face while the words and the dim fade (`collapseToFace`, 0.26 s).
Said rather than typed, the shell stays round the words while the region is cut
(`holdWordsForQuestion`): let go of as the take ended, they went out and the
prompt stood there for that moment, which read as the words vanishing.
Then the panel goes at once, and the face beside the pointer takes up from
where the orb's stood, at its size (`handRegionOver` →
`AskBolttyOverlayController.arrive`). It flies on a low arc (0.55–1.1 s by
distance, at most 80 pt up, a little larger at the top), landing at its own
size, and only then does its bubble come out of it (`popBubble`). The answer
done, the bubble draws back into the face (`rest`). A bare version, face and
words on the dimmed screen with no glass, was tried and refused: the face hung
in nothing.

Files in the prompt wait out the question: taken out as the region begins, so the
microphone opens, and back in the prompt afterwards. Over an open chat a dragged
region is a card in its composer; a click outside still hides. Screen
Recording is asked the first time; refusals are said in the panel.

### The folder chip

Home is the folder glyph alone; elsewhere the folder's name (and git branch,
read from the repo's files without running `git`) on a light pill. A click opens
a menu: Show in Finder, Copy Path, Open on GitHub, No Folder, Recent (up to
five, from Boltty's chats), Open Folder…. Once a chat has a session, only the
actions remain.

### Listening

Pressing the microphone on the first screen collapses the shell into an
orb of the panel's own glass under its black ramp, and the prompt's face
**flies into it** (`beginFaceFlight`, 0.55 s on a
small arc, from its place and size on the prompt to 48 in the 84 orb). The
orb draws nothing of its own: a black orb, lit gradients and an aurora were
each tried and refused. Once words are heard it grows into a capsule (up to 380 wide,
`listeningMaxWidth`): the face rises to its top with the spring and
**watches the newest word** (`MascotNSView.lookAtWindowPoint`; the
`.listening` mood's gaze and turn were widened so it is seen to) and nods
at each new one (`MascotNSView.nod`), and the
words stand under it in centred lines that **run downward**, the capsule
growing a line at a time to five (`listeningMaxLines`); past five the oldest
line rises under the face and fades through a gradient mask over the room
above the lines (`ListeningWordsView.headroom`), never cut at an edge. A word a line re-centres glides there. **Each word
arrives slowly out of a soft blur in the face's colours**
(`ListeningWordsView`, 1.1 s: the word drawn in the face's gradient round
rings of offsets, closing into the sharp white word, no filter), rising a
little into place; words heard together a beat apart. Only words past the
end arrive: a word the engine revises changes in place (arriving again, the
last few words blinked on every result). In an open chat a
non-empty draft keeps the composer. Enter is ✓, which waits for the engine's
final text **as the orb**, then goes from the orb straight to the chat (or the
prompt) in one move while the orb fades on the shell's spring
(`voiceGlowOrbReleaseDuration`). The orb casts no shadow: the shell's shadows
read as a dark rim round it. A long silence sends, but only after speech was
heard.

## Ask Boltty

- **One gesture: select, then speak.** The region, the listening and the
  words are the panel's (*Selecting the screen*); Ask Boltty is the session
  and the answer. The freehand trail and the ring at the pointer
  were removed: a region says what is meant exactly.
- A region drawn warms up the chat and its session (`warmUp`); let go of
  unasked, a chat made for it goes (`cancel`).
- Sent: the screen at 1568 px with the region outlined (what 0–1000 measures
  across) and the region up close, the window under the region, Vision's text
  in `<screen-text>`, and `AskBolttyPrompt.bracket` (answer in one or two
  sentences, in the asker's language, a link as it is, point and draw with
  tags). Nothing said is nothing sent.
- **The picture holds only what the question is about** (`FrozenScreen.layers`):
  the windows the region shows, what they have open over them (a menu, a
  popover: the same owner above layer 0), the menu bar ("where is Export?") and
  the region. The rest is painted out where it stands, so the coordinates hold
  and a window or another app's banner lying over a shown one stays hidden; the
  prompt says it is hidden on purpose. A window above layer 0 as big as the screen
  is ignored: some are clear (the system's Screenshot keeps one at the menu bar's
  level). The whole screen selected, the whole screen goes. A region's card
  in a chat goes the same way. People read "this area" as what is sent, and the
  picture is something Boltty makes (*Boltty is a wrapper*), so README and
  Settings › Ask Boltty say so.
- Over a Finder window or the desktop the prompt names the folder and what is
  selected in it (`ScreenSelection.finderSpot`, `FinderSelectionService.place`,
  on a 1.5 s timer; Settings › General's Finder switch), so "organise this" has a
  "here". The window is told by its name and a point in it, from what Finder
  lists (`parsePlace`), never by a guess: Recents, a search, a refusal or no
  answer name no folder and the prompt says to ask. The chat works in that folder:
  a session cannot move, so one warmed up elsewhere, or going on from another
  folder, gives way to one started there (`reopen`).
- Tags: `<point x y label/>`, `<circle>`, `<box>`, `<arrow>`, `<line>`,
  `<path d>`, `<label>`, `<board>…</board>`, coordinates 0–1000 of the picture.
  Each is shown when the reading reaches its sentence; drawings stay until the
  next question, a click or Escape. The chat card strips the tags. A `<point>`
  is shown by the face flying beside the spot with a small pointer of its own
  (`AskBolttyPointerMark`, the face's colours under a white edge; a ring was
  tried and refused): its tip lands on the spot, its tail lies toward the face
  (`pointerTurn`), and it travels with the face.
- At most two sentences of an answer are said, one at a time: a new sentence
  takes the last one's place (`captionSentences`, `answerSentences`). The answer
  ends when the voice falls silent; `$speakingID` tells before the value changes,
  so it is read on the next turn of the run loop (asked at once, the voice was
  still saying it, and nothing ended the answer until the store moved).
- The answer comes beside the face word by word, each arriving out of the blur
  the listening words have (`ListeningWordsView`, `isCentred` off), the bubble
  growing to fit what has come (`revealWords`, `growBubble`); a new sentence
  starts it afresh. **The words hold still**: the bubble's top stays and lines
  are added below, only the face bobs, and the side stays while the widest
  bubble fits, gliding across when it does not. On the left it stands at its
  whole sentence's width (the words hang from its left edge). With blips
  (`AskBolttyBlips`, rendered on Core Audio's thread — its block is made
  `nonisolated`). Saying it aloud
  (`SpeechOutput`: Supertonic's 31 languages, once it is downloaded) is
  Settings › Ask Boltty › "Say answers aloud" (`boltty.talk.speaksAloud`,
  off; until Supertonic is here its download stands in the switch's place),
  read into `AskBolttySession.speaksAloud` as a question is sent. Said aloud,
  the words still type out, without blips over the voice.
- **The face waits after the answer** (`AskBolttyOverlayController.rest`): its
  words go once said, a line says what can be done ("⌥Space to ask more · Esc to
  close", `restHint`, gone after 5 s, since a bubble riding with the pointer gets
  in the way), and it goes by itself after 12 s. It returns to the pointer unless
  it pointed at something: then the place is the answer and it stays on it.
  **While it is there the launch key goes on with the question**
  (`AskBolttyController.questionToContinue` → `AgentPaletteController.askAgain`):
  no panel to pass through, the same region, the same agent, listening; the
  screen is taken afresh. A question within ten minutes, by either way, continues
  the same chat (`choosePlace`); one that cuts off a first answer still running
  starts a new chat, since that turn has not stopped yet.
  A click or Escape takes it sooner; the panel opening does too. What it drew
  outlasts it, until a click or Escape.
- "Thinking…" beside the face wears the shimmer a working
  row has in the chat list: a band of the face's arrival light across the
  words; under Reduce Motion they stay plain.
- The overlay is one `PassivePanel`; frames are snapped to pixels so the face's
  drawable never reallocates.
- Ask Boltty chats raise no banner, unread mark or notch line, and are forgotten
  (record, screenshots, session released via `AgentClient.release`) ten minutes
  after the last answer unless working, waiting or open in the panel; a question
  within those ten minutes continues the chat. Until then one that was asked in
  is a row in the chat list, the only way back to words that have gone from
  beside the pointer. Gone on with in the panel it is the person's own chat
  (`keepChat`): no longer read-only, its process let go before the next send, and
  a new region starts a chat of its own. A chat waiting on the person opens the
  panel on it, every time it waits; while it is open there, nothing about it shows
  beside the pointer.
- Read-only by default (`Conversation.readOnly`): the engine refuses every
  permission (what the agent asks the person still reaches them), Claude Code and
  Codex start without write tools, and asked to change something it says where the
  switch is. With "Can make changes" on it does what it is clearly asked, told not
  to narrate, and the words beside the face follow the turn's step
  (`AskBolttySession.step`) in place of "Thinking…". Back at work after saying
  something it returns to the step, and what it says when done has its own two
  sentences. Claude
  Code's read-only tools include WebSearch and WebFetch, let through without
  asking (`readOnlyAllowedTools`): "find where this news is" needs a search.
- Who answers: the chosen agent and model if ready, else the preferred agent in
  its default model, else the first ready agent that takes pictures. No model is
  hunted for by name: an "Automatic" that meant Claude Code on Haiku was tried and
  removed. Chosen in Settings › Ask Boltty as a strip of bare faces, no circle or
  ring, the chosen one told by its name in the accent's ink
  (`AskBolttyAgentPicker`, on `RingedChoice` with `isRinged` off); "Can make
  changes" is the one switch for access. Always at the model's lowest
  effort, never the effort the agent's chats use and never stored
  (`boltty.talk.effort` is retired, inert), `low` before `minimal`
  (`AskBolttyConfiguration.fastestEffort`):
  a CLI's own default is its highest, and Antigravity's Flash took 14 s at
  high, 7 s at low (1.4.12). Antigravity still spends ~3 s on a turn that
  only opens the screenshot; `content` is text, and `@path` does not inline it.
- A new region while an answer runs stops the voice **and the agent's
  turn** (`stopTurn`), so the old turn doesn't keep spending the plan.
- **Escape calls an answer off** while it thinks or answers: it stops the turn
  (`ConversationEngine.stop`) and takes the face, its words and its drawings
  away. It is a Carbon hotkey (`AskBolttyController.escapeKey`), so it needs no
  permission, held **only while the face or a drawing is on the screen and the
  panel is not up**: for that time Escape does not reach other apps, which is
  why the face does not stay for good. Before sending, Escape is the panel's: it
  closes the question (*Selecting the screen*).

## Other surfaces

- **Notch face** (`NotchMascotController`): a black circle beside the camera
  housing, or in the middle of the menu bar on a Mac with no notch
  (`NotchMascotGeometry(topEdgeOf:)`), one face per agent with something to say
  (up to four, most urgent nearest the notch). It speaks a line ("Needs your approval · Claude",
  "Done · <chat>"); approvals and questions hold their line, others fold after
  6 s. No circle when there is nothing to say. Never key, never activates.
- **Permissions window**: four rows (Microphone + Speech, Screen Recording,
  Notifications, Finder Automation), each Allow / spinner / check / Open
  Settings…, re-read every 1.5 s. Allow All asks in order, Screen Recording
  last. Permission callbacks are never main-actor isolated (TCC calls them on
  its own queue).
- **First run**: a show over a sunset (`SunsetView`, `ShowSpace` maps 1800 × 1169
  slides to the screen; one face carried through every scene; its own clock,
  `ShowClock`). Its beats, each with a caption: the panel under the notch,
  ⇧Tab walking the agents, a question answered in a chat whose composer has
  Auto and Send; ↓ to the chat list and its agent's tab; Ask Boltty in an app
  as one movement (the panel, a dragged region, the orb on its corner with
  the words out of a blur, the face to the pointer and on to what it names,
  drawing a loop and an arrow on the app itself); Settings (a face, a backdrop's round window, Usage, Voice). A
  feature's real gesture changing means this script changes with it. Only the
  shell's glass casts shadows, so it stands in front of the made-up apps. Then the setup card (agents, faces, keys, voice,
  permissions) on the panel's glass. The voice step offers Parakeet and
  Supertonic, both unticked; a ticked one is chosen and downloaded in the
  background once setup ends (`installSetupVoices`), Apple's engine standing
  in until then. `-boltty.replayIntro YES`, `-boltty.skipShow YES`,
  `-boltty.setup.step N` in Debug. Launch with `open`, never the binary from a
  shell (TCC would attribute the request to the shell's app).
- **Settings**: a sidebar of pages (General, Agents, Usage, Voice, Ask Boltty,
  Shortcuts), standard parts but for what is selected: the sidebar's rows and
  the segments are drawn here (`SettingsSidebarRow`, `SettingsSegments`), since a
  `List`'s selection and a segmented `Picker` take the person's accent. The sidebar
  takes the focus as it appears, so the arrows walk the pages and no control opens
  wearing a ring. The selected page is
  `boltty.settings.page` (`-boltty.settings.page agents` opens a page). The window
  is sized after its view controller is set; the sidebar width modifier is last on
  its column.
- **App icon**: one, `AppIcon.icon` (Icon Composer); `.github/icon.png` is it
  rendered with Xcode's `ictool`. A choice of four was tried and removed: macOS has
  no alternate icons, so it only ever showed while a Boltty window was open.
  `boltty.appIcon` is a retired key, inert on disk.
- **Settings › Agents** is a list, one row per agent: face, name, a "Preferred"
  tag, one line of what a new chat would use (or why it can't), its switch.
  A row opens the agent's own page (`SettingsLocation`, in the back/forward
  history; only the page is stored): the agent and its switch, Make
  Preferred, model, reasoning, permissions with the Auto Mode note once, and
  the face's shape, gradient and finish as rows. Never expand every agent on
  the list again. `-boltty.settings.agent claude` opens an agent's page.
- **Usage**: plan windows per agent (each: what remains and when it
  comes back, the bar and the activity chart flat in Boltty's accent,
  never the face's gradient), 14 days of activity, and an overview counted
  off every CLI's own records (`AgentStatisticsReader`, cached per file in
  `Application Support/Boltty/Usage/statistics.json`). Never summed across
  agents' different units. Signing in happens in a terminal, so the page asks
  every CLI again whether it is signed in before reading limits: when shown,
  when its window comes forward (at most every 30 s), and on Refresh. A
  signed-out agent's row is its face, name and `AgentId.signInCommand`
  (`claude auth login`, `codex login`, `grok login`); its old limits are
  dropped.
- **Reading aloud** (`SpeechOutput`) is Supertonic's (below) or nothing:
  the Mac's own voices are never used. In Boltty's process they are the
  compact ones (Siri's are spoken only for Apple's apps, as compact Samantha
  for anyone else), and they could not read Ukrainian at all. Until
  Supertonic is downloaded, Settings › Voice shows only its download, the
  per-answer speaker button does not appear, and nothing is said.
  **"Read answers aloud"** (`boltty.speech.readAnswers`: empty = Never,
  `voice` = When I Asked by Voice, `always`): when a chat's turn ends well
  (`ChatWorkspaceCoordinator.onTurnFinished`, never Ask Boltty), the start of
  its last reply is read — up to three sentences, code and marks dropped
  (`AnswerReading`). "By voice" is the panel's mark that dictation wrote into
  the prompt sent (`onPromptSent`'s `byVoice`, not stored). It never talks
  over something else being said; hiding the panel does not stop it; a new
  request or the microphone opening does. `boltty.speech.voiceByLanguage`
  and `boltty.speech.engine` are retired keys, inert on disk.
- **Dictation**: Apple's engine by default, optional second language as a
  second recognizer on the same audio (`BilingualDictationEngine`), decided per
  phrase by confidence (`BilingualTranscript`). `fastResults` lowers
  confidence, so with two languages the transcriber is built from options.
- **Parakeet dictation** (`ParakeetDictationEngine`, Settings › Voice ›
  Dictation, `boltty.dictation.engine` = `parakeet`): once downloaded,
  every take whose dictation language is one of its 25 goes to it
  (`VoiceDictationService.localEngine`, asked at each take); others stay
  Apple's. It hears Ukrainian and English in one take, so while it is chosen
  the language pickers are hidden, and it needs the microphone only, not
  Speech Recognition.
  It reads whole takes: the take so far again every 0.7 s for live words,
  once more on release for the final text. Own Core ML port
  (`ParakeetTranscriber`, `ParakeetTDT`): 15 s windows with 1.6 s of sound on
  each side of what is decoded, the predictor's state carried across. On the
  owner's 30 takes it matches FluidAudio (WER 14.7 %, CER 10.1 % vs 10.0 %;
  Apple bilingual 21.8 / 14.0) at ~0.12 s a take, ~600 MB loaded; first load
  in a new binary 24 s (Core ML compiling), then a fraction of a second.
  Loaded when chosen (dropped after a minute unused), and 10 minutes after the
  last take. No Russian letters appeared in Ukrainian takes, so there is no
  uk/ru filter.
- **Local voice models** (`LocalModelStore`): Parakeet Ultra (dictation,
  632 MB) and Supertonic-3 (speech, int8 Neural Engine buckets, 268 MB), Core
  ML builds from FluidInference on Hugging Face, run by Boltty's own code — no
  package. Downloaded only when the person asks; Apple stays the default.
  On the Voice page choosing Parakeet is asking: its menu item names the
  size, the download starts at once, and Stop takes the choice back; one
  that is here and not chosen gets one line with Remove…. Supertonic has a
  Download button where its rows will be.
  `LocalVoiceCatalog` pins each to a commit with every file's size and
  SHA-256, written by `scripts/pin-local-model.py` (change the revision there,
  run it, review the diff); a file that does not match is not kept. One folder
  per model and revision in `Application Support/Boltty/Models`, a download in
  progress is `<folder>.partial` and resumes with what is missing; folders of
  older revisions are deleted, nothing else there is touched. Right after a
  download every `.mlmodelc` is loaded once so Core ML compiles it (Parakeet's
  first load took 48 s; then 0.3 s). A second Boltty downloads and deletes
  nothing. Hashing and compiling are blocking and run detached. Licences:
  Parakeet CC BY 4.0, Supertonic BigScience OpenRAIL-M (its `LICENSE` is
  downloaded with it). Measurements and the plan: `.scratch/local-voice/`.
- **Supertonic** (`SupertonicSpeaker`, Settings › Voice › Voice, stored as
  `boltty.speech.localVoice` = a preset `F1`…`M5`, default `M3`; chosen on a
  sideways strip of plain circles in the mascots' gradients, no faces (faces
  were tried and refused; `VoiceSwatch`, `VoicePicker`): a press chooses and
  plays, a press on the chosen one plays again): once
  downloaded it reads every language it speaks, and nothing else is said.
  Each piece is synthesized on a serial queue while the one before
  plays through one `AVAudioPlayerNode`; `onStart` fires when a piece is
  heard. A piece that fails is skipped.
  Measured on an M1 Pro (Boltty's own port): load 0.5 s from Core ML's cache
  (47 s the first time in a new binary, which "preparing" pays), 0.1–0.2 s
  per sentence, ~104 MB. All three estimator buckets load up front, so there
  is no slow first sentence (FluidAudio loads them lazily: 6.7 s). Loaded at
  launch when chosen, dropped after 10 idle minutes; the audio engine stops
  whenever nothing is queued.
  - **One language per pass.** In a Ukrainian, Russian or Bulgarian answer a
    run of Latin words is its own English pass (`SupertonicText.runs`), joined
    without the silence each pass ends on (`SupertonicSynthesizer.joint`);
    read as Ukrainian, "README" came back "ядм". Tagging the Latin runs inside
    one pass (`<uk>…</uk> <en>README</en> <uk>…</uk>`) made the model drop
    whole words: never do that.
  - A pass is at most 70 characters (57 for ko/ja): the 128-scalar window
    degrades toward its end. The last run of a pass ends on a stop, others on
    a comma, so they do not fall.
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
- **Every agent wears its own face**, chosen on its page in Settings › Agents; no two alike
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
- The listening orb is the shell's glass and draws no light of its own: the
  glow view clears once and draws no more frames while `fillsShell`; its clock
  still times the take.
- **Chat backdrops** (`AgentBackdropView`): what an open chat wears behind
  its transcript, chosen per agent in Settings › Agents › Chat
  (`boltty.chatBackdrop.<agent>`): Standard (the glass), Sky, Space. Matrix
  was removed; a stored `matrix` reads as Standard. Standard is every
  agent's default, and nothing stores another for the person. The Settings
  picker is round windows only (`RingedChoice`), with no face in them: the
  chosen one moves under a ringed edge, the others are stills. There is no
  mock-chat preview. Over the glass, under the
  transcript, dark at the top for the white prose. Each face has its own sky
  (`AgentBackdropSky`: zenith, horizon, cloud light, cloud shade, middle,
  glow), the feeling of the face's colour rather than a wall of it: a soft
  gradient through a few related shades, leaning across the chat and
  breathing, with clouds shaded in the sky's own colour; deeper than
  Messages' and rolled off under a brightness ceiling (`backdropCeiling`)
  because the prose has no bubbles. The ceiling gives back saturation as it
  dims, and cloud tops carry the sky's glow: dimmed white read as grey and
  dimmed yellow as olive. Space is near black with only breaths
  of that sky (its glow low in one corner, its zenith high in the other),
  and stars in four depths: gathered in loose drifts, mostly faint, white,
  bluish, warm or in the face's light, the brightest with a halo and faint
  rays. No clouds, no milky way, no night colour (each was tried and
  refused). The sky is after
  Messages' (read off `DynamicBackgroundPosterExtension`'s `clouds.vfx`:
  sprites warped by two scrolling noises, edges choked, ramp-tinted, three
  depths), with noise in place of their textures. **The corner is the
  layer's**, from the glass's rendered corner and curve; a squircle formula
  in the shader did not match. Sky draws a pixel per two points, Space at
  full scale; while the shell morphs (`morphingTo`) the sky is drawn
  once at the size it is going to, pinned to the shell's top and uncovered
  as it grows, with its clock stopped so the live sky that takes over on
  settling is the same frame (redrawn at every size of the spring, the
  list-to-chat morph stuttered; held back, it popped in late); 20 fps, and the clock stops while the window is occluded (a hidden
  panel keeps the view).
- `UI/Effects/`: a thumbnail's reveal out of a blur, a sent card's whip to
  its place over the bubble, the selection border's light. Each always ends by a timer, is made
  through `make` (a failable `NSView` init crashes), and uploads textures as
  8-bit sRGB.

## Design contract (AppKit)

- **Icons are Boltty's own** (`BolttyIcon`, `Resources/Icons`;
  `BolttyIconView` in SwiftUI). Never an SF Symbol: the one left is the Apple
  mark in the first-run show's made-up menu bar, which is Apple's to draw, not
  ours. A 16 × 16 grid, a 1.25 stroke with round ends, continuous corners and
  no hard vertex, one colour. An icon is sized by its box (a chat's composer
  `ComposerControlGroup.iconSize`, a point over `glyph`; elsewhere about a
  fifth over the point size its symbol had, since the ink stops short of the
  box), and its stroke grows with the box. A small round mark is solid:
  stroked, it reads as a ring round a pinhole. `NSImage` draws the files as
  template images, so they are black, not `currentColor`, and **it blurs an
  SVG mask**: a solid with marks cut out is one plain path. Refresh shows the system's spinner while a press is at work: an arrow turned by
  hand could stop at any angle.
- **Glass is the system's**, in five kinds: the shell (`PaletteGlassHost`, bare
  regular glass under a black ramp), controls (the same
  glass), glass buttons (`NSButton` with `.glass` bezel — `GlassCircleButton`,
  `GlassPillLabelButton`), the selected history tab, and help tags
  (`PaletteHelpBackdrop`). Density goes *over* the
  glass, never into its tint. The system's Tinted/Clear setting is respected.
  A glass host's corner must be set again whenever its size changes.
- The shell casts two shadows: a tight contact one and a broad pool behind the
  glass with the shell's shape cut out.
- The transcript dissolves under floating controls (a gradient mask, and in the
  history a private `variableBlur` filter); the scroll indicator bends round the
  shell's corners (`PaletteCornerScrollIndicator`).
- **Type**: five sizes in `AgentPaletteMetrics` — 18, 15 (`typeSecondary` and
  `typeChat`), 13, 11; the first screen's 20 is the exception (key hints
  take the typed size), and so is the notch badge's digit at 9. Whole points only, SF Pro Rounded everywhere, no `.kern`.
- **Colour**: `PaletteInk` — system label colours (dynamic) and fills written as
  values (they end up as `CGColor`). Pure white only for primary-action fills.
- **The accent is Boltty's, not the system's** (`BolttyBrand`, off the app icon;
  [BRAND.md](BRAND.md) says where it goes). `controlAccentColor` and
  `Color.accentColor` are not used: an `NSAccentColorName` counts only while the
  person's own accent is Multicolor. It is always a fill, under black words (white
  is 1.5:1): words in it were unreadable on white, and an ink dark enough to read
  was brown and was refused. `.tint` goes on the control (`BolttySwitchStyle`,
  `.bolttyProminentButton()`), never a page: on Settings' root it turned every
  button's and menu's words yellow on white. Focus rings and text selection stay
  the person's.
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
  450 ms delay, instant when moving between controls. They stand on the
  system's glass with black density over it (`helpDensity`), as a Mac's
  popovers and menus are glass; a flat `#202020` read as a grey patch on the
  shell.

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
  chose a chord, the first free `HotkeySuggestions.fallbacks` entry is stored —
  unless another Boltty is running (it holds ⌥Space); then it is used for this
  run only.
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
  into /Applications. Before a build only the old binary goes, not the bundle: with
  the bundle gone an incremental build leaves out `default.metallib` and the app has
  no faces, so `release.sh` refuses an app without it.
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
- **`install.sh`** (repository root, run as `curl … | sh`) is the way in
  without Open Anyway: Gatekeeper judges only what carries the quarantine
  mark, which a browser sets and curl does not. It takes the latest release's
  `Boltty.dmg`, checks it against `Boltty.dmg.sha256`, checks the app against
  a pinned requirement (the "Boltty Development" root, as `UpdateInstaller`
  does), and swaps it into `/Applications` (`~/Applications` if not
  writable). It refuses while that copy runs, and opens with `open`.
  `release.sh` runs it on every DMG it builds (`BOLTTY_DMG`,
  `BOLTTY_INSTALL_DIR`), so a new signing identity changes the pin in the
  same commit.
- Entitlements: `device.audio-input`, `automation.apple-events`, in every build.
- Fixed by the first release: repository `ruslan-enko/boltty`, bundle id
  `com.boltty.app`, asset name `Boltty.dmg`, tag `v<MARKETING_VERSION>`.
  `scripts/bump-version.sh X.Y.Z` sets the version and bumps the build number.
- `LICENSE` and `THIRD_PARTY_NOTICES.md` ship in every copy.
- The README's pictures (`.github/readme/`) are the real panel and overlay over
  Boltty's own sunset, taken by `ReadmeShotsOnScreen`
  (`TEST_RUNNER_BOLTTY_README_SHOTS=<dir>`; it takes the screen for about a
  minute, and shows the Standard backdrop whatever this Mac chose). The recordings
  become animated WebP: frames at 15 fps from `ffmpeg`, then `img2webp -lossy -q 72`
  (GIFs of the sunset run to 20 MB).
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
   types; `--all` once at the end. UI tests only when named. CI runs the unit
   tests on every push, so a red test is heard of without taking anyone's Mac.
   A test holds behaviour: a number kept twice (a proportion, a height) only
   breaks when the eye has already judged.
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
  `lint`). CI (`.github/workflows/ci.yml`) runs both linters, a Debug build and
  the unit tests on GitHub's `xcode-27` image; its jobs are skipped while the
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
| `BRAND.md` | the name, icon, colour, type and voice |
| `SECURITY.md` | reporting a vulnerability, what counts |
| `THIRD_PARTY_NOTICES.md` | licences of what ships |

Work in flight lives in `.scratch/<feature>/` (gitignored) and moves here, if
still true, when it lands. Do not create a `docs/` folder of specs.
