---
name: deckex
description: A Commander deck read on a playmat under low light — always dark, art-led, monospaced where a number is being compared
colors:
  felt: "#0b120e"
  rail: "#0f1813"
  surface: "#131d17"
  surface-2: "#192720"
  inlay: "#070c09"
  chip: "#203028"
  ink: "#e8ece5"
  ink-secondary: "#b6c0b6"
  ink-muted: "#949f96"
  ink-faint: "#848f85"
  ink-disabled: "#4a544c"
  hairline: "rgb(232 236 229 / 7%)"
  hairline-soft: "rgb(232 236 229 / 10%)"
  hairline-strong: "rgb(232 236 229 / 15%)"
  focus-ring: "rgb(232 236 229 / 55%)"
  scrim: "rgb(7 12 9 / 72%)"
  scrim-soft: "rgb(7 12 9 / 45%)"
  scrim-deep: "rgb(7 12 9 / 92%)"
  mana-w: "#f8f0d8"
  mana-u: "#4a90d9"
  mana-b: "#8b7d94"
  mana-r: "#e05c48"
  mana-g: "#4fa363"
  mana-c: "#9aa0aa"
  sev-critical: "#e2559f"
  sev-warning: "#e3a93c"
  sev-healthy: "#35bda6"
  sev-info: "{colors.ink-muted}"
typography:
  display:
    fontFamily: "Archivo, system-ui, sans-serif"
    fontSize: "34px"
    fontWeight: 700
    lineHeight: 1.1
  title:
    fontFamily: "Archivo, system-ui, sans-serif"
    fontSize: "26px"
    fontWeight: 600
    lineHeight: 1.15
  heading:
    fontFamily: "Archivo, system-ui, sans-serif"
    fontSize: "20px"
    fontWeight: 600
    lineHeight: 1.2
  lead:
    fontFamily: "Archivo, system-ui, sans-serif"
    fontSize: "16px"
    fontWeight: 400
    lineHeight: 1.5
  body:
    fontFamily: "Archivo, system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.55
  caption:
    fontFamily: "Archivo, system-ui, sans-serif"
    fontSize: "12px"
    fontWeight: 400
    lineHeight: 1.4
  label:
    fontFamily: "Archivo, system-ui, sans-serif"
    fontSize: "11px"
    fontWeight: 600
    letterSpacing: "0.1em"
    textTransform: "uppercase"
  micro:
    fontFamily: "Azeret Mono, ui-monospace, monospace"
    fontSize: "10px"
    fontWeight: 400
  numeral:
    fontFamily: "Azeret Mono, ui-monospace, monospace"
    fontSize: "28px"
    fontWeight: 600
    lineHeight: 1
  numeral-sm:
    fontFamily: "Azeret Mono, ui-monospace, monospace"
    fontSize: "15px"
    fontWeight: 500
  scale:
    micro: "10px"
    label: "11px"
    caption: "12px"
    body: "13px"
    body-lg: "14px"
    lead: "16px"
    heading: "20px"
    title: "26px"
    display: "34px"
    numeral-sm: "15px"
    numeral: "28px"
rounded:
  xs: "4px"
  sm: "6px"
  md: "8px"
  lg: "11px"
  card: "13px"
  xl: "16px"
  pill: "9999px"
elevation:
  contact: "0 8px 20px -10px rgb(0 0 0 / 85%), inset 0 1px 0 rgb(232 236 229 / 7%)"
  lifted: "0 24px 50px -16px rgb(0 0 0 / 90%), inset 0 1px 0 rgb(232 236 229 / 10%)"
frames:
  art-crop: "626 / 457"
  card: "488 / 680"
