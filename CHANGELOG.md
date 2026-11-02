# Changelog

What changed from release to release. The newest is at the top.

## 0.3.0

**Voice**
- Natural voices that run on your Mac, downloaded only when you ask: in
  setup's new "Your voice" step or in Settings › Voice.
- Parakeet takes dictation in 25 European languages and tells them apart
  itself, Ukrainian and English in one sentence included. It needs only the
  microphone.
- Supertonic reads answers aloud in 31 languages, Ukrainian included. English
  names inside a Ukrainian sentence are said in English. It replaces the
  Mac's voices, which Boltty no longer uses: Settings › Voice lists its ten
  voices and nothing else.
- "Read answers aloud" (Never, When I Asked by Voice, Always) reads the start
  of an agent's answer when it finishes.
- Ask Boltty can say its answers aloud.

## 0.2.9

**Boltty AI**
- The composer stands in two groups: attach, Auto Mode and folder on the
  left; the usage ring, the microphone and Send on the right. Send is a white
  disc.
- Auto Mode is the word "Auto", white when on.
- A chat's backdrop fades in smoothly.

**Agents**
- OpenCode offers reasoning levels and Auto Mode, and Settings names the
  model a new chat uses by default.

**First run**
- The intro shows more of Boltty: the panel growing into a chat, every
  agent's face, the chat list, Ask Boltty pointing at a menu, and Settings.

## 0.2.8

**Fixes**
- After installing an update, the old copy of Boltty quits instead of
  hanging beside the new one. A copy left hanging by an earlier update is
  closed by the new one, so it no longer starts read-only.

## 0.2.7

**Boltty AI**
- An open chat can wear a backdrop, chosen per agent in Settings: Standard
  glass, Sky, Space or Matrix, each in that agent's colours.
- Key hints read like Siri's: what you typed, then "— Ask Claude".
- The chat list shows what a working chat is doing right now ("Reading
  upscale.py") with a soft shimmer; ↑/↓, ⌘↑/⌘↓ and Page Up/Down move through
  it without jumping.
- Auto Mode in the composer is an Ⓐ.

**Agents**
- OpenCode works in Desktop, Documents, Downloads, iCloud Drive and external
  drives. Its background service isn't allowed into those folders by macOS,
  so Boltty runs those chats on its own server.

**Settings**
- Agents is a list; each agent has its own page with its model, reasoning,
  permissions and face.
- Usage meters and charts are drawn in each agent's colours, readable in
  Light and Dark.

**Fixes**
- A second copy of Boltty, running read-only, no longer starts chats or
  changes your shortcut.
- Quit waits for every running turn to stop.

## 0.2.6

**Updates**
- Installing an update no longer hangs on *Installing Boltty…* with a second
  Boltty opening beside it: the old copy quits and the new one takes its
  place. The update *to* 0.2.6 still runs the old code, so if it hangs, quit
  Boltty from the menu bar once; updates after it are fixed.

## 0.2.5

**Boltty AI**
- The chat list has two buttons at its foot: **New Chat** (+, or ⌘N) on the
  right starts a chat with the agent of the tab you're on, and **Settings** on
  the left opens Settings.

## 0.2.4

**Voice**
- The listening orb is dark at rest and lights at its edges as you speak,
  in waves that run round the rim; its colours follow the agent's face.
- Read aloud uses a voice that actually speaks for Boltty. Siri's voices,
  which macOS only plays for Apple's own apps, are no longer offered;
  Settings › Voice has a Reading voice picker with a preview, Automatic
  picking the best voice you have installed.

## 0.2.3

**Updates**
- Boltty installs its own updates. When a new version is out, *Install
  Boltty X…* in the menu bar and in Settings asks first, then downloads it,
  checks it, puts it in place and opens it again. It installs only a copy
  signed the same way as yours, so permissions you granted stay granted;
  anything else opens the release page instead.
- Coming from 0.2.2 or earlier, install this one by hand; updates after it
  arrive on their own.

## 0.2.2

**Boltty AI**
- A chat shows its transcript from the first turn, with the agent's face on a
  working line under it, instead of a separate thinking screen.
- Files in the chat are filled cards with a larger picture; their actions
  appear on hover.
- Prompt chips are glass pictures that name their kind — file, image, text,
  link; what each holds shows under the pointer.

**Ask Boltty**
- What you say shows beside the face while you hold ⌃⌥⌘.
- Answers are at most two sentences, shown one at a time: a new sentence
  replaces the one before.

## 0.2.1

**Usage**
- Plan limits come back after you sign in again in a terminal, without
  restarting Boltty. The page checks every agent's sign-in when it opens, when
  its window comes forward, and on Refresh.
- An agent that is signed out shows its face and the command that signs it in
  (`claude auth login`, `codex login`, `grok login`), with a button to copy it.
- An expired Claude Code login is now recognised as signed out.

## 0.2.0 — first public release

The first version anyone can download.

**Boltty AI**
- ⌥Space opens a floating prompt from anywhere; Return starts the chat in the
  background without taking focus away from what you're doing.
- The same panel shows the chat: answers as they stream, tool calls folded
  into one line per step, files the agent made as cards, a stop button, and a
  queue for what you type while a turn runs (⌘Return adds it to the running
  turn instead, where the agent supports that).
- Permission and question cards that look like a Mac dialog. Type words
  instead of pressing Deny, and they go to the agent as the reason.
- ↓ for recent chats, grouped by day with a tab per agent; right-click a row
  to show it in Finder or delete it (it goes to the Trash).
- Drag across the screen to ask about that region; the agent gets the picture
  and the text read off it.
- Paste or drop files and pictures into the prompt.
- Pick a working folder per chat, with recent folders and the git branch shown.
- Resizable chat and history, remembered between launches.

**Ask Boltty**
- Hold ⌃⌥⌘, ask about the screen out loud and circle what you mean. The
  answer types out next to the pointer, and the agent can point at things and
  draw on the screen while it explains.
- Follow-up questions within ten minutes continue the same chat.
- Read-only by default.

**Agents**
- Claude Code, Codex, OpenCode, Grok and Antigravity, each over its own
  interface, with models, reasoning effort and Ask/Auto permission mode chosen
  per agent in Settings.
- Each agent gets its own mascot: six shapes, six gradients, velvet or fur.
- Usage in Settings: plan limits per agent and activity across every CLI.

**Everything else**
- On-device dictation through Apple's speech engine, with an optional second
  language.
- A face by the notch while something is running, waiting or done.
- A first-run intro and a short setup: agents, faces, keys, permissions.
- Open at login, interface sounds you can switch off, and every keyboard
  shortcut listed in Settings.
- Notify-only updates: Boltty checks GitHub once a day and tells you when a
  new release is out. It never installs anything by itself.
