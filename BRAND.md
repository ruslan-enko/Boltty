# Boltty brand guidelines

How Boltty looks and speaks. [AGENTS.md](AGENTS.md) holds the design contract for
the code (grids, metrics, motion); this file says what the brand is and where its
colour goes.

## The idea

Boltty is a small warm thing on a Mac that gets out of the way: one key, a panel,
an answer. The brand is **a honey-coloured hexagon and rounded type**, on top of a
Mac that otherwise looks like a Mac.

Three rules follow from that:

- **Native first.** Windows, controls, materials and neutral colours are the
  system's. Boltty adds a colour, a typeface and a voice, not a skin.
- **Yellow is rare, so it means something.** It says "on", "chosen" or "this is
  the one to press". A screen with yellow everywhere has said nothing.
- **Yellow is a fill, never words.** Yellow on white can't be read, and darkened
  until it can it turns brown, which is no colour of ours. So a chosen thing is a
  yellow shape with black words on it, in both themes.

## Name

| Write | For |
|---|---|
| **Boltty** | the product. One word, capital B, two t's. Never BOLTTY or boltty in prose |
| **Boltty AI** | the panel on ⌥Space. Never "Spotlight" |
| **Ask Boltty** | selecting an area of the screen and asking about it out loud |

An agent's own name appears only where Boltty is naming that agent: a picker row,
a status line, an error.

## The icon

A soft hexagon of light on a honey field. It is defined in
`apps/macos/AppIcon.icon` (Icon Composer) and rendered to `.github/icon.png`.

| | Field | Hexagon |
|---|---|---|
| **Light** | gradient, `#FFEB01` to `#FFA500` | white, fading downward into the field |
| **Dark** | the system's dark icon field | white at the top, fading to `#FFB815` |

- The icon is the logo. There is no separate wordmark: where the name stands beside
  it, it is set in SF Pro Rounded.
- Use the rendered icon, never a redrawing. Don't recolour, outline or flatten it,
  don't put a face in the hexagon, and don't set the icon on a yellow ground.
- Leave at least a quarter of its width clear on every side.
- Boltty has no mascot of its own. Each agent wears its own face, and those faces'
  gradients are the agents' colours, not the brand's.

## Colour

Values are Display P3 where the code writes them so; the hex is the sRGB reading.

| Token | Light | Dark | Swift | For |
|---|---|---|---|---|
| **Honey** | `#FFEB01` | | icon only | the field's top |
| **Amber** | `#FFA500` | | icon only | the field's foot |
| **Accent** | `#FFBF00` | `#FFC800` | `BolttyBrand.accent`, `Color.bolttyAccent` | always a fill: what is selected, a switch that is on, a meter, chart bars, a chosen ring, a tag, the one prominent button |
| **On accent** | `#000000` | `#000000` | `BolttyBrand.onAccent`, `Color.bolttyOnAccent` | words and glyphs on an accent fill |
| **Accent on glass** | | `#FFC800` | `BolttyBrand.accentOnGlass` | the accent on the panel's glass, always dark; fixed because it ends up as a `CGColor` |

### Contrast, measured

| Pair | Ratio | Verdict |
|---|---|---|
| Black on Accent | 12:1 and up | use this |
| **White on Accent** | 1.5:1 | **never** |
| **Accent on white** | 1.6:1 | **never as words**; as a shape only, with its figure or name beside it |

### Where the colour goes