components:
  mana-pip:
    size: "16px"
    rounded: "{rounded.pill}"
    background: "the mana token, or a 135deg hard-stop across two for hybrid"
    glyphColor: "{colors.inlay}"
    fontFamily: "Azeret Mono, ui-monospace, monospace"
  mana-pip-absent:
    background: "transparent"
    ring: "inset 0 0 0 1px {colors.hairline-strong}"
    glyphColor: "{colors.ink-disabled}"
  stat:
    backgroundColor: "{colors.surface}"
    rounded: "{rounded.lg}"
    padding: "12px 16px"
    border: "1px {colors.hairline}"
    borderAlarm: "1px color-mix(in srgb, <tone> 32%, transparent)"
    numeral: "{typography.numeral}"
  finding-alarm:
    backgroundColor: "color-mix(in srgb, <severity> 10%, transparent)"
    border: "1px color-mix(in srgb, <severity> 28%, transparent)"
    rounded: "{rounded.lg}"
    padding: "14px 16px"
    mark: "8px dot in <severity>"
    textColor: "{colors.ink}"
  finding-quiet:
    backgroundColor: "{colors.surface}"
    border: "1px {colors.hairline}"
    rounded: "{rounded.lg}"
    padding: "14px 16px"
  card-tile:
    backgroundColor: "{colors.surface}"
    rounded: "{rounded.card}"
    border: "1px {colors.hairline}"
    shadow: "{elevation.contact}"
    artAspect: "{frames.art-crop}"
    captionPadding: "10px 12px"
  curve-bar:
    fill: "linear-gradient(to top, color-mix(in srgb, <tone> 16%, transparent), color-mix(in srgb, <tone> 40%, transparent))"
    emptyTick: "2px {colors.hairline-strong}"
    rounded: "{rounded.xs} top only"
    plotHeight: "96px"
  button-primary:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.felt}"
    rounded: "{rounded.md}"
    padding: "6px 12px"
  button-quiet:
    backgroundColor: "{colors.surface-2}"
    textColor: "{colors.ink-secondary}"
    border: "1px {colors.hairline-soft}"
    rounded: "{rounded.md}"
    padding: "6px 12px"
  input:
    backgroundColor: "{colors.inlay}"
    textColor: "{colors.ink}"
    border: "1px {colors.hairline-soft}"
    borderInvalid: "1px {colors.sev-critical}"
    rounded: "{rounded.md}"
    padding: "8px 12px"
  chip:
    backgroundColor: "{colors.chip}"
    textColor: "{colors.ink-secondary}"
    rounded: "{rounded.sm}"
    padding: "2px 8px"
---

# Design System: deckex

## Overview

**Creative North Star: "A Mesa"**

deckex is a playmat under a low lamp. The table is dark and warm-green, like
felt; the card art is the light on it. Magic's own artwork is the most beautiful
thing this domain has, so the interface treats it as the primary visual mass and
never as decoration — a deck tile is an image with a caption, not a card with a
thumbnail. Everything the app adds around that art is quiet: felt, hairlines,
and monospaced numbers.

The voice is a measuring instrument, not a brochure. The app's whole job is to
say *your deck averages 3,2 and wants 36 lands and has twelve black sources
behind eight cards demanding double black* — so numbers are dense, aligned, and
always shown next to the baseline they are being compared against. It never
argues about which card is better; that is the AI's job, and the UI's restraint
is a statement of that boundary.

Two constraints shape everything else. First, **WUBRG is the semantic palette**:
every Magic player reads the five colours instantly, so the app spends colour on
mana and on nothing else. Second, **the app is always dark** — there is no light
theme, no toggle, and nothing left in the stack that could produce one. daisyUI
shipped with the generator carrying both a light and a dark theme; it is gone.

Confirmed visual rejections (posture, not taste): no light theme, no gradient
text, no decorative emoji, no scrim over card art, no colour used for anything
but mana or severity. Generator-default UI is a defect here even when no rule
below names it.

**Key Characteristics:**
- Art first, at the source aspect, never covered
- Felt-green surface ramp whose chroma rises with the light
- WUBRG for identity, a magenta/gold/jade ramp for severity, ink for everything else
- Monospaced numerals wherever a value is compared to a baseline

## Colors

Felt under a lamp, the five colours of mana, and one severity ramp deliberately
parked in the hues Magic's colour pie does not own.

### Surface — o Feltro

