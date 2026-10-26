# Contributing to Boltty

Thanks for taking a look. Boltty is a native Swift/AppKit app with no
third-party packages, so getting it running is mostly opening Xcode.

## Before you start

- **macOS 26+** and **Xcode 27** (the app targets macOS 26; the glass uses the
  macOS 27 SDK where it's there).
- At least one agent CLI on your `PATH` — `claude`, `codex`, `opencode`,
  `grok` or `agy` — if you want to do more than look at the UI.
- For anything bigger than a small fix, open an issue first so we can agree on
  the shape before you spend the time.

Read [ARCHITECTURE.md](ARCHITECTURE.md) for how the app is put together.
[AGENTS.md](AGENTS.md) is the detailed rulebook: written for coding agents,
but it's where the hard-won facts about each CLI live, and it's worth reading
before touching an adapter.

## Build and run

```bash
cd apps/macos
open Boltty.xcodeproj    # ⌘R
```

Or with `make` from the repository root (`make` alone lists the targets):

```bash
make run        # Debug build, then open it
make install    # build what's on disk into /Applications
make test       # tests for what you changed
make lint       # both linters
```

From the command line:

```bash
cd apps/macos
xcodebuild -scheme Boltty -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .derivedData build
open .derivedData/Build/Products/Debug/Boltty.app
```

Always use `.derivedData` (Xcode is set up to use it too). A second
DerivedData means a second `Boltty.app`, and two copies fight over the global
hotkey and the conversation store; a stale binary looks exactly like a
current one.

**Keep your permissions between builds.** macOS ties microphone, Screen
Recording and Input Monitoring grants to the app's signature. An ad hoc build
gets a new one every time, so you'd be asked again and again. Run this once:

```bash
apps/macos/scripts/setup-local-signing.sh
```

It creates a self-signed "Boltty Development" identity in your login keychain
and makes Debug builds use it.

**Install what you have into Applications**, uncommitted changes included:

```bash
apps/macos/scripts/release.sh --local
```

It builds for this Mac, quits the running Boltty, replaces
`/Applications/Boltty.app` and opens the new one.

**Try it without touching your real chats and settings:**

```bash
apps/macos/scripts/run-isolated.sh
```

## Project layout

```
apps/macos/
  Sources/Boltty/
    Chat/            conversations, the engine, and one folder per agent adapter
    UI/              the panel, Settings, the notch, the first run
    Services/        hotkeys, dictation, speech, screen capture, updates
    Models/          plain value types
  Tests/BolttyTests  unit tests (and opt-in live tests against real CLIs)
  scripts/           build, release, test selection, linters
  project.yml        the XcodeGen spec
```

## Tests

The full suite takes about a minute. While working, run only the suites your
change can affect:

```bash
cd apps/macos
./scripts/test.sh          # suites covering the files you changed
./scripts/test.sh -n       # just print which ones it would run
./scripts/test.sh --all    # everything, once, before you open a PR
```

`test.sh` finds the suites by name: it reads the types declared in each
changed file and runs every test file that mentions one of them.

Some tests talk to the real CLIs. They're skipped unless you ask for them, and
the handshake ones cost no tokens:

```bash
TEST_RUNNER_BOLTTY_LIVE_AGENTS=1 xcodebuild -scheme Boltty -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .derivedData \
  -only-testing:BolttyTests/AgentAdapterLiveTests test
```

UI tests (`BolttyUITests`) drive the real mouse and keyboard, so they're never
selected automatically; name them when you mean to run them.

Two things that save time: a failing XCTest can look like a hang (printing a
failure takes a while), so `sample <pid>` the test host before suspecting a
deadlock; and tests use `isolatedDefaults(…)`, never
`UserDefaults(suiteName:)`, which leaves files in `~/Library/Preferences`.

## Linters

```bash
apps/macos/scripts/lint-architecture.sh   # structural rules (see below)
apps/macos/scripts/lint-design.sh         # the AppKit design contract
```

The architecture linter holds a handful of invariants: nothing under `UI/`
starts a process, `NSPanel`, the status item and the Carbon hotkey each live in
one file, resumes go by stored id, no `bypassPermissions`, and the shell is
called in exactly one place. The design linter fails only on new debt;
`scripts/lint-baseline.txt` lists the old, and it should only ever shrink.

## Adding an agent

Every agent sits behind one protocol, `AgentClient`
(`Chat/Agent/AgentClient.swift`), and is listed in `AgentRegistry.live()`.
Nothing above that seam knows which CLI it's talking to, so a new agent is a
new adapter folder and one line in the registry.

A few rules from experience:

- **Measure the CLI, don't trust its docs.** Run it, record what it prints
  (`scripts/record-cli.py`), and build the adapter from that. Replay the
  recording in tests (`Tests/BolttyTests/Fixtures/replay-cli.py`). Read a
  recording before committing it; it can contain your paths and account.
- **Declare capabilities honestly** (`AgentCapabilities`). The UI shows a model
  menu, a stop button or a permission card only where the adapter declares it.
  A control the CLI can't honour is worse than no control.
- **Read history from the CLI's own record** (its transcript file or
  database), never by asking the process to replay it.
- **When the CLI refuses to start, pass its last stderr line up.** A startup
  failure reported later as something else can't be acted on.

## Changing the Xcode project

`project.yml` is the source of truth; files under `Sources/` and `Tests/` are
picked up as folders. After adding a file:

```bash
cd apps/macos
xcodegen generate
git checkout Boltty.xcodeproj/xcshareddata/xcschemes/Boltty.xcscheme
```

XcodeGen rewrites the shared scheme every time, so put it back as above.

## Pull requests

- Keep a PR to one thing. A UI change is easier to review with a screenshot or
  a short recording.
- Commit messages are short and lowercase after a type, the way the history
  reads: `feat(voice): …`, `fix(palette): …`, `docs: …`, `chore: …`.
- Comments explain *why* something is the way it is. Who decided and when
  belongs in git, not in the code.
- Run `make test-all` and `make lint` before you push. CI runs the linters
  and a build on every pull request.

## Releases

Maintainers only. `scripts/bump-version.sh X.Y.Z`, commit, then
`scripts/release.sh`, which builds the last commit into a DMG and prints the
`git tag` and `gh release create` commands to run. It never publishes
anything itself. Signing details are in [AGENTS.md](AGENTS.md#releasing).