| Yes | No |
|---|---|
| The selected page in the sidebar: yellow, with black icon and words | Words or icons in yellow, in either theme |
| The chosen segment | A darkened yellow or brown, anywhere |
| A chosen name under a face: a yellow capsule | Button and menu labels (they stay in label colour) |
| A tag ("Preferred"): a yellow capsule | Large backgrounds and page washes |
| A switch that is on | A warning or an error (those keep the system's orange and red) |
| A chosen ring or outline | Agents' faces and chat backdrops |
| A meter, with its figure beside it | Every button in a row |
| Chart bars and the activity grid | |
| The one default button in a window or on a card | |

While the window is not the one in use, a selection goes the system's quiet grey,
as a Mac's own selections and switches do.

Everything else is the system's: label and secondary colours, window and card
surfaces, separators. So are the **focus ring and text selection**, which follow the person's own accent colour: they are about the
person's Mac, and macOS gives an app no way to change them while that colour is
set.

The panel's Send disc is the exception on purpose: white, with Return in black,
the composer's one pure-white fill.

Permission tiles (microphone, Screen Recording, notifications, Finder) keep their
own colours so the four can be told apart at a glance. They are icons, not accents.

### In code

- Use `BolttyBrand` and `Color.bolttyAccent`. Never `controlAccentColor`,
  `Color.accentColor` or a colour written out elsewhere.
- Don't set `.tint` on a page or a window. It reaches every button's and menu's
  words, yellow on white. Put it on the control: `BolttySwitchStyle` for switches,
  `.bolttyProminentButton()` for the one prominent button.
- A system `List` selection and a segmented `Picker` take the person's accent and
  can't be told otherwise, so Settings draws its own: `SettingsSidebarRow`,
  `SettingsSegments`, both through `SettingsSelection`.
- An `NSAccentColorName` would not do this job: the system honours it only while the
  person's own accent is Multicolor, so a Mac set to blue stays blue.

## Type

**SF Pro Rounded, everywhere**, the same family in the icon's company, in Settings
and in the panel. Whole points only, no tracking (`.kern`).

| Size | In the code | Where |
|---|---|---|
| 20 | `promptFontSize` | the panel's first screen |
| 18 | `typePrimary` | a title, the top of the scale |
| 15 | `typeSecondary`, `typeChat` | the transcript, secondary text |
| 13 | `typeMeta` | what is said about the content |
| 11 | `typeFootnote` | the smallest: tags, footnotes |

Settings uses the system's text styles in the rounded design
(`BolttyInterfaceTypography`), so it follows Dynamic Type.

## Shape

- Soft, continuous corners and no hard vertex, like the hexagon's. Nested corners
  are concentric: outer = inner + inset.
- Borders are filled, not stroked. Shadows belong to the panel's glass alone.
- Glass is the system's, and density goes over it, never into its tint. Never tint
  glass with brand yellow as a surface: only a button's fill may be yellow.
- Icons are Boltty's own (`BolttyIcon`): a 16 × 16 grid, 1.25 stroke, round ends, one
  colour. Never SF Symbols.

## Voice

Boltty speaks like a helpful person who respects your time.

- **Plain and short.** "Transcripts stay on this Mac." Not "Your data privacy is
  our priority."
- **Say what will happen, then stop.** "Boltty asks GitHub once a day and tells you;
  it installs only when you say so."
- **Say why when something can't happen, and what to do.** "Signed out. Run
  `claude auth login` in a terminal, then refresh."
- **Refusals are said, not hidden.** A control that can't work isn't shown, and an
  agent that isn't ready is refused out loud, never swapped.
- **No exclamation marks, no emoji, no "AI magic".** A friendly word is allowed
  where it is earned: the first run ends on "Let's Go".
- **Mac conventions:** title case on buttons and menu items ("Show in Finder"), an
  ellipsis when a press asks something more ("Clear History…"), sentence case
  everywhere else. British spelling ("Behaviour").
- **Progress is one or two words:** `Working`, `Thinking`, `Reading upscale.py`,
  `Needs your approval`, `Listening`.
- **Banners name the chat and the state, never the reply.**

Code, identifiers and commits are in English. The app's own words are too; answers
come in the language of the question.

## Motion

Critically damped springs and short fades, no flourishes. A keystroke is answered,
not animated. Yellow never pulses or glows to get attention. Under Reduce Motion
geometry settles directly. Numbers are in AGENTS.md.