- **Feltro** (`felt` #0b120e): the mat, and the page ground.
- **Trilho** (`rail` #0f1813): navigation and fixed chrome.
- **Superfície** (`surface` #131d17) → **Superfície 2** (`surface-2` #192720):
  panels laid on the mat, and panels nested inside those.
- **Encaixe** (`inlay` #070c09): the one step *below* the mat — inputs, wells,
  empty art frames. Things recessed into the table, not resting on it.
- **Ficha** (`chip` #203028): the lightest step, for small enclosed labels.

The ramp holds hue 144–150 throughout while its chroma climbs with lightness
(5 → 16 of 255). That is the lamp doing its job: the shadowed mat is nearly
neutral, the lit surfaces are visibly green. A flat-chroma ramp was built,
rendered and rejected — at these luminances the green was imperceptible on every
step, which is a north star that never arrives.

### Ink

**Ink ramp** (#e8ece5 → #b6c0b6 → #949f96 → #848f85; #4a544c disabled): warm
off-white mixed from the felt, so text belongs to the table instead of sitting on
top of it. Every step down to `ink-faint` clears 4.5:1 on every ground text is
allowed to land on, `felt` (15.9 / 10.1 / 6.9 / 5.6) through `surface-2`
(13.0 / 8.3 / 5.7 / 4.6). `ink-disabled` is a marker tone and never carries text.
`chip` is the one ground not on that list: it carries `ink-secondary` (7.4:1)
and nothing dimmer.

**Hairlines** (ink at 7% / 10% / 15%) carry all separation. They are the ink at
low alpha, never pure white — a cold hairline on warm felt reads as a seam.

### Mana — the whole semantic palette

| Token | Hue | Meaning |
|---|---|---|
| `mana-w` #f8f0d8 | 45° | Parchment, not white. Pure white blows out against the table. |
| `mana-u` #4a90d9 | 211° | |
| `mana-b` #8b7d94 | 277° | **Lifted grey-violet, not black.** Pure black vanishes on the felt. |
| `mana-r` #e05c48 | 8° | |
| `mana-g` #4fa363 | 134° | |
| `mana-c` #9aa0aa | — | Colourless and generic. |

These are fixed by the spec and are not negotiable. A pip is the colour as a
disc with an `inlay` glyph on it, exactly how the printed symbol works; all six
clear 5:1 that way (B, the hardest, lands at 5.1).

### Severity — a separate ramp

| Token | Hue | Distance from the nearest mana hue |
|---|---|---|
| `sev-critical` #e2559f | 328° | 39° from R |
| `sev-warning` #e3a93c | 39° | 31° from R |
| `sev-healthy` #35bda6 | 170° | 36° from G, 41° from U |
| `sev-info` | — | resolves to `ink-muted`; a note is not an alarm |

**Critical is magenta on purpose.** It is the one hue Magic's colour pie has no
claim on — the running joke about pink mana is exactly the point — so an alarm
can never be misread as colour identity, and at 39° off R it never blurs into a
Mountain either.

**Warning is table gold**, which shares W's hue family. That is the ramp's one
genuine near-collision and it is resolved by lightness rather than hue: W is
always the palest thing on screen and gold never is. The alternative was pushing
gold toward orange, which would have walked it into R.

**Healthy is jade**, squeezed between G and U because those two leave nothing
wider. It is the tightest gap in the system, and it is survivable only because
healthy is the quietest tone in the app (below).

### Named Rules

**The Felt Rule.** Every surface, hairline and scrim in this app is mixed from
the felt hue. A neutral `#1a1a1a`, a white hairline, a black scrim: all drift.
Scrims are `--scrim*` (the felt at alpha) because black opens a hole in the
table. Chroma rises with lightness across the ramp; a lit surface that is less
green than the one below it is a mistake.

**The One-Legend Rule.** Every saturated hue in this app is either a mana colour
or a severity. Chrome — buttons, focus, selection, navigation, progress —
is built from the felt and ink ramps only. That is why the primary button is a
solid ink fill with felt-coloured text and the focus ring is ink at 55%: the
loudest the chrome is allowed to be is *bright*, never *coloured*. Reach for
`Format.color_token/1` or `Format.severity_token/1`; a component that needs a
literal hex is a hole in the token set, not a local fix.

**The Lifted-Black Rule.** Nothing in this app is `#000`. Black mana is
`#8b7d94`, the glyph inside a B pip is `--inlay`, and shadows are the only place
pure black appears at all — as alpha, under an object, where nothing has to be
read through it.

**The Quiet-Health Rule.** Only `:critical` and `:warning` may fill or tint.
`:healthy` colours its numeral and its dot and stops there; `:info` gets no hue
at all. A panel where every tile glows teaches nothing, and a deck that is fine
should look like a deck nobody needs to argue about. `stat/1` and `finding/1`
both implement this: the alarm tones get a tinted edge or a wash, the quiet ones
keep the plain hairline.

**The Pip-Not-Type Rule.** A mana colour is a disc, never a typeface. "12 fontes
de preto" is ink with a B pip beside it, not violet text. This is a design
preference that happens to also be the accessible answer: B measures 4.5:1 on
`surface` — right on the floor — while the glyph on its disc measures 5.1:1.

**The Physical-Target Rule.** A touch target is measured in px, from
`--size-touch`, and never from Tailwind's numeric scale. The root font-size here
is 13px, so every rem-based utility renders at 0.8125× its nominal value:
`min-h-11` reads as 44 and paints 35.75. Thirty-eight hit areas shipped that way
— written as 44, rendered as 36, and invisible to every test, because the class
was present and correctly spelled. A fingertip does not scale with the type.
`DeckexWeb.TouchTargetTest` fails if the rem scale comes back.

**The Low-Light Rule.** `color-scheme: dark` is declared on `html, body` so even
the native chrome — scrollbars, form controls, the caret — stays on the felt.
There is no light theme, no `prefers-color-scheme` branch, no toggle, and no
second design language to fall back to: daisyUI and its two themes were removed
rather than configured, because a light theme that exists is a light theme that
eventually renders.

## Typography

**Display / Body:** Archivo (with system-ui, sans-serif)
**Mono:** Azeret Mono (with ui-monospace, monospace)

**Character:** Archivo is a workhorse grotesque built for small sizes and dense
data — it holds a card name at 14px and a table header at 11px without getting
precious. Azeret Mono is squared and mechanical, closer to a measuring
instrument than to a code editor, and its figures are unmistakable at 12px in a
column. Together they read like a well-labelled panel next to a beautiful
picture, which is the whole product.

Both load from Google Fonts in `root.html.heex`. Self-hosting them into
`priv/static/fonts` is the follow-up when the CSP lands (see `.sobelow-conf`);
until then the app degrades to `system-ui` offline, which is ugly but legible.

### Hierarchy

- **Display** (700, 34px): reserved. Nothing uses it yet; it exists for the one
  identity moment a future screen may earn.
- **Title** (600, 26px): page titles.
- **Heading** (600, 20px): section and panel headers, `<.header>`.
- **Lead** (400, 16px): the one line at the top of an empty state.
- **Body** (400, 13px): the workhorse. Card names and emphasised rows step to
  14px (`body-lg`).
- **Caption** (400, 12px): type lines, finding details' supporting text, the
  baseline under a stat.
- **Label** (600, 11px, uppercase, 0.1–0.14em): section labels, table headers,
  field labels, severity words.
- **Micro** (400 mono, 10px): finding codes and the smallest annotations.
- **Numeral** (600 mono, 28px, leading 1): the stat tile's value. `numeral-sm`
  (500 mono, 15px) is its inline form.

### Named Rules

**The Mono-Measure Rule.** Azeret Mono carries two things: **a value you compare**
(the stat numeral, a curve bucket's count, the number inside a pip) and **a
machine identifier** (`mana.color_starved`, an oracle id, a pasted decklist).
Everything else is Archivo, including the numbers inside prose and captions —
"alvo 36" under a tile is a caption, not a readout, and setting the word "alvo"
in mono is monospace worn as a costume. Where mono runs, `tabular-nums` runs with
it; that is declared once in `app.css`, not per component.

**The Table-Distance Rule.** The interface band is 11–16px. This app is read at
table distance with the art doing the work, not at cockpit distance with the
type doing it — so it sits a step above a dense dashboard's 8–13px, and 13px is
the default body size rather than 12px. Sizes ≥20px are structural (headings,
titles) or the single stat numeral. Nothing else earns them.

## Layout

Single-column operational surfaces on the mat: `mx-auto max-w-[1440px] px-5 py-8`
(`sm:px-8`), set in `Layouts.app/1`. Spacing rides the stock Tailwind 4px grid —
`gap-1.5`–`gap-3` inside a row, 12–16px panel padding, `space-y-12` between the
sections of a long page, and always more space above a heading than below it.

Card grids are the app's signature layout: `grid-cols-2` on mobile stepping to
`md:grid-cols-3 xl:grid-cols-4`, every tile at the `art-crop` aspect so the
images line up as a single field of art rather than a ragged mosaic.

**The Art-Is-Not-A-Background Rule.** Nothing is ever laid over card art — no
scrim, no gradient, no name overlay, no corner badge. A card tile is the crop at
its source aspect with a hairline under it and a caption strip below, and every
piece of chrome the tile needs lives in that strip. The artwork is the reason
this product looks like anything; covering it to save 40px of height is the one
trade this design system does not make. (`--scrim-deep` exists, is strong enough
to carry ink over pure-white art, and is for modals — not for this.)

## Elevation & Depth

Flat plus hairline. Depth is the surface ramp — one tonal step per layer — and
1px ink hairlines at 7–15%. Panels printed on the mat never get a shadow.

**The Contact-Shadow Rule.** Only an object *on* the table casts one, and every
shadow is a pair, because on a near-black table a cast shadow alone is
invisible. The readable half is the lit top edge — the lamp catching the object's
near corner — and the drop shadow does the work at larger separations:

- **Contact** (`elevation.contact`): a card tile resting on the felt.
- **Lifted** (`elevation.lifted`): a card picked up — modals, popovers, flashes.

Anything that is neither of those gets a hairline. There are no glows.

Keyboard focus draws a 2px ring in `--focus-ring` at 2px offset, declared once in
`app.css` on `:focus-visible`. A mouse click stays silent; keyboard travel always
shows. Never write `focus:outline-none` without putting something visible in its
place — that class fires on mouse *and* keyboard and erases the only cue a
keyboard user has. The ring is neutral ink rather than an accent because of The
One-Legend Rule.

## Shapes

A tight 4–16px radius scale. `md` (8px) is the workhorse for buttons, inputs and
rows; `lg` (11px) for panels and finding rows; `xl` (16px) for large containers.
Pills (9999px) are reserved for mana pips, which are true circles.

**The Card-Corner Rule.** A printed Magic card is 63mm wide with a 3mm corner —
4.8% of its width. Anything standing in for a card uses `rounded-card` (13px),
which is that proportion at the ~270px tile the grids actually render. A card
tile with an 8px corner reads as a UI box; with a 24px corner it reads as a toy.
Non-card containers do not borrow this radius.

## Components

The product vocabulary lives in `DeckexWeb.UI`; the chrome Phoenix itself expects
(flash, button, input, header, table, list, icon) lives in
`DeckexWeb.CoreComponents`. Colour resolution for both lives in
`DeckexWeb.UI.Format` — that module is where "which token does colour B use" is
answered, once.

### Mana pip — `mana_pip/1`

A coloured disc with a drawn glyph, or a mono numeral for generic and variable
costs. Glyphs are authored SVG on a 16×16 grid at one weight, filled with
`currentcolor`: sun, drop, skull, flame, conifer, gem, snowflake, tap arrow,
Phyrexian mark. A hybrid is a 135° hard stop across its two tokens with no glyph
— the split disc already says which two colours it is, and two half-size glyphs
are illegible at 16px. A monocoloured hybrid (`{2/W}`) prints its generic half
over the split. The pip is `aria-hidden`; the accessible name belongs to the row
that wraps it.

### Colour identity — `color_identity/1`

Inline, it prints only the colours the deck has. With `full`, it keeps all five
WUBRG slots and drops the absent ones to a hairline ring — so in a grid, two
decks can be compared by scanning down a column instead of reading each row.

### Mana cost — `mana_cost/1`

Parses `"{3}{G}{U}{R}"` once and renders the pips, with a pt-BR `aria-label`
naming every symbol. A `nil` or empty cost renders **nothing**: a land has no
mana cost, and that is not a missing value.

### Stat — `stat/1`

Label (11px uppercase) over a 28px mono numeral in the tone's colour, over the
baseline it is measured against. Value strings arrive pre-formatted through
`Format.decimal/2` or `Format.percent/1`, so the pt-BR decimal comma is applied
in one place. Per The Quiet-Health Rule, only `:critical` and `:warning` tint the
tile's edge.

### Finding — `finding/1`

A severity dot, a pt-BR title, the explanation, the implicated card names as
chips, and an actions slot for "pedir diagnóstico à IA". Alarm severities sit on
a 10% wash of their own tone; quiet ones sit on `surface` with a hairline. The
severity reads from a dot and a word — never from a coloured left edge on the
container, which is the most recognisable tell of generated UI. Text on a wash
stays `--ink`, so the hue never has to carry contrast.

### Card link — `card_link/1`

A card's name, linking to its Scryfall page. The underline is permanent and
dotted, never a hover effect: a link discoverable only by hovering is invisible
to touch, and half of this app is read on a phone at a table. A name the
catalogue never resolved renders as plain text — an unresolved card has nowhere
honest to point. The lookup is one batched query per screen
(`Deckex.Cards.uris_for_names/1`), never one per name.

### Card thumb — `card_thumb/1`

The dense sibling of `card_tile/1`, for a row of several cards where the art is
what a player recognises before the name registers. Art and name are **one**
link target, which is both the natural gesture and what clears the touch
minimum — the name alone was an 11px sliver. Nothing is laid over the art, and
an optional note (a price) sits outside the link.

### Card tile — `card_tile/1`

The `art_crop` at its source aspect, a hairline, then a caption strip: name and
mana cost on the first line, type line and quantity on the second, an optional
footer slot. Without an art URL the frame falls back to an `inlay` well carrying
the card's name — a tile is never blank. Card names are data and are never
translated.

### Curve bar — `curve_bar/1`

One bucket of the mana-curve histogram: the count in mono above, the bar, the CMC
label below a hairline baseline. `max` is the tallest bucket in the whole
histogram and sets the shared scale — pass the same value to every bar or the
chart lies. An empty bucket keeps a 2px tick so a gap in the curve reads as a
gap. Bars rest in ink and take a `tone` only when a lens has a finding about that
bucket.

### Buttons

- **Primary:** solid `ink` fill, `felt` text, 13px semibold, `md` radius. One per
  view. It is bright rather than coloured, per The One-Legend Rule.
- **Quiet:** `surface-2` with a hairline and `ink-secondary` text; hover
  brightens the text to `ink` and the background holds still.
- **Disabled:** `opacity-40`, no colour change.

### Inputs

`inlay` background — recessed into the table, one step below the mat — with a
`hairline-soft` border, `md` radius, 13px text, `ink-faint` placeholder. Focus
moves the border to `ink-faint`. Invalid swaps it for `sev-critical`; the
resting and invalid border colours are applied as separate classes, because two
`border-*` colour utilities on one element are resolved by Tailwind's output
order rather than by the order they appear in the attribute. A pasted decklist
textarea runs in mono (it is machine input).

### Flash

Fixed top-right, `surface` on `lifted` elevation with a hairline in the semantic
accent — jade for `:info`, magenta for `:error`. Icon in the accent, title in
`ink`, message in `ink-secondary`. Copy is pt-BR, like every other user-facing
string.

## Do's and Don'ts

### Do:
- **Do** lead with `art_crop` wherever a card is shown and there is room for it.
- **Do** reach for `Format.color_token/1`, `Format.severity_token/1` and
  `Format.tone_token/1`; the palette's meaning lives there, not in per-screen hexes.
- **Do** set every compared value and machine identifier in Azeret Mono, and
  everything else in Archivo.
- **Do** separate with a hairline or one surface-ramp step.
- **Do** show a number next to the baseline it is measured against — a bare "34"
  teaches nothing, "34 / alvo 36" is the whole product.
- **Do** write microcopy in adult pt-BR, direct and calm, like
  "A importação por link do Moxfield e por lista colada chega junto com as telas."

### Don't:
- **Don't** introduce a light theme, a theme toggle, or daisyUI. The table is
  always under low light.
- **Don't** put anything over card art — no scrim, no overlay name, no badge.
- **Don't** spend a saturated hue on chrome. If it is not mana and not a
  severity, it is ink.
- **Don't** use `#000` anywhere, or a neutral grey where a felt-tinted one exists.
- **Don't** tint or fill for a healthy state; health is quiet by design.
- **Don't** set a mana colour as text — a colour is a disc.
- **Don't** put a coloured left edge on a card, row, or finding.
- **Don't** use a drop shadow for separation; the only shadows are Contact and
  Lifted, and both are shadow-plus-lit-edge pairs.
- **Don't** add a font family beyond Archivo and Azeret Mono, or a Unicode glyph
  where an authored SVG belongs.
