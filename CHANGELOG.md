# Changelog

What changed from release to release. The newest is at the top.

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
