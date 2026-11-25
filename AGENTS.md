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
comes back. OpenCode reads sooner: its `model.updated` / `provider.updated` events
and a reconnect read the list again at once, and the panel opening does after 5
minutes (`modelListLifetime`), since that is one HTTP request; a failed turn does on
every agent, at most once a minute. A CLI updated under a process kept running (Codex's
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
| Agents' installers | `Services/AgentInstaller.swift`, `UI/Settings/AgentInstallButton.swift` |
| Panel ↔ conversations | `Chat/BolttyAIConversations.swift` (implemented by `ChatWorkspaceCoordinator`) |
| Panel | `UI/AgentPalette*`, metrics in `UI/AgentPaletteMetrics.swift` |
| What comes with the words | `UI/Prompt/PromptAttachmentStrip.swift`, `PromptAttachmentCard.swift`, `Models/PromptDraft.swift`, `Services/PasteboardIngest.swift` |
| Notch face | `UI/NotchMascotController.swift` |
| Mascot | `Chat/UI/ConversationAvatar.swift`, `MascotRenderer.swift`, `MascotShaders.metal`; `Models/MascotShape.swift`, `MascotPalette.swift`, `MascotLook.swift` |
| Screen selection | `Services/ScreenRegionCapture.swift`, `Models/ScreenSelection.swift`, `UI/ScreenSelectionOverlay.swift` |
| Boltty's icons | `UI/BolttyIcon.swift`, `Resources/Icons`, drawn by `scripts/render-icons.py` and judged by `scripts/check-icons.py` |
| Brand colours | `UI/Appearance/BolttyBrand.swift`, [BRAND.md](BRAND.md) |
| Shader effects | `UI/Effects/` |
| Backdrops | `UI/Backdrop/`, `Models/ChatBackdrop.swift`, chosen beside the panel's glass in `UI/Settings/ChatBackdropPicker.swift` (`AppearancePicker`) |
| First run | `UI/FirstRunShowController.swift`, `UI/Settings/SetupWindow.swift` |
| Permissions window | `Services/AccessPermissions.swift`, `UI/Settings/AccessPermissionsWindow.swift` |
| Who takes a new chat | `Models/AgentRouting.swift` (`AgentRouting`, `AgentHandOver`), `ChatWorkspaceCoordinator.routingOrder` / `handOverIfDue` |
| Settings | `UI/Settings/`; what a setting changes, shown live: `UI/Settings/SettingsStage.swift` |
| Boltty Design, the design tool | `apps/macos/Design/` |
| Ask Boltty | `AskBolttyController.swift`, `Chat/AskBoltty/`, `UI/AskBolttyOverlayController.swift`, `UI/AskBolttyDrawingLayer.swift`; the region is the panel's (`AgentPaletteController.beginScreenAsk`) |
| Dictation, speech, sounds | `Services/` (`BilingualDictationEngine`, `SpeechOutput`, `InterfaceSounds`), sounds rendered by `scripts/render-sounds.py` |
| Local voice models | `Services/LocalVoice/` (`LocalModelStore`, `LocalVoiceModel`, `LocalVoiceCatalog` written by `scripts/pin-local-model.py`); Supertonic in `Supertonic/` (`SupertonicText`, `SupertonicSynthesizer`, `SupertonicSpeaker`) |
| Strings and translations | `Resources/Localizable.xcstrings`, `Resources/InfoPlist.xcstrings`, `scripts/sync-strings.sh` (*Languages*) |
| Updates, login item, releases | `Services/AppUpdater.swift`, `Services/LoginItem.swift`, `scripts/release.sh`, `scripts/bump-version.sh` |

**A chat's model is the conversation's, and the engine applies it.**
`Conversation.model`, `reasoningEffort`, `autoApprove` and `readOnly` are what the
chat asks for; `settingsInForce` is what its session was last told. Before every send
that differ (always, the first time after a relaunch) and
`AgentClient.prepareSession` closes the gap, never during a turn. A refusal keeps the
words in the composer and says why. Declared as `.modelSwitching`.

**Plan first.** `Conversation.planMode` asks that the chat's next turn plan and
change nothing until the plan is approved; the engine applies it with the rest
(`AgentSessionOptions.planMode`, `.planMode`). Turned on by `/plan` opening a
request (Boltty's own first row of the `/` list, taken out of the words in
`ChatWorkspaceCoordinator.takePlanRequest`) or Plan First in the model chip's
menu; never in a read-only chat. The plan is one card (`PendingInteraction.Kind.plan`:
Approve / Request Changes / Quit). Where the CLI waits on it (Claude Code, Grok)
the card holds the turn; where the plan ends the turn (Codex's plan item, Antigravity's plan
file, OpenCode's reply, `.planInReply`) it holds nothing up (`PlanPrompt.endedTurn`), Approve sends
"Implement the plan." and Request Changes the words, as the next message, and
another message lets it go. Approve and Quit turn plan mode off.

**Forks.** Fork from Here (an answer's right click) and Fork Chat (a list row's)
make a new chat that goes on from the end of that turn, where the agent declares
`.forking` (Claude Code, Codex, OpenCode; Grok and Antigravity cannot). It opens
at once with the messages it goes on from, copied in Boltty
(`ConversationEngine.fork`); its session is made from `Conversation.forkedFrom` by
its first message (`AgentSessionOptions.forkFrom`), so a fork never written to
leaves nothing in the CLI's history.

**Undo Changes from Here…** (a question's right click, where the agent declares
`.fileUndo`: Claude Code, OpenCode) puts the agent's changes to files back as they
were before that question, after an alert that says what changes back
(`AgentClient.previewUndo` / `undo`, `FileUndo`). Claude Code's chat stays and a
line says so; OpenCode's question and all after it leave the chat
(`FileUndo.cutsHistory`) and its words come back to the composer. A question is
named to the CLI by its place among the chat's questions, since a live chat's
ids are not the record's. Not while a turn runs. Codex's `thread/revert` changes
no file, so Codex declares none.

**Who takes a new chat.** Nobody chosen with ⇧Tab, a new chat goes to the ready,
enabled agent with the most of its plan left (`AgentRouting.ranked`,
`boltty.agentRouting` = `automatic`, the default; `fixed` is always
`boltty.agentPreset`). Plans are in different units, so only the percentage used
and the time it comes back are compared, never summed: the most pressing live
window counts, at half if it is back within the hour. Within 15 points the agent
that answered last keeps the chats, then the person's own agent, so the choice
does not jump about; an agent that reports no percentage comes after those that
do, a spent one last (soonest back first). A request with pictures goes only
among agents that take them. The first screen wears the face of who would get
it, and ⇧Tab still fixes one agent for one chat.
**A first turn that fails before the agent says or does anything is handed
over** (`ChatWorkspaceCoordinator.handOverIfDue`): the same words and files go
to the next agent in that order, each once, in the same chat — its dead session
is released, its transcript cleared, its name and sent files kept
(`ConversationEngine.handOver`, `ConversationStore.moveToProvider`). One line
under the composer says who and why ("Claude Code's limit is used up · Codex
answers", `AgentHandOver`, the preview's `handOverNote`). Only on the automatic
route: an agent chosen with ⇧Tab, or by `fixed`, fails as it did. A Stop is not
a failure, and a second message fixes the agent for good. An agent that hit its
limit here counts as spent until the reset, else 15 minutes (`markSpent`), for
the panel and Ask Boltty alike. A limit met in the middle of a chat is not
handed over: the session is the agent's.

**A provider is added behind `AgentClient` or not at all**: an adapter, and one
line in `AgentRegistry.live()`. The store, engine, panel and Settings speak that
protocol and nothing below it. Pi and Gemini are discoverable on PATH but have
no adapter; never offer a toggle for them.

## Locked decisions

| | |
|---|---|
| Stack | Swift, AppKit; SwiftUI only in `UI/Settings/`. No web view, no embedded terminal |
| Platform | macOS 26.0+, hardened runtime in Release. Universal DMG on GitHub releases, MIT. Not the App Store (private API, no sandbox) |
| Return in the panel | Starts a conversation **in the background**: no window raised, no `NSApp.activate`. An empty Return starts nothing and plays the system alert |
| Agent choice | ⇧Tab on the first screen walks ready, enabled agents (`AgentHistory.tabOrder`); `nil` is automatic routing: the agent with the most of its plan left (*Who takes a new chat*), or always one agent when Settings › Agents says so. Fixed once the conversation has a session. An agent the person chose that stops being ready is refused out loud, never swapped |
| Tab on the first screen | Walks folder → microphone → text; Space presses the focused icon, which stands on a flat fill (`keyboardTargetFill`): a brighter ink alone was not seen |
| Working folder | New chats start in `$HOME`, or, opened over Finder, in its front window's folder (`FinderSelectionService.frontFolder`, with Settings › General's Finder switch). Boltty is a Siri replacement first, not a tool for one repository. Chosen with the folder chip; once the session exists, changed only where the agent declares `.folderMoving` (all but Grok), applied before the next send |
| Persistence | Conversations persist and are never replayed or re-executed. Kept forever unless Settings › General › Keep chats says otherwise (`boltty.history.keepDays`: 7, 14, 30, 182, 365; absent is Forever): a chat untouched for longer goes to the Trash, at launch, every 6 h and on a change (which asks first when it moves any); one working, waiting or open in the panel stays. Pasted files (`Boltty/Pasteboard`) go a week after no stored chat shows them (`ConversationStore.filesInUse`). A chat stored mid-turn (working or waiting) comes back `interrupted`, not `idle`, with its open permissions and plans expired and its questions late (*The permission card*) |
| One writer | `ConversationPersistence` takes a `flock` on `owner.lock`; a second Boltty runs read-only and the tray says so. It starts no session or turn (`ConversationEngine.secondCopyRefusal`) and never stores a fallback chord |
| Closing | Closing a window backgrounds it. ⌘Q is **Close Boltty**: windows go, Boltty drops to `.accessory`, work continues. A real quit is only *Quit Boltty* (tray or app menu), with no chord; it stops every turn and adapter on an 8 s deadline, waiting for each turn's stop (3 s timer), not the first to answer |
| Dock click | Brings Settings forward, never the panel |
| Launch order | Hotkey, menu, tray, `.accessory` — then load conversations, so ⌥Space works from the first moment |
| Execution states | `idle`, `working`, `waiting`, `failed`, `interrupted`, `rateLimited` |
| Progress words | `Working`, `Thinking`, `<verb> <object>` for tool events, `Needs your approval`, `Needs your answer`, `Listening`. Reasoning traces are never shown |
| Auto-approve | Off by default; chosen on each agent's page in Settings › Agents and copied into each new chat; the menu of the composer's model chip switches it per chat. Elsewhere Boltty decides: edits in the folder, and commands `AutoModeCommands` reads as only reading, building, testing or changing files there (each part of a `&&`/`|` line, with `cd` followed); anything it cannot read asks. A path is judged both as written and as the file system follows it (`AutoModeCommands.followed`: links resolved, a link to nowhere refused), so a link in the folder does not reach out of it and `~/.ssh` linked into a dotfiles folder is still a secret; edits into `.git` ask (its hooks run). A script run by itself (`./x`, `sh x`, `python x.py`, `node x`, `bun x`), `ln`, `printenv` and `env`, and git that names a program (`grep -O`, `fetch --upload-pack`, `--ext-diff`, `--textconv`) ask; package scripts go through only by a build or test name (`npm run test:unit`). Builds and tests still run the folder's own code, which Settings says. Except Codex (its sandbox, no asking but for what its MCP servers ask) and Claude Code (its own `auto` mode: its classifier decides edits and commands). Never a full bypass (except Antigravity's flag, behind Boltty's gate) |
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
- The shell is called in two places: `JSONLineProcess.locate`'s `command -v`
  fallback, and `AgentInstaller`, whose script goes down stdin. Prompts go down
  stdin, never through `sh`.

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
- A process kept for many chats (Codex, Grok) that dies ends every turn it was
  running with a failure, takes its open cards away, and forgets which sessions
  it had loaded; nothing else would say the turn ended.
- JSON-RPC requests have a deadline (120 s), but for Grok's `session/prompt`,
  which answers only when the turn ends.
- A deadline is a timer, not a check in a read loop. A timer inside a task group
  is not a deadline (the group waits for every child). Model scans race a timer
  per agent (`ConversationEngine.modelList`, 30 s).
- A blocking call never runs inside an actor. Every one-shot CLI read
  (`--version`, `login status`, `opencode models`, `command -v`) goes through
  `OneShotCommand`: handlers, a deadline, SIGTERM then SIGKILL, and no waiting on
  a grandchild that holds the pipe.
- A provider that has forgotten a session is recoverable: the engine drops the
  dead id and opens a new session, once per send (`ConversationEngine.deliver`).
- A chat whose folder is gone sends nothing (`ConversationEngine.folderIsGone`,
  checked before every send): every CLI then fails in a way that reads as a
  forgotten session. The card says so and offers Choose Folder… where the
  agent can move.
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
- "Always Allow" sends the CLI's own `permission_suggestions` back with every
  destination set to `session` (`sessionRules`); with none, Bash gets a rule
  for that exact command. A rule of the tool's name alone allowed every
  command after the first.
- An MCP server's ask is a control request `elicitation`, answered `{action,
  content}`; an error cancels it (2.1.330). Its card offers no "Always Allow".
- An `interrupt` cancels what was asking (`control_cancel_request`, or nothing
  at all): Stop takes every open permission card away.
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
- `initialize`'s `commands` are skills, plugin commands (`figma:…`) and the
  person's own beside the CLI's (`builtin: true`, which steer its session and
  screen and are left out); a folder's own `.claude/skills` show only to a
  `initialize` made in that folder (cached 5 minutes). A request that starts
  `/name args` runs the skill in print mode (2.1.325); the record files it as
  `<command-message>name</command-message><command-name>/name</command-name>
  <command-args>…</command-args>`, then the skill's body as an `isMeta` record
  opening "Base directory for this skill:". The CLI's own commands open with
  `<command-name>` and stay hidden (`InjectedText.claudeCommand`).
- Read-only chats run with `--tools Read,Glob,Grep` (variadic flag: another
  flag must follow it).
- Plan mode is `--permission-mode plan` / `set_permission_mode plan`. The plan
  comes as `can_use_tool` for `ExitPlanMode`, the markdown in `input.plan`
  (2.1.325). Allowed with `updatedPermissions: [{type: setMode, mode, destination:
  session}]`, the same turn goes on in that mode (a `system status` frame says
  so); denied with words, it plans again. Re-read, the tool's plan is the turn's text.
- A fork is `--resume <source> --resume-session-at <record uuid> --fork-session
  --session-id <new>` (2.1.325; `--resume-session-at` is not in `--help`): the new
  file holds the history through that record, written only once a message is
  sent. The cut is the last record of the chosen turn
  (`ClaudeCodeTranscript.forkAnchor`).
- `rewind_files {user_message_id, dry_run}` on the control channel puts files back
  as they were before that question, from the CLI's own snapshots
  (`~/.claude/file-history`); `dry_run` answers `canRewind`, `filesChanged`,
  `insertions`, `deletions` (2.1.325). The chat's record stays. A chat with no
  process runs it in one resumed for the call, which writes nothing.
- `set_model` over the control channel takes effect on the next turn and keeps the
  process, so "Always Allow" rules survive it. `--resume` without `--model` goes on
  with the last model used; with it, on that one (2.1.319). Effort and the read-only
  tools are launch flags: the process is let go and resumed, 0.3 s.
- `--resume <id>` from another folder goes on in that conversation, working in
  the new folder; the record stays in the first folder's project file, its `cwd`
  changing from then on (2.1.322). So a folder change lets the process go too.

### Codex

- `codex app-server` is the surface (JSON-RPC over stdio, one server, every
  thread). `codex app-server generate-json-schema --out DIR` writes the schema;
  read it instead of guessing.
- A local picture is `localImage` with a `path`.
- Approval decisions are `accept` / `acceptForSession` / `decline` (and
  amendments, `cancel`). None carries words, so a refusal in words is decline,
  `turn/interrupt`, and the words as the next message.
- An MCP server's ask is `mcpServer/elicitation/request`; Computer Use asks so
  for each app ("Allow Computer Use to use "OrcaSlicer"?", `_meta.persist`
  `session`/`always`). Answered `{}` it is refused, and under `approvalPolicy:
  never` Codex refuses it without asking, so Auto Mode is `granular` with only
  `mcp_elicitations` on (0.171; `approvals_reviewer = "auto_review"` did not take
  it). Shown as a permission when its schema has no fields, else declined.
  "Always Allow" sends `_meta.persist: session`, never `always`.
- `item/permissions/requestApproval` is granted only by sending the asked
  `permissions` back; an empty object grants nothing. The card shows them.
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
- Plan mode is experimental (0.169): `initialize` opts in with
  `capabilities.experimentalApi`, and `turn/start` takes `collaborationMode {mode:
  plan|default, settings: {model, reasoning_effort, developer_instructions: null}}`,
  which needs a model and holds for later turns, so the turn after a planning one
  says `default`. Plan mode is read-only; asked to act, it said so and planned
  nothing until asked for a plan. The plan is an item of type `plan` and the turn
  ends; the rollout files it as an assistant message in `<proposed_plan>`.
- A fork is `thread/fork {threadId, lastTurnId}` (0.169). Its rollout holds only
  what comes after: `session_meta` names `forked_from_id` and
  `forked_from_ordinal_exclusive`, the source's lines it carries, and the reader
  reads those first (`CodexRolloutTranscript.forkPrefixes`). `thread/revert` only
  cuts the history; it changes no file.
- Skills are `skills/list {cwds}` (name, path, `shortDescription`; one name can
  come twice, from two places: the first stands). A request opening with
  `/name` goes as a `skill {name, path}` input before the words, as Codex's own
  composer sends it (0.169). The rollout files the words, then the skill's body
  as a user `<skill><name>…` record; the reader puts `/name` back in front of the
  words (`CodexRolloutTranscript.prependSkill`).
- `thread/resume` and `turn/start` take `cwd`; on a turn it holds for the turns
  after (0.167 schema). Boltty sends the chat's folder with both.
- `turn/start` takes `model` and `effort`, per turn; the rollout's `turn_context`
  shows each (0.167). Neither has a "none": a level stays until another is sent,
  so Codex and Grok do not declare `.effortReset` and their menu offers no way back
  to Default.

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
  has not seen (`ensureLoaded`). **`session/load` requires `cwd`** (1.0.77: "missing
  field `cwd`"); without it every chat after a relaunch read as forgotten and went on
  in a new session.
- `session/set_model` and `session/set_config_option` work on a loaded session; the
  session keeps its model across a load (`summary.json`'s `current_model_id`).
- A session cannot change folder: `session/load` with another `cwd` answers
  "Path not found" (1.0.77), the record living under the first folder's name. So
  Grok does not declare `.folderMoving`.
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
- Permission mode is process-wide; Auto Mode is Boltty answering `edit` asks, and
  `execute` asks `AutoModeCommands` passes, "allow once".
- Extension methods arrive with a leading `_` (`_x.ai/exit_plan_mode`, 1.0.88);
  both spellings are taken.
- Plan mode is per session: `session/set_mode {modeId: plan|default}`, answered by
  `current_mode_update` (the permission mode stays the process's).
- Questions are `x.ai/ask_user_question` (from t3code's adapter, not yet seen
  live); plans are `x.ai/exit_plan_mode` with `planContent`, answered
  `approved` / `cancelled` (+ `feedback`) / `abandoned`. A plan is
  `PendingInteraction.Kind.plan`, drawn as the turn's text with Approve /
  Request Changes / Quit.
- An MCP server's ask is `_x.ai/mcp/elicit`, answered `{outcome: accept|decline,
  content}`; any other shape is a cancel (1.0.92).
- `_x.ai/billing` gives the plan's `creditUsagePercent`.
- Skills reach only a session: `available_commands_update` after `session/new`
  or a load lists them with `_meta.path` and `scope`, beside the CLI's own
  commands (no `_meta`; `/always-approve` among them). `initialize` names only
  its own (1.0.88), and an empty `session/new` stays in Grok's history, so the
  list is the one a chat's session sent (by folder, else the person's own
  skills): none until a Grok chat has run. `/name args` as text runs the skill;
  `chat_history.jsonl` keeps it inside `<user_query>`.

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
    Auto Mode lets edits inside the folder through, commands `AutoModeCommands`
    passes, and reads outside the folder but where credentials live. "Always
    Allow" lasts for the chat while Boltty runs; for a command it covers the
    program and its subcommand (`git commit`, `npm test`), else the whole line.
  - agy's own `--mode auto` is no use here (1.5.3): print mode refused even `ls`,
    `--sandbox` too, and `agy acp` offers no auto mode.
  - Ask Boltty's read-only prompt tells it to open the screenshot when the
    picture did not come with the message, and that the read is allowed; told
    only "do not use tools", `agy` answered without looking.
- Plan mode is `--mode plan`, a launch flag (an idle process is let go to change
  it). Behind the gate it writes its plan as markdown into
  `~/.gemini/antigravity-cli/brain/<conversation>/` (`write_file` with
  `ArtifactMetadata.RequestFeedback`; once `implementation_plan.md`, once
  `plan.md`) and ends the turn linking it (1.5.11); the file becomes the plan card.
  The gate lets writes into `brain` through quietly: agy's own notes.
  Without the gate print mode refused even `ls` before a plan.
- Skills: `agy -p=/skills --output-format json` in the folder (~7 s, no model
  call, the folder's `.agents/skills` among them, 1.5.11). `/name args` in the
  words runs the skill in print mode; the record keeps `/name args` as the
  person's text.
- Plan limits: `agy -p=/usage --output-format json` (~4 s, no model call);
  groups of weekly buckets, each labelled (`AgentUsageWindow.title`).
- `--conversation <id> --model <other> --effort <level>` goes on in that conversation
  on the other model (1.5.2); both are launch flags, so an idle process is let go.
  With neither, `init` names no model. A conversation resumed after a relaunch gets
  its folder from `prepareSession`, so a folder change lets the idle process go
  and `--conversation` goes on in the new one. Declared `.folderMoving`, not yet
  seen live in another folder.
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
  `message.*`. An inbox item is the person's only when its `type` is `user`: a
  background shell that ends comes as `synthetic` (`<shell id=…>`, 2.3.2), and
  the record files it under `synthetic` too. A turn ends with `session.step.ended` `finish: "stop"`, then
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
- Undo is `POST …/revert/stage {messageID, files: true}`, which puts the files back
  at once and answers each file's patch, then `POST …/revert/commit`, which takes
  that message and all after it out of the session; `DELETE …/revert` drops a
  staged one (2.3.2). There is no look without the change.
- A fork is `POST /api/session/{id}/fork {before}`: the history up to, not
  including, `before`, copied with new message ids, the folder and model kept
  (2.3.2); `before: null` copies it all.
- Plan mode is the `plan` agent (read-only), `build` the default:
  `POST /api/session/{id}/agent {agent}` (2.3.2). Its plan is its reply; the
  record gains `agent-switched` and `synthetic` entries.
- Skills are `GET /api/skill?location[directory]=…` (2.3.2); a session made with
  no `location` is in home and cannot use a folder's skill ("Skill not found").
  A request opening with `/id` goes as `skills: [{id}]` beside the rest of the
  words, and the record keeps them apart (`text`, `skills`); the mapper puts
  `/id` back in front. `/api/command` (init, review, goal) is not offered: the
  record keeps only the template a command expands to, not its name.
- The model catalogue is `/api/model` on 2.0 (`/provider` on 1.18); free models
  have `settings.apiKey == "public"`.
  `GET /api/model/default` names what a session made without a model starts with
  (2.2.5); that one is the list's default.
- Reasoning levels are a model's `variants` (`[{id, settings: {reasoningEffort}}]`,
  2.2.5); the chosen one goes as `model.variant` when the session is made.
- An effort needs a model (`model.variant`), so a chat with a default model and a
  chosen effort names the default.
- Auto Mode is Boltty answering `edit` asks, and `bash` asks whose every resource
  `AutoModeCommands` passes, "once"; a file outside the folder asks
  `external_directory` first.
- An MCP server's ask with an empty schema OpenCode accepts itself: no form comes
  (2.3.2).
- The record keeps no title for a tool call (2.3.2): a `shell` call is named by its
  command line, and a file tool's (`read`, `write`, `edit`, `multiedit`, `patch`)
  file comes from its input (`filePath`, `path`, `file`). Another tool's path is
  not taken, so it gets no file row.
- **The free tier refuses a session whose id is not in OpenCode's own
  spelling** (`FreeTierError`, measured 2.0.12–2.0.27; on 2.2.5 it is a 429
  `provider.free-limit`, "Free usage limit reached", which reads as a spent
  plan but is not). So the server names every session: any chat can be switched
  onto a free model later. A chat from before that, on a Boltty id, still fails the
  same way on a free model. Do not report this upstream on the person's behalf.
- `POST /api/session/{id}/move` `{directory}` moves a session to another folder
  (2.2.7, from the OpenAPI document; answers 204). `prepareSession` moves it when
  the record's `location.directory` differs, on the server that can open the new
  folder. A prompt to a session whose folder is gone answers 404.
- `POST /api/session/{id}/model` `{model: {id, providerID, variant?}}` answers 204
  and the next turn runs it (2.2.5). Each switch leaves a `model-switched` record,
  which the transcript reader passes over, so an unchanged chat sends none. 1.18 has
  no such route: there the chat keeps its model.
- **A session accepts any model at all**, a made-up one included; the first anyone
  hears is `session.execution.failed` `provider.no-route` ("Model unavailable: …"),
  with no step and no reply. Unread, the chat stood at Working until Stop.
  `session.execution.interrupted` ends a turn the same way.
- **Plan limits** (2.2.6): `GET /api/experimental/usage/limits` gives OpenCode
  Go's `rolling` / `weekly` / `monthly` meters (`percent`, `limited`, `resetsAt`
  in ms) and the Console's budgets (`spent` of `limit` in dollars), `data: null`
  until OpenCode is signed in to its Console. The free models' daily allowance
  is the server's alone: hit after 55, 198 and 141 steps on three days, so no
  percentage is ever shown. Limits show only Go and the Console, or the line
  asking to sign in; nothing is said of the free models.
- `model.updated` / `provider.updated` arrive on `/api/event` when a config edit
  changes the catalogue (seconds, with no restart) and when a folder's instance
  opens; reading `/api/model` raises none.
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
  → follow up in the same composer; ↓ lists saved chats (from a draft's last line:
    above it ↓ walks the lines)
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
- **Sizes:** first screen 540 × 92 capsule; once the draft wraps or holds a
  card it widens to 680 (until emptied) and grows up to five lines, with the
  cards' band over them; list five rows; chat 584 × 680 default. They reserve their space; short content does
  not shrink them.
- **Return while a turn runs queues** (one slot, shown, cancellable).
  **⌘Return** steers where the agent declares `.steering`. **⌘.** stops where it
  declares `.interrupt` or `.terminableTurn`; the Send slot turns into Stop.
- **A composer button has its own key**, shown as glass keycaps on its help tag:
  ⌘D the microphone, ⌘O the folder, ⇧⌘A attach, ⇧⌘M the model (`ComposerChord`, through
  the field's `performKeyEquivalent`). A hidden or disabled button's key does
  nothing.
- **A chat's composer foot is two groups.** Left, what shapes the request:
  + (attach), the folder, the model.
  Right, what is read and pressed: the usage ring, the microphone, Send. Send
  is a white disc with Return in black (the composer's one pure-white fill;
  the glass's fill while there is nothing to send, a stop square while
  it stops). The ring is thin, from twelve o'clock
  clockwise, in the group's inks; from 80% used its arc is the accent on glass
  (`planRingWarningPercent`): in the ink, nearly full read as empty. An agent
  that reports no plan (OpenCode's free models) has the chat's context drawn
  there instead (`shownPercent`): an empty ring read as broken. The first screen keeps ring, folder and microphone together on the
  right; the folder's slot moves between the two stacks
  (`placeDirectorySlot`).
- **The model chip says what the chat runs on, in words** ("Opus · High"; a
  CLI that lists only ids gets them read as a name, `ModelSelection.readable`:
  `claude-opus-4-6-thinking` is "Claude Opus 4.6 Thinking"), in the
  group's inks; a long name gives way at its end, never the effort after it,
  and the padding in its pill holds. Its menu (`ModelMenu`) is the
  models (under their providers when there are several, in submenus past 14), the
  chosen model's efforts, and Auto Mode with what it lets through for this agent.
  Auto was a word of its own here and read as not working, since on most agents
  commands still ask; it is on the chip's help tag while on. A choice waits for the
  next message, whatever is running. The first screen has no chip: a new chat starts
  on Settings' choice.
- **Key hints after the typed text** read like Siri's "ds — Ask Siri": an em
  dash, then the first hint in secondary ink at the typed size, with no capsule
  and no key ("— Ask Claude", "— Queue"). Only ever that one: a second hint
  read as a second answer, so neither ⇧Tab's next agent nor ⌘Return or ⌘. is
  suggested (the Send slot turning into Stop says the last). None while an `@` or
  `/` list is open: Return chooses from it. They appear after a 1 s rest, drop from the end when short of room, and
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
- **`@` brings a file** (`ComposerSuggestionPicker`, `ComposerToken`, `FileMention`, `FileMentionSearch`),
  the same for every agent, since no CLI offers a search all five share: an `@`
  at the start of a word (never inside one, `me@site.com`) opens a list of up to
  eight at the `@`, above the line where there is room inside the shell (a
  chat's composer), else under the shell (the first screen, whose line is at its
  top: a one-row list fitted above stood over its edge),
  on the help tags' glass. What follows the `@` filters it; ↑ ↓ choose, Return
  or Tab adds the file as a card and the `@word` goes, Escape lets that `@` be.
  The chat's folder is walked (hidden files, `skippedNames` and the plain lines
  of its `.gitignore` left out; 40 000 entries or 2 s); where a file is gives way
  at whole folders from the front ("…/Screenshots", `SuggestionPlace`), or not at all; home, the default, and
  any folder holding it are Spotlight's, Library and dot-folders left out. A
  bare `@` lists the newest: modified there, or used in the last 14 days. Not in
  the list's search, while listening, or over a region.
- **`/` at the very start lists the agent's skills and commands**, read from its
  CLI (`.commands`, `AgentClient.commands(folder:)`, `AgentCommand`), never
  written down: the open chat's agent, else the one the first screen wears, in
  the chat's folder. The same list as `@`, the description after the name. The
  chosen one goes into the words as `/name `; each adapter carries it the way
  its CLI takes it (*Adapter facts*), and every transcript reads `/name …` back
  as the person's words. A new chat is held to that agent (`holdAgent`), so
  automatic routing never hands a skill to another. The CLIs' own commands are
  never offered: they steer the CLI's session (Grok's `/always-approve` would
  undo Boltty's asking). A slash later in the words is a path, not a command.
- **The caret is placed by frame, never by a constraint's constant**
  (`PromptOverlayView`, over the scroll view, with the key hint): it moves inside
  the layout pass that rewraps the words, where a new constant waits for the next
  pass. The panel opens with it at the draft's end; every other return of focus
  leaves it where the person did (`focusField(caretAtEnd:)`). A draft put in place
  by code drops the whole undo stack: typing is registered on the text storage,
  and undone over other words it throws.
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
  once. The band is 120 on the first screen (corner 26) and 116 in a chat
  (corner 13), both concentric with their shells; it is nothing while the list
  is up. The placeholder stands beside cards: `isEmptyPrompt` means no words,
  `isWhollyEmpty` nothing at all.
- **The black ramp** (`bolttyAIPrompt`) is on clear glass and runs from alpha
  1 to 0.5; Settings › General › Appearance › Panel glass
  (`boltty.panel.clearGlass`, on) puts it back on regular glass, same ramp,
  chosen as the system's Liquid Glass setting is: the shell itself over the
  desktop's own wallpaper (a system one's `.madesktop` names its downloaded
  asset and a thumbnail; an aerial is named only in the wallpaper store's
  `Index.plist`, under `Desktop`, or `Linked` while the screen saver shares the
  choice (macOS 27), and its video's first frame is used; `DesktopPicture`), as a
  Clear and a Frosted tile (`AppearancePicker`, `GlassSwatch`). Regular glass adds a neutral grey to what is behind it (about +30
  sRGB over a dark wallpaper), so bare at the foot it read as grey, and darkened
  to hide that it read as too black. The glass lights its own rim, strongest
  along the foot and thinning up the corners; through the ramp's thin end that
  crescent read as a second, tighter corner inside the shell's, so the ramp is
  denser over the rim, at the foot and fading up the corners (`rimShade`). Shaded
  all the way round, with the glass half a point inside the ramp, the edge was a
  black line: the glass runs to the shell's very edge. It is worn by the shell
  in every state
  — first screen, listening, list and chat — never by the composer, and only
  once the state has settled (`applySurfaceStyle` defers changes *to* a wash to
  the end of the turn).
- Opened over Finder with an empty first screen, the panel attaches the files
  selected there (`FinderSelectionService`, Finder Automation). Settings ›
  General › Finder switches it (`boltty.finderSelection.enabled`, on).
- Refreshing rows never orders the window forward or steals first responder.
- Hiding gives the Mac back to the app before it, unless another has come
  forward meanwhile (a link's browser, Finder), which stays (`handBack`).
- **Clicking outside** (a click, not a drag) hides; the panel takes every press
  on the screen, so a click outside does not reach the window below.

### The transcript

- The question is a white bubble with black text, round and with no tail
  (`MessageBubbleView`: a capsule while it is one line, else the layer's
  continuous corner of 18; a Messages tail was tried and removed); the answer is prose on the
  glass, Codex's proportions (headings 1.5/1.25/1.125×, line 24 on 15). A
  turn's last answer always has Copy and, where it can be read, the speaker
  under it; a question's row (status, time, Copy) shows under the pointer, 6
  below the bubble, in room kept for it.
  A question stands nearer its answer (`previewQuestionAnswerSpacing`) than
  the turn before it (`previewTurnSpacing`), so each pair reads as one. An open
  chat's empty composer says "Reply…"; the first screen's says what it can do.
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
  command"), and a bare id of a known kind as that kind ("execute" → "Ran 1
  command", `saysOnlyItsName`); Antigravity's calls fall back to their command
  and file, OpenCode's `shell` to its command line (its record keeps no title).
  Work rows of two messages in a row stand as close as rows of one.
- A finished turn with work gets "Worked for …" and folds to its last prose. A
  running turn, the first one included, shows the transcript and under it a
  working line with the agent's face. **The work since the agent's last words
  is said there**, not as a line of its own above it ("Reading config.ts",
  "Running npm test", else "Thinking"; `liveWork`, `liveWords`), and joins the
  transcript as its folded line once the agent speaks again or the turn ends:
  a line of work over a "Thinking" line read as two statuses.
- Streaming prose: the paragraph still growing (`PaletteStreamingTailView`) is
  drawn as the answer draws it, markdown and all, in the same text view, so it
  does not move or change when it closes and joins the reply. Its words fade in
  through the agent's light (`MascotPalette.arrivalLight`) one after another,
  however the deltas bunch them (`previewStreamingWordGap`, never more than
  `previewStreamingWordLag` behind), and the words still arriving when their
  paragraph closes finish in the reply's row (`continueArrival`). The light is
  the layout manager's temporary colour (`WordArrival`): the text is set once
  per change, not once a frame. A face of one hue (Ember, Mist, Lilac)
  has its light fanned 80° round that hue: lifted as it was, it was one
  pastel and read as no light at all.
  A single newline in an answer is a line, as in Messages: plain markdown read
  it as a space and one-item-a-line answers ran together
  (`PaletteAnswerText.keepingLineBreaks`).
- Only files a turn **made** get file rows (`PaletteFileRowView`, with their
  actions in reach); reads and searches leave activity rows only. Pictures get
  Quick Look thumbnails that resolve out of a blur. **A file opens over the
  panel itself** (`PaletteLightboxView`, through `FileQuickLookStore.show(url:from:)`
  and `LightboxHosting`), never in Quick Look's panel, which took the key and the
  panel hid. A picture grows out of what was pressed over a dimmed panel; anything
  else (PDF, video, text) is Quick Look's own view (`QLPreviewView`) there, at its
  page's or frame's shape, fading in, with its controls in reach. A press outside
  it, Escape, Space or Return puts it back. It is a window of its own over the
  panel's, which keeps the key: drawn inside the panel, the chat's content stood
  over it and the controls under it still lit and opened. Every key is its while
  it is up, and nothing else opens over it. A file link in an
  answer opens there too, fading in (a folder goes to Finder): the system's own
  way with one is Finder, which hides the panel. A file that is gone plays the system
  alert. The whole screen opens out of the region it holds (`crop`, the layer's
  `contentsRect`) and closes back into it: grown from the region's frame, it
  stood squeezed. A file pressed outside the panel still goes to Quick Look's panel.
- What the person sent stands over their words as the cards it came as, in rows
  from the right (`AgentPaletteMetrics.sentCardFrames`; `Conversation.sentFiles`,
  `SentFile.lift`), stored on the conversation because providers re-file requests
  under their own ids. A follow-up's words fly up as Messages sends them: a picture
  of the typed words leaves the composer where they stood and fades into the white
  bubble, which grows round them from 0.9 on the way (only the bubble: the words keep
  their size, the typed picture fading into one of the bubble's words on the same path; where the
  composer wraps them otherwise, the typed words fade where they stand) (`makeWordsMorph`,
  `PromptTextView.wordsSnapshot`). Pasted text too: its words go inline, and a file written
  beside them is what its card stands on. A card flies there from the strip
  without changing shape. Right click: Quick Look, Show in Finder, Use in Follow-up.
- An Ask Boltty question stands under what it was about, in place of its cards
  (`PaletteAskedRegionView`, `ConversationMessage.askedRegion`): the app and window
  in secondary ink, then the region at the column's width (at most 240 high, its
  edge with the bubble's), with what the answer drew and pointed at on it in the
  marker's colour (the answer's tags, laid over the region's thousandths;
  `ChatWorkspaceCoordinator.withAnswers`). Drawn again, the drawings stand still;
  ones that arrive while it is open are drawn. A press is Quick Look; the expand disc in its corner
  (Whole Screen, `BolttyIcon.expand`) shows the picture the agent was sent.
- A tool cut off with its turn (OpenCode's `error.type` `aborted`) is
  `AgentActivity.State.interrupted`: no warning and none of "Tool execution
  interrupted", since the turn's "Stopped" says it.
- A failure belongs to the turn that produced it; once the agent speaks again
  it draws no card. A failure is never a bubble. One sentence serves every failure,
  but for a used-up plan and a model that has gone (`saysModelIsGone`): that card
  offers Choose Model, its Retry sends the request again, and the chip wears the
  failure's accent. A turn that failed before any reply keeps its words on an empty
  agent message.
- The answer text view is contiguous layout: non-contiguous layout drew long
  answers blank when first shown at their foot.
- Where a line is the point (a table's rule, a quote's bar) it is filled, never
  stroked (wide strokes hit Core Animation's
  wide-line renderer, which can hand Metal a zero-instance draw). A Debug build
  stopped on a Metal assertion is paused, not hung — `sample <pid>` it.
- Sizes are arithmetic: the same function measures and draws.
- **The chat rests on its last words**, as Messages does, never on blank under
  them: a floor that let the question stand at the top of the view, during a
  turn or after it, was tried and removed.
- **The card stands in the panel at its width before it measures a chat**
  (`enterAddressing`). Measured with no width, the words wrapped narrow and the
  first long chat since launch opened on the blank under its end. A new width
  wraps the words in a pass after the card's own, so the place at the end is
  worked out again once it has (`scheduleReflowSettle`).

### The permission card

- Asked the way a Mac asks: the sentence as title ("Run this command?"), what
  it is about verbatim in a well (tool name as a label, command in mono, long
  commands cut at six lines with "Show N More Lines"), the answers as dialog
  buttons, right to left from the default. The reach of "Always Allow" is a
  caption over the buttons.
- **Return confirms the first answer**, as the CLIs do. Do not change this
  without a new reason. On an empty composer ← and → walk the lit answer
  across the buttons in the order they stand (`moveApprovalFocus`), and Return
  presses the lit one; with words typed the arrows stay with the words.
  The lit one is a fill of its own, not the glass's `bezelColor` (the system
  drops that while the panel is not key), and every answer keeps the width it
  has on glass, so nothing moves as the light does. Titles are title case, as
  a Mac's buttons are ("Allow Once").
- **Words typed on a permission card refuse it and go to the agent**
  (`.permissionMessage` where the protocol carries them; otherwise refuse,
  stop, and queue the words). A refusal this press did not deliver stops and
  queues nothing and keeps the words.
- Questions: digits answer on an empty composer (not on a permission); a
  question that takes typed answers says so.
- An ask that is gone (`requestGone`) takes its card away, raises no notice and
  re-reads the conversation. **A question is the exception: it outlives its
  ask.** A form lives only in the memory of OpenCode's process (2.2.5), and a
  real quit stops every turn, so a question left waiting would otherwise be lost
  with the answer typed to it. It becomes late (`Resolution.askGone`, from a quit,
  a relaunch, a gone ask, or a read that no longer lists it with no turn working):
  its card stays, holds nothing up, and its answer goes as the chat's next message
  saying what it answers (`QuestionPrompt.lateAnswer`, `deliverLateAnswer`), by the
  path any message takes. Another message or a Stop lets it go; a later read that
  lists the ask reopens it, as after a crash with the service up. Permissions and
  plans are never answered late: a yes to a tool no longer waiting means nothing.
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
  switched on. All wears the faces of enabled agents gathered round the last of them,
  which stands in the middle (`AgentHistoryTabView.faceFrames`).
- Ask Boltty's chats are chats like any other, in All and their agent's tab; their
  row carries the latest region asked about, at the face's size, as far in from the
  trailing edge as the face from the leading one
  (`BolttyAISessionItem.askedRegionPath`), so one is told at a glance. A list of
  their own behind a foot capsule, and a tab of their own, were tried and removed.
- **Nothing offers a choice with nothing to choose among.** With one agent there is
  no All, no agent menu on Usage, no ⇧Tab or ←/→ in Settings › Shortcuts and none
  suggested when it is not ready, no New Chats strip in Settings › Agents, and the first
  run's list and its walk do the same. Any number from two to five is All and that
  many tabs, sharing the strip.
- Only the chosen tab's face is alive; the live face wakes out of, and returns
  to, the still picture (`handOver`, `awake`) so switching never jumps.
- Rows are built lazily near the viewport (`ResultsListView`); a filtered row is
  hidden in place. A row's preview stops at 400 characters.
- A row's title is the chat's name once it has one, until then the first
  request, cleaned of brackets and Boltty's paths (`ChatTitle`). **The name comes
  once, after a turn that ended well with something said** (`nameIfDue`,
  `AgentClient.chatTitle`, `ChatNaming`, `Conversation.hasOwnName`), fades in on
  the row, keeps the row's place and stays when the talk moves on. OpenCode,
  Grok and Codex name their sessions themselves, so it is read off their records
  (waited for over 22 s). Claude Code's print mode and Antigravity name nothing,
  so it is asked of the smallest model they list, in a folder of its own, at a
  small cost to the plan (5.5 s; `--no-session-persistence`, nothing left on
  disk). `agy` cannot keep no record: each name leaves one conversation, which is
  left alone and counts in Usage. No name is no failure: the request stays, and
  the next turn tries again. Ask Boltty chats are not named, and what the
  person typed is still found by search, off the transcript. A row's title is regular; unread rows have a blue dot and a semibold title. **A row is
  one line, the title**: a second line of preview or step was there and was
  removed (the preview and step are still searched and read out to VoiceOver).
  A working row's title has a band of the agent's light sweeping across it, as
  the CLIs' shimmer does. Nothing
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
  agent cannot take a prompt keeps it disabled — and **Settings** (hex nut) lower
  left, 18 from the foot and side (`historyFootDiscInset`). They stand inside
  the corner resize grips, which give way on a disc; the rows dissolve under
  them, gone by the discs' middle (faded only to the foot, a day's heading read
  beside a disc, cut by it).
- Right click: Open Chat, Show in Finder, Delete Chat… (Boltty's own; to the
  Trash, after asking, no Return on the destructive button). No pin.
- Typing after ↓ searches. `/` and `@` are plain text there, with no list of their own.

### Selecting the screen

Selecting an area and asking about it is Ask Boltty, and there is one way in:
the panel's first screen, where a press on empty glass that moves past 4 pt
draws a region. Nothing switches it on. A chord of its own (⌃⌥⌘) was tried and
removed: one key to remember is the point. ScreenCaptureKit freezes the display (Boltty's windows excluded), the
outside dims to 40%, the border is light in the agent's gradient
(`ScreenSelectionGlowView`, its inner glow faint, so what is selected keeps its
colours; handles at the corners alone under 120 a side), and the shell stands beside the region. The
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
speak. **The question is only ever spoken** (`asksByVoice`): the shell is the
orb for as long as the region stands, keys that would type, paste or drop do
nothing, and ⌘D is the one composer chord left. A typed key used to take over
from the microphone and left a text field beside the region. Return, ✓, a
silence after speech sends; Return or ✓ with nothing said is the system alert
and the listening goes on, and the take's × lets go of the question as Escape
does. So the orb is never left with a microphone that is not listening
(`listenForRegion`): a redrawn region listens again, an engine that ends its
take with nothing heard is started again, a microphone slow to start says
"Getting the microphone ready…" in the orb in secondary ink
(`showRegionVoiceStatus`), and one that fails is tried once more
("Trying the microphone again…"); a second failure lets go of the region and
the first screen says why (`regionMicrophoneFailed`). Words already heard
when it fails stay in the orb, for Return. The region is cut off the main thread (the
region at display pixels, the whole screen at 1568 with the region outlined,
the app and window under it, Vision's text) and goes with the words to
`AskBolttySession.ask`.

**It is one movement.** The shell stands at the corner of the region where the
drag ended, on that side if the prompt fits there (`shellAnchor`), and is the
orb from the first frame, growing out of a speck on the region's edge on the shell's spring
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

What the prompt held, words and files, waits out the question: taken out as the
region begins, so the microphone opens, and back in the prompt afterwards. Over an open chat a dragged
region is a card in its composer; a click outside still hides. Screen
Recording is asked the first time; refusals are said in the panel.

### The folder chip

Home is the folder glyph alone; elsewhere the folder's name (and git branch,
read from the repo's files without running `git`) on a light pill. A click opens
a menu: Show in Finder, Copy Path, Open on GitHub, No Folder, Recent (up to
five, from Boltty's chats), Open Folder…. Once a chat has a session the folder
can still be changed where the agent declares `.folderMoving`
(`canChangeWorkingDirectory(of:)`); the session goes on in the new folder from
the next message (`ConversationEngine.moveToFolder`, carried by
`prepareSession`). Elsewhere, and in Ask Boltty chats, only the actions remain.

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
last few words blinked on every result). **An open chat never becomes the
orb** (`dictatesInChat`): the transcript and composer stay, the words go
straight into the field, and the composer's foot becomes the take
(`ChatDictationBar`): × lets it go and puts the draft back, a neutral wave
of the voice runs leftward (`DictationWaveView`, a bar a frame, gated as the
glow is but quicker), the time it has run, and a lit microphone that ends the
take and leaves its words to edit; Send stays Send and sends what was said.
The empty field says "Listening…". Escape is ×, ⌘D is the microphone, the
foot's other chords do nothing, and an empty Return is the alert. A pause
never sends here: the take ends only by a press. Enter is ✓, which waits for the engine's
final text **as the orb**, then goes from the orb straight to the chat (or the
prompt) in one move while the orb fades on the shell's spring
(`voiceGlowOrbReleaseDuration`). The orb casts no shadow: the shell's shadows
read as a dark rim round it. A long silence sends, but only after speech was
heard. The face in the orb hears: it swells a little and widens its eyes with
the voice's level (`MascotMotion.hear`), so it is seen to listen before a word
is recognised. A region's microphone that has given no sound at all (only zeros: a quiet room
reads as `VoiceDictationService.quietRoom`, not 0) 5 s after its first take says
so in the orb ("No sound is reaching the microphone…",
`watchForSilentMicrophone`): a muted or wrong input otherwise waited in silence.

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
  Ask Boltty does not move a session, so one warmed up elsewhere, or going on from another
  folder, gives way to one started there (`reopen`).
- Tags: `<point x y label/>`, `<circle>`, `<box>`, `<arrow>`, `<line>`,
  `<path d>`, `<label>`, `<board>…</board>`, coordinates 0–1000 of the picture.
  Each is shown when the reading reaches its sentence; drawings stay until the
  next question, a click or Escape. The chat card strips the tags. A `<point>`
  is shown by the face flying beside the spot with a small pointer of its own
  (`AskBolttyPointerMark`, the face's colours under a white edge; a ring was
  tried and refused): its tip lands on the spot, its tail lies toward the face
  (`pointerTurn`), and it travels with the face.
- **Words, not pixels.** Vision reads the picture the agent is sent (hidden
  windows painted out) into lines and words with their boxes (`ScreenText`,
  `ScreenRegionCapture.labels`), listed in the prompt as `<screen-labels>`
  (`x1 y1 x2 y2 words`, 0–1000), at most 5 KB: the menu bar's and those nearest
  the region kept first, listed in reading order (12 KB was 3–4 thousand tokens
  a question). A `<point>` with `text="…"` lands on those words, matched whole
  (`AskBolttyPoint.placed`, `ScreenText.find`: "Save" never in "Saved"), the
  nearest within 250 of where the agent put it; else where it put it.
- **Steps.** Three steps or more come as one sentence each after its own
  `<step text x y/>`, shown one at a time, numbered (`AskBolttySession.isGuiding`);
  a click anywhere (`leftMouseUp`, a global monitor that takes nothing from the
  app) moves on after 0.45 s. Each step after the first is found by its words on
  the screen as it is then (`look`: a fresh capture read locally, nothing sent),
  so a menu's item the agent never saw is still pointed at; looked for twice,
  else the face goes where the agent put the step, or back to the pointer; a
  step whose words are still streaming waits for them. Escape ends the walk, and so does a
  minute with no click (`guideIdleLimit`): the face holds Escape while it is up.
- **What the keys do is said where they act** (`PaletteKeyHints`, a capsule of
  the shell's glass and ramp, always frosted, its keycaps round and concentric): under the region's orb "esc Cancel" while the
  microphone starts, "Speak your question · esc Cancel" while it listens, "⏎ Ask
  · esc Cancel" once something was said, filling from the left in the face's light under black words, its first fifth shown as nothing and what is
  drawn easing after it (`PaletteKeyHints.follow`: levels come in steps and fall at every word), as a pause runs
  toward sending by itself (`setRegionSilence`, the silence watcher's progress;
  speech empties it), and "Asking…" from Return or that pause until the face
  takes over (`regionHints`, `layoutRegionKeyHints`, riding the shell's spring,
  above it near the foot of the screen); under the face "esc Stop" while it thinks, and "Click to go on ·
  esc Stop" through steps (`AskBolttyController.keyHints`). At rest "⌥Space
  Ask more · esc Close" stands in the words' place. While no sound comes the
  orb says so and the tag keeps only Cancel.
- At most two sentences of an answer are said, one at a time: a new sentence
  takes the last one's place (`captionSentences`, `answerSentences`). The answer
  ends when the voice falls silent; `$speakingID` tells before the value changes,
  so it is read on the next turn of the run loop (asked at once, the voice was
  still saying it, and nothing ended the answer until the store moved).
- The answer comes beside the face word by word, each arriving out of the blur
  the listening words have (`ListeningWordsView`, `isCentred` off; "Thinking…", a step, an ask and a failure arrive so too, all at
  once), the bubble
  growing to fit what has come (`revealWords`, `growBubble`); a new sentence
  starts it afresh. **The words hold still**: the bubble's top stays and lines
  are added below, only the face bobs, and the side stays while the widest
  bubble fits, gliding across when it does not. On the left it stands at its
  whole sentence's width (the words hang from its left edge). The bubble is
  the shell's glass and ramp, with the worded orb's padding and its corner's
  share of the height (`bubbleCorner`), since a clamped corner made pills of it. Its
  window is never key, so the glass lights no rim and the rim shade, a black line
  there, is off (`shadesRim`). The bubble changes side rather than
  stand on the region or a drawing, where the other side is free (`bubbleSide`).
  **Drawings are a marker's** (`AskBolttyDrawingLayer`, `MarkerLine`): one colour,
  the face's strongest, with no gradient and no edge, a faint shadow of the same
  colour; the line sways, changes width with the hand and the direction, overshoots
  where it closes, and is the same each time it is drawn. A glow, a white edge and a
  gradient were tried and refused. A board is the marker's too, straight on the screen
  beside the bubble: on glass and on a sheet of paper it was refused. Labels are white
  pills with black words. It draws quickly, stroke after stroke, as a hand does. With blips
  (`AskBolttyBlips`, rendered on Core Audio's thread — its block is made
  `nonisolated`). Saying it aloud
  (`SpeechOutput`: Supertonic's 31 languages, once it is downloaded) is
  Settings › Ask Boltty › "Say answers aloud" (`boltty.talk.speaksAloud`,
  off; until Supertonic is here its download stands in the switch's place),
  read into `AskBolttySession.speaksAloud` as a question is sent. Said aloud,
  the words still type out, without blips over the voice.
- **The face waits after the answer** (`AskBolttyOverlayController.rest`): its
  words go once said, key hints say what can be done (`restHints`, gone after 5 s, since a bubble riding with the pointer gets
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
- Ask Boltty chats raise no banner, unread mark or notch line. They are kept, as
  any chat is (Settings › General › Keep chats), with the region and the whole
  screen each question was about (`AskedRegion`, on its `SentFile`; both counted
  in `filesInUse`), and are listed with the rest, marked by their region (*The chat list*). Ten minutes after the last answer, unless working, waiting or open in
  the panel, the chat's session is let go (`settleAskBolttyChats`,
  `ConversationEngine.releaseSession`) and the next region starts a new chat; a
  question within those ten minutes continues it. A chat nothing was asked in,
  and one from before Ask Boltty chats were marked, is forgotten. Gone on with in
  the panel it is the person's own chat
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
- Who answers: the chosen agent and model if ready; with none chosen
  ("Automatic", first on the strip and the default), whoever a new chat would go
  to among agents that take pictures, in its default model. **A used-up
  plan does not refuse a question**: unlike the panel, Ask Boltty passes over an
  agent, chosen or not (`AskBolttyController.targets`, in `AgentRouting`'s order or
  `AskBolttyConfiguration.ranked`'s), whose plan window is exhausted or that hit its
  limit here (until the reset, else 15 minutes), and says so beside the face
  ("Claude Code's limit is used up · Codex answers"). A turn that fails before
  any word — a limit, a model gone, any failure — gives the same question to the
  next agent, each once (`AskBolttySession.handOver`); with none left the face
  says why, with the reset time for a limit. Spent agents are tried last, not
  never, since the usage read may be stale. No model is
  hunted for by name: an "Automatic" that meant Claude Code on Haiku was tried and
  removed; today's Automatic names no agent and no model. Chosen in Settings › Ask Boltty as a strip of bare faces, no circle or
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
- **First run**: a show over a sky (`SunsetView` wearing a chat's Sky backdrop
  in Daybreak, at the screen's size; the written gradient is what README's shots
  stand on; `ShowSpace` maps 1800 × 1169 slides to the screen; its own clock,
  `ShowClock`). Everything in it moves on one curve, slow, then a sharp peak, then a
  long settle (`ShowClock.curve`), with no springs; a move begun in the middle of
  another keeps its speed (`ShowGlide`). `pace` (the waits) and
  `ShowClock.quick` (the moves) are how fast it runs; the music starts
  `musicStart` in, so its beat still comes in with the first line on white. One face is carried through every scene, and it is Boltty's
  own, the hexagon in Daybreak (`hero`): the one place Boltty has a face, since
  no agent has been chosen yet. Its beats: that face rising close, wider than
  the screen, on the sky; the title, "This is Boltty" a word at a time, with the
  agents' faces round it turning once like coins (`ShowFace.spin`,
  `MascotNSView.turn`). Then the sky gives way to one flat pale colour a scene
  (`SunsetView.field`, the face's own hue) with one thing on it, large, and before
  each a line alone on white (`card`): the prompt, ⇧Tab walking the agents and the
  field with them, the camera close on the words as they are typed, the capsule
  growing into the question and its answer; the agents' faces overlapped in a row
  with ⌄, opening into the chat list; Ask Boltty over
  somebody's window in bars (a region dragged round a part of it, the orb on its
  corner opening large as the camera comes in, the words, the face flying to the
  heading, a loop drawn round it and the answer in a bubble); the last line, every face in a row turning in
  turn, gathered into Boltty's own beside its name, and the sky again. There the
  panel is a plain black shape (`ShowSlab`), not glass: over a pale field the
  ramp's thin foot read as grey. A made-up app window with a menu bar, the panel
  at its own size under a caption, and a walk through Settings were there and were
  removed. A feature's real gesture changing means this script changes with it.
  The faces come with no flash of light. Its music (115 beats
  a minute, `show-music`) comes in with the first line on white, each line and
  scene after it waits for the next beat (`onBeat`), and the faces gathering is
  `show-ending`; clicks, blips, the ladder of ticks, a bell and a sub hit are
  one-shots in its key. After the feel of a promo's track, measured and not
  copied. A whoosh on every move was removed. An agent that wears Boltty's own
  face wears another here (`MascotRoster.looks(besides:)`). Then the setup card (agents, faces, keys, voice,
  permissions) on the panel's glass. With no agent on the Mac the first
  step says Boltty needs one, the face step is left out, and Not Now goes on. The voice step offers Parakeet and
  Supertonic, both unticked; a ticked one is chosen and downloaded in the
  background once setup ends (`installSetupVoices`), Apple's engine standing
  in until then. `-boltty.replayIntro YES`, `-boltty.skipShow YES`,
  `-boltty.setup.step N` in Debug. Launch with `open`, never the binary from a
  shell (TCC would attribute the request to the shell's app).
- **The menu-bar mark** (`StatusBarIconRenderer`, the hexagon with soft corners)
  stands still. Moves of its own, blinks and glances, were tried and removed; work is
  the notch face's to show. A click opens **Limits** under it
  (`UsageGlanceController`, rows from `ChatWorkspaceCoordinator.usageGlanceRows`):
  each listed agent's face and plan windows on frosted panel glass (clear let the
  window behind read through), straight on the glass with a gap between agents
  (a filled well round each took room and said nothing), read again as it opens; a click outside or Escape
  closes it. On the automatic route the agent a new chat would go to now says
  "Next chat" beside its name. Its foot has Settings › Usage and More, which is the old menu; a right
  or Control-click on the mark opens that menu at once.
- **Settings**: a sidebar of pages (General, Agents, Usage, Voice, Ask Boltty,
  Shortcuts), standard parts but for what is selected: the sidebar's rows and
  the segments are drawn here, since a `List`'s selection and a segmented
  `Picker` take the person's accent. The sidebar wears the page's grey: the
  system's sidebar glass took the wallpaper's tint beside it. A row (`SettingsSidebarRow`) leads with its page's
  tile (`SettingsPageTile`, 24 pt, as System Settings' are): a square picture, the maintainer's own, in
  `Resources/Icons/Settings/<page raw value>.png`, given its continuous corner
  (26 % of its side) in code so all six agree; the chosen row a
  quiet grey fill with semibold words: a yellow fill there shouted over the
  page. Every segmented choice is `GlassSegments` (one glass thumb on a grey
  track); a yellow one was drawn beside it on Usage and was retired. The sidebar
  takes the focus as it appears, so the arrows walk the pages and no control opens
  wearing a ring. The selected page is
  `boltty.settings.page` (`-boltty.settings.page agents` opens a page). The window
  opens at 760 × 560 (`BolttySettings` keeps its frame; the older
  `BolttySettingsWindow` and `BolttySettingsSidebarWindow` frames are inert) and
  is sized after its view controller is set; the sidebar width modifier is last on
  its column. Every key that can be changed is a grey capsule
  (`ShortcutRecorderCapsule`, 128 × 24, the accent while it listens, the same size
  either way so its row does not jump), and a built-in key is plain text, so what
  can be clicked shows; Shortcuts has a filter over its sections
  (`SettingsFilterField`). A whole agent row opens its page, its padding too.
- **A setting that changes what is seen shows it** (`SettingsStage`): the thing
  itself, a real view of the product in an `NSViewRepresentable`, over the
  person's own desktop (`DesktopPicture`, read once), changing as the control
  does: built of the parts the product draws with (its glass host, faces,
  backdrop renderer, attachment card, listening words), never a picture of them.
  Either it opens its group, the row's whole width an even 8 from the group's
  edges (`SettingsPreview`): Finder's selection (`FinderSelectionSample`),
  dictation's words (`DictationSample`) and Ask Boltty's answer beside the face
  (`AskAnswerSample`). Or the choice itself is tiles, each the thing in small
  (`AppearancePicker`, on `RingedChoice` with a `tile`): Panel glass's Clear and
  Frosted (`GlassSwatch`) beside Backdrop's Standard, Sky and Space
  (`BackdropSwatch`, the sky a still from the backdrop's own renderer,
  `AgentBackdropRenderer.still`). A slider and three large stages there made
  General three screens long. A switch of behaviour with nothing to see has
  none; New Chats and an agent's model had one and lost it.
- **App icon**: one, `AppIcon.icon` (Icon Composer); `.github/icon.png` is it
  rendered with Xcode's `ictool`. A choice of four was tried and removed: macOS has
  no alternate icons, so it only ever showed while a Boltty window was open.
  `boltty.appIcon` is a retired key, inert on disk.
- **Settings › Agents** opens on **New Chats** (two agents or more): a strip of
  bare faces, Automatic first (the enabled agents' faces gathered round one,
  `FaceCluster`) then each enabled agent (`NewChatsPicker`), and under it a line
  saying who takes the next chat. A picture of the first screen and of each
  agent's plan under the strip was tried and removed: the strip says it. A
  "Preferred" tag with a Make Preferred button on each agent's page was there
  before: to change it one had to open an agent. Then the list, one row per agent: face, name,
  one line of what a new chat would use (or why it can't), its switch.
  A row opens the agent's own page (`SettingsLocation`, in the back/forward
  history; only the page is stored): the agent and its switch,
  model, reasoning, permissions with the Auto Mode note once, and
  the face's shape, gradient and finish as rows. Never expand every agent on
  the list again. `-boltty.settings.agent claude` opens an agent's page.
- **Installing an agent** (`AgentInstaller`): one not here has Install in place of
  its switch (setup's first step, Settings › Agents). A press downloads the maker's
  own script, the one its site gives for `curl | sh`, over HTTPS and runs it off
  stdin, with no terminal, no `sudo`, 10 minutes at most; never without the press.
  All five ran so in 13–25 s and put the CLI where `ExecutableLookup` looks
  (2026-11). It runs on the person's own PATH, since the installers add their folder
  to the shell's profile only when PATH lacks it. `opencode.ai/install` is
  OpenCode 1; Boltty takes `/v2/install`. Signing in stays the person's, in a terminal.
- **Usage**: plan windows per agent (each: how much is used and when it
  comes back, as the composer's ring counts it — never what is left; the bar
  4 high and flat in the accent, `UsageMeter`; in black it read as no brand at
  all), and an overview counted
  off every CLI's own records (`AgentStatisticsReader`, cached per file in
  `Application Support/Boltty/Usage/statistics.json`); a chart of 14 days under
  each agent was there and was removed. Never summed across
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
  sideways strip of plain circles, each a mesh of two of Boltty's gradients
  (retired ones too), deepened, no faces (the faces' gradients alone read as
  one pale family; faces
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
- Six gradients (`MascotPalette`), written in OKLCH and mixed in Oklab; `lagoon` and
  `slate` are the stored ids of Mist and Lilac. Retired ids still load.
- **Every agent wears its own face**, chosen on its page in Settings › Agents; no two alike
  (`MascotRoster`). Stored as names in `boltty.mascotByProvider`. Where no agent
  speaks, the preferred agent's face is used; Boltty has no face of its own,
  but in the first-run show (the hexagon in Daybreak).
- One `MTKView` per face, one shared pipeline, drawn on demand from the shared
  60 Hz `MascotClock` timer (a display link measured worse). `currentDrawable`
  only inside `draw(in:)`. Nothing on the canvas may force an offscreen pass (no
  filter, mask, `masksToBounds`). Two rays a pixel live, four for stills; the first screen's
  face is drawn at twice the screen's scale (`promptMascotSupersampling`); extra
  rays only where a 2×2 quad disagrees; `shadeSolid` is `noinline`; the march is
  bounded by a box.
- Motion is Boltty's own (`MascotMotion`): layered attention, breathing and one
  action at a time; pokes pick a different reaction each time. Signs: yaw right,
  positive pitch up, roll clockwise, lift down.
- Judge looks from the contact sheets (`TEST_RUNNER_BOLTTY_CONTACT_SHEET=<dir>`),
  which draw into sRGB on purpose. `half` is a type in Metal.

## The voice glow and shader effects

- The glow (`UI/Voice/`, `VoiceEdgeGlowView`) draws nothing: its rays of the
  face's colours under the shell while listening were refused. The view stays
  for the take's clock and phase. Never `presentsWithTransaction` (it starved
  the run loop).
- The listening orb is the shell's glass and draws no light of its own.
- **Backdrops** (`AgentBackdropView`): what the chat list and the open chat
  wear behind their content, one choice for every agent in Settings › General ›
  Appearance (`boltty.backdrop`): Standard (the glass), Sky, Space. The first
  screen and the listening orb stay glass: a sky squeezed into them read as
  flattened. Its colours are the face shown (the chat's agent, the list tab's);
  the list's All tab wears a neutral grey sky (`AgentBackdropSky.slots(for: nil)`),
  and a change of face blends the ramp in Oklab over 0.6 s rather than jumping. The sky
  drifts at 1.6× its scene clock (`AgentBackdropView.pace`) and fades both in and
  out. It was a choice per agent for open chats only;
  `boltty.chatBackdrop.<agent>` is retired, inert. Matrix was removed; a stored
  `matrix` reads as Standard. Standard is the default, and nothing stores
  another for the person. Settings chooses it on tiles beside the panel's
  glass, each an open chat in small over the person's desktop wearing that
  backdrop (`BackdropSwatch`): the backdrop's own renderer, not a mock-up. It
  was `GlassSegments` over a large live chat; the segments are Usage's now (a
  dark capsule with one thumb of the system's glass, untinted, stretching toward
  the choice and swelling while pressed; the system's segmented `Picker` drew the
  person's blue, and `NSSegmentedControl` has no glass thumb outside a toolbar). Over the glass, under the
  transcript, dark at the top for the white prose. Each face has its own sky
  (`AgentBackdropSky`: zenith, horizon, cloud light, cloud shade, middle,
  glow, written in OKLCH), the feeling of the face's colour rather than a wall
  of it: a soft gradient through a few related shades, leaning across the chat
  and breathing, with clouds shaded in the sky's own colour; deeper than
  Messages' and rolled off under a brightness ceiling because the prose has no
  bubbles. The sky mixes in Oklab and its ceiling (`oklabCeiling`) lowers
  lightness alone, chroma kept, and cloud tops carry the sky's glow: dimmed in
  sRGB, white read as grey and yellow as olive. High clouds take their light from
  the sky behind them. Space reads the same Oklab ramp: each light (the
  glows, the stars, written in OKLCH, tinted toward the face's light at their
  own lightness) is tinted in Oklab and added in linear light, as light adds,
  then goes under the ceiling and darkens at the top by lightness alone. A sky between two hues opposite each other has a colour standing
  between them (Daybreak's violet, with rose cloud light): blue straight into
  orange mixed through grey. Space is a night of that sky: the
  ramp from a soft light in the middle (the middle tone, warmed a little by
  the glow: dark orange read as mud on Daybreak) to zenith at the edges, its shape loosened by drifting noise, at a lightness of
  about 0.1 and a fifth of its chroma, so the colour is seen to change, quietly
  (a near-black field with one blurred glow in a corner read as a stain; the
  same field coloured from that corner, as too loud), and stars in four depths: gathered in loose drifts, mostly faint, white,
  bluish, warm or in the face's light, the brightest with a halo and faint
  rays. No clouds, no milky way (each was tried and refused). The sky is after
  Messages' (read off `DynamicBackgroundPosterExtension`'s `clouds.vfx`:
  sprites warped by two scrolling noises, edges choked, ramp-tinted, three
  depths), with noise in place of their textures. **The corner is the
  layer's**, from the glass's rendered corner and curve; a squircle formula
  in the shader did not match. Sky draws a pixel per two points, Space at
  full scale; while the shell morphs (`morphingTo`) the sky is drawn
  once at the size it is going to, pinned to the shell's top and uncovered
  as it grows; where the shell is still wider or taller than that size it is
  scaled up just enough to cover (`cover`, through `contentsRect`), since bare
  edges read as a black rim, with its clock stopped so the live sky that takes over on
  settling is the same frame (redrawn at every size of the spring, the
  list-to-chat morph stuttered; held back, it popped in late); 20 fps, and the clock stops while the window is occluded (a hidden
  panel keeps the view).
- `UI/Effects/`: a thumbnail's reveal out of a blur, a sent card's whip to
  its place over the bubble, the selection border's light. Each always ends by a timer, is made
  through `make` (a failable `NSView` init crashes), and uploads textures as
  8-bit sRGB.

## Design contract (AppKit)

- **Icons are Boltty's own** (`BolttyIcon`, `Resources/Icons`;
  `BolttyIconView` in SwiftUI). Never an SF Symbol. A 16 × 16 grid, a 1.3 stroke with round ends, drawn only of lines and
  true circular arcs, every turn a tangent arc (1.25 at a joint, 2 for a medium corner,
  3.25 for a box's; 0.75 only on a pointer's tips; a few shapes keep a
  size of their own, such as the Return arrow's 2.75). The one turn with no arc is a
  tip: an arrow's strokes meet on their round ends, since a fillet made
  a blob of it. So nothing is sharp or nearly so, no curve is by hand, and a shape's
  two sides are one number. An icon is changed in `scripts/render-icons.py`, never in its file,
  and `scripts/check-icons.py` then judges the files: lines and arcs only, no kink at
  a joint, the ink clear of the edge. One colour, outlines only: no icon is a filled version of another. On a tile of its own colour (the permission window) it stands in white; Settings' sidebar tiles are pictures of their own. An icon is sized by its box (a chat's composer
  `ComposerControlGroup.iconSize`, a point over `glyph`; elsewhere about a
  fifth over the point size its symbol had, since the ink stops short of the
  box), and its stroke grows with the box. In the panel every icon's box then
  goes through `AgentPaletteMetrics.iconSide` (15% larger, `iconScale`), the
  buttons round them keeping their size. A small round mark is solid:
  stroked, it reads as a ring round a pinhole. So is Stop's square, which
  stroked read as an empty frame on the Send disc. So are the stars of `sparkles`, which
  stroked only fill up; that icon is the maintainer's own drawing, curves and all, kept
  to the letter by the generator and passed over by the check. `NSImage` draws the files as
  template images, so they are black, not `currentColor`, and **it blurs an
  SVG mask**: a solid with marks cut out is one plain path. Refresh shows the system's spinner while a press is at work: an arrow turned by
  hand could stop at any angle. The ink fills the box to about 1 from each edge,
  and a stroke breaks to let a small solid detail stand in the gap (a dot, a check).
  Icons stand still: a movement as the pointer came to a button was tried and removed.
- **Glass is the system's**, in five kinds: the shell (`PaletteGlassHost`, bare
  clear glass under a black ramp), controls (regular
  glass), glass buttons (`NSButton` with `.glass` bezel — `GlassCircleButton`,
  `GlassPillLabelButton`), the selected history tab, and help tags
  (`PaletteHelpBackdrop`). Density goes *over* the
  glass, never into its tint. The system's Tinted/Clear setting is respected.
  A glass host's corner must be set again whenever its size changes.
- The shell casts two shadows: a tight contact one and a pool behind the
  glass with the shell's shape cut out. Close and dense, not spread: at radius 50
  the pool read as a haze.
- **One corner for the shell's edge** (`PaletteCorner`): the glass host works it
  out (`PaletteGlassHost.renderedCorner`, radius and curve) and every layer on
  the edge takes it whole — ramp, rim shades, backdrop, content masks, listening
  words, voice glow, shadows. None works it out again from its own bounds. The
  curve is continuous at every size: the glass draws so even in a capsule, and
  circular layers over it left a dark sliver where the arc begins. **A change to
  the edge is read off the pixels** before it is called done: over white and grey,
  with the panel key (the glass lights its rim only then), clear and frosted, at
  the foot's middle, where the arc begins and at 45°, and in the frames of the
  drip. The moving shell is snapped to pixels (`drawSurface`): between them the
  ramp covers half of the rim and it flashes.
  A layer inside the edge is concentric (`inset(by:)`). Clipping is a layer's
  corner, never a `CGPath`: a path has no continuous curve, so `path(in:)` is
  only for what is blurred or stands inside the edge. **No two antialiased
  edges share a pixel**: what lies under the glass's edge runs
  `PaletteCorner.edgeOverlap` (2) under it. The pool's hole cut exactly at the
  edge left a light hairline round the foot where neither covered the desktop.
- The transcript dissolves under floating controls (a gradient mask, and in the
  history a private `variableBlur` filter); in a chat it is gone by the back
  disc's middle, as the list's rows are by its foot discs'; the scroll indicator bends round the
  shell's corners (`PaletteCornerScrollIndicator`).
- **Type**: five sizes in `AgentPaletteMetrics` — 18, 15 (`typeSecondary` and
  `typeChat`), 13, 11; the first screen's 20 is the exception (key hints
  take the typed size), and so are the notch badge's digit at 9 and a chat's folder
  and model chips at 14.5 (`folderChipFontSize`). Whole points only, SF Pro Rounded everywhere, no `.kern`.
- **Colour**: `PaletteInk` — system label colours (dynamic) and fills written as
  values (they end up as `CGColor`). Pure white only for primary-action fills.
  **A colour with a hue is written in OKLCH** (`OKLCH(l, c, h)`, `Models/OKLCH.swift`),
  never as hex or RGB, and lands in Display P3, giving up chroma, never hue, past it.
  White, black, greys and the system's colours stay as they are. **Colours are mixed in
  Oklab**: a gradient of hues goes through `OklabGradient`, since Core Animation and
  Core Graphics mix stops in RGB and two far hues met in grey, and a shader mixes
  through `UI/Effects/OklabShading.h` (`srgbMix`, `oklabToSRGB`, `oklabCeiling`).
- **The accent is Boltty's, not the system's** (`BolttyBrand`, off the app icon;
  [BRAND.md](BRAND.md) says where it goes). `controlAccentColor` and
  `Color.accentColor` are not used: an `NSAccentColorName` counts only while the
  person's own accent is Multicolor. It is always a fill, under black words (white
  is 1.5:1): words in it were unreadable on white, and an ink dark enough to read
  was brown and was refused. `.tint` goes on the control (`BolttySwitchStyle`,
  `.bolttyProminentButton()`), never a page: on Settings' root it turned every
  button's and menu's words yellow on white. Focus rings and text selection stay
  the person's.
- **No borders.** A surface is told by its fill or its glass, a chosen thing by
  a flat fill; nothing is finished with a stroke or a hairline round it. The
  glass's own edge is the system's. Left on purpose: table rules, a quote's bar,
  the work thread, the screen selection's edge, the Ask pointer's white edge
  (it stands on any screen), `RingedChoice`'s ring, and the 1-point inner edge
  of white at 20% on Settings' sidebar tiles (`SettingsPageTile`).
- **Spacing**: numbers read off a mock go through `fromMock` / `fromHistoryMock`,
  snapped to the half-point grid. The shell's inset is 12, and nested corners are
  concentric (`outer = inner + inset`), in Settings too: a stage that fills its
  section stands an even `sectionGap` from every edge with the section's corner
  less that (`SettingsStageMetrics`; the section's 11 and the rows' insets, 10
  each way, read off the pixels on macOS 27, not by eye: a `Form` ignores
  `listRowInsets` across). The composer's content stands 16 from
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
- **Help tags** (a view that shows one keeps its `toolTip` from AppKit, as
  `PaletteIconButton` does, or the system's shows too) are drawn like a menu row inside the panel, above the control,
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
  The Edit menu carries Undo, Redo and Cut: without them ⌘Z and ⌘X did nothing in
  the prompt. The recorder refuses a chord another row holds and names it.
- Never use `Date.FormatStyle`: on a locale with a regional override
  (`en_US@rg=uazzzz`) it returns empty strings. Use `DateFormatter` built from
  templates.

## Languages

- Every word the person reads goes through the String Catalog
  (`Resources/Localizable.xcstrings`; usage descriptions in
  `InfoPlist.xcstrings`): `String(localized:)` in AppKit and wherever a
  `String` is passed on, a literal in SwiftUI's own `Text`, `Button`, `Toggle`,
  `Picker`, `.help`. English is the source. The language is chosen in Settings ›
  General › Language (`AppLanguage`): the app's own `AppleLanguages`, the
  value System Settings › Language & Region › Applications writes, so the two
  agree; Follow System removes it. Each language is named in itself. It applies
  from the next launch, so a change offers Relaunch Boltty
  (`UpdateInstaller.relaunch`, the new copy waiting for this one to quit).
- A sentence is one key with its values inside (`"\(name) is not ready."`),
  never glued from pieces: word order differs. A count is its own key with
  plural variants (`"\(count) replies"`); Ukrainian has four forms.
- What goes to an agent stays English and is never localized: prompts
  (`AskBolttyPrompt`, `AskBolttyConfiguration`), refusal messages the model
  reads (`readOnlyRefusal`, `denialMessage`, the gate's reasons), the
  `[Selected on screen…]` bracket. So do stored values (`ConversationEngine.untitled`),
  ids, `case` patterns and JSON keys. Key names on keycaps stay Latin.
- One English word in two senses is two keys: "Clear" glass and "Clear the
  filter" read differently in Ukrainian. The catalog holds English,
  Ukrainian, German, French, Spanish, Brazilian Portuguese, Japanese,
  Simplified Chinese and Korean (`uk de fr es pt-BR ja zh-Hans ko`), each
  with its own plural forms; a string added in English is translated into all
  of them in the same change. Russian is not offered.
- SF Pro Rounded has no CJK glyphs, nor does SF Pro: the system font's cascade
  draws them in Hiragino Sans (ja), PingFang SC (zh-Hans) or Apple SD Gothic
  Neo (ko), chosen by the app's language, inside SF Pro Rounded's line height
  (measured). Nothing in Boltty names a CJK font.
- A label in a control of fixed width is measured in every language: the
  shortcut capsule (`ShortcutRecorderMetrics`, 128) took "Record Shortcut" only
  as one short word in Ukrainian, German, French and Japanese.
- Tests read English: `-testLanguage en` in `test.sh` and CI, and `language`
  on the scheme's TestAction only (XcodeGen's `language` would set Run too, and
  the scheme is restored from git after `xcodegen generate` anyway).
- `scripts/sync-strings.sh` builds and merges the compiler's extraction into
  the catalog, as Xcode does on its builds; run it after changing strings.

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
- The README's pictures (`.github/readme/`) are stills of the real panel and overlay
  over Boltty's own sunset, taken by `ReadmeShotsOnScreen`
  (`TEST_RUNNER_BOLTTY_README_SHOTS=<dir>`; it takes the screen for about 40 s, and
  shows the Standard backdrop on clear glass whatever this Mac chose). The PNGs go in
  as WebP: `cwebp -q 92 -m 6 -sharp_yuv -metadata icc`.
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
11. **Write no comments.** 99% of comments in code are not needed, so the default
    is none. Forbidden: a comment on what the code already says, a doc comment by
    habit, a section heading, history of what was tried, the story of the bug a
    change fixes (that is the commit message), a fact already in this file. The
    other 1% is a reason that is not obvious and would be missed (a measured CLI
    quirk, a trap): one line, two at most, and it says why. In doubt, leave it out.
    Who decided and when belongs in git.
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
- **Boltty Design** (`Design/`, `make design`) is an app of its own, with its own
  project made by XcodeGen on each run: the product's sources but `main.swift`,
  built with `BOLTTY_DESIGN`. Nothing of it is in Boltty's target or a release. It
  shows foundations, elements and the panel in each state with the parts the
  product draws with, over a chosen ground, starts none of the product and writes
  none of its settings. Pick an Element (⌘E) names what is clicked by the property
  that holds it, and Copy for Claude says where it is written and its values. A new
  element, icon or panel state gets its sample there in the same change (icons,
  faces and values list themselves). Its words are not localized.
- A value written `{ live(12) }` (`LiveValue`) is the value itself in Boltty; Boltty
  Design gives it a slider on the pages that read it, and Save writes its line of
  Swift. The source is the truth, read at launch and as the window comes forward.
  The line keeps that exact shape (a number, `NSColor(oklch:)`, or white or black
  with an alpha), and what is worked out from one is a computed `static var`, never
  a `static let`, which would keep the first value. A cache of measurements is
  cleared as a page is made again (`forgetMeasurements`).
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
