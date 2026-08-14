# deckex — Meta-prompt: strategic dossier + self-critique — Design Spec

**Date:** 2026-08-14
**Status:** Shipped and validated (see the Validation section)
**Extends:** `2026-08-13-deckex-design.md` (the consult pipeline, §§ import/analysis/consults)

---

## 1. What we are building, and the evidence for it

The consult briefing today is exact about numbers and silent about strategy.
It is a fixed template: measured facts + a per-lens task block. The 2026-08-13
model comparison (spec §14) showed precisely where that costs us: what
separated `opus` from `fable` and `sonnet` was not phrasing — it was **deck
comprehension**. Opus read Iroh's text, understood that the expensive Lessons
are the engine because the commander flashbacks them, and reasoned from there.
The briefing never told any model that, because the engine measures structure
and does not understand strategy — by design.

This feature closes that gap with two pieces:

1. **A strategic dossier per deck.** A one-time "scout" consult reads the deck
   and writes the part of the prompt no template can write: what the deck is
   trying to do, the synergies that give it identity, how it actually wins,
   and the weaknesses the numbers cannot see. The dossier is stored on the
   deck, shown on the deck page, editable by the owner, and injected into
   **every** subsequent briefing.

2. **Self-critique in every answer.** Every lens's response schema gains a
   required `leitura` field the model must write *before* proposing cuts and
   adds: its own reading of the deck, confronted with the dossier. The
   instruction deliberately includes *"if you disagree with the dossier, say
   where and why"* — which turns the field into a stale-dossier detector. If
   three consults in a row dispute the same point, the dossier is wrong and
   the owner sees it.

The expected gain is exactly what the comparison measured: `fable` and
`sonnet` receiving on a plate what only `opus` deduced on its own.

### What we are explicitly NOT building

- **No automatic scout runs.** A consult costs money and minutes; spending is
  always the owner's click. Deck edits mark the dossier stale — they never
  re-run it.
- **No deck versioning.** Staleness is a boolean flag flipped by edits, not a
  version history. If versioning ever matters, it is its own design.
- **No second pipeline.** The scout is a consult. It reuses the existing
  machinery end to end: frozen briefing, worker, status states, history,
  PubSub. The per-consult "prompt lapidary" variant (two model calls per
  consult) was considered and rejected: it pays per consult instead of per
  deck, adds latency to an already 3–4 minute call, and puts a paraphrasing
  model between exact measurements and the analyst — the price lesson again.

---

## 2. Data model

Four new columns on `decks` — one dossier per deck; a separate table would be
ceremony:

| Column | Type | Meaning |
|---|---|---|
| `dossier` | `:map`, null | The four prose fields below, or NULL when never generated |
| `dossier_source` | `Ecto.Enum` `[:scout, :manual]`, null | Who wrote the current text |
| `dossier_stale` | `:boolean`, default `false` | Deck changed since the dossier was written |
| `dossier_updated_at` | `:utc_datetime`, null | When it last changed |

The `dossier` map holds four **prose** fields (strings, pt-BR, card names
untranslated — the language rule applies):

- `"plano"` — what the deck wants to do and how the commander enables it
- `"sinergias"` — the interactions that give the deck its identity
- `"linhas_de_vitoria"` — how the deck actually closes a game
- `"fraquezas"` — what the numbers do **not** show (e.g. total graveyard
  dependence)

Prose per field, not nested lists: structure keeps the scout complete, prose
keeps the owner's edit path trivial (four textareas) and the briefing
injection verbatim.

**Provenance, as everywhere in the app:** a manual edit sets
`dossier_source: :manual`. Re-running the scout over a manual dossier asks for
confirmation in the UI (`data-confirm`) before replacing it — the same law as
`:manual` card roles, softened from "never overwritten" to "never overwritten
silently", because here replacement is an explicit owner action on one screen.

---

## 3. The scout

A new lens `:scout` in `Deckex.Consults.Consult` — `Consults.request(deck,
:scout)` and nothing else new in the request path.

- **Briefing:** the same body every other lens gets (deck block, measured
  numbers, findings), with a scout task block and — obviously — no dossier
  injection. The task block instructs: read the deck; write the four fields;
  `fraquezas` is only for what the measurements above do not show; **do not
  propose any change** — a scout that suggests cards has become a consultant,
  and the consultant already exists.
- **Schema:** `Schemas.for_lens(:scout)` returns the dossier schema — the four
  fields, all required. This is the day the `for_lens/1` indirection was built
  for; until now every lens shared one schema.
- **Model:** `Settings.model()` (today `opus`), WebSearch allowed. One write
  per deck edit-cycle — quality pays more than economy here.
- **On success:** `Consults.run/1`'s success path additionally writes the
  answer to the deck via `Decks.put_dossier/2` (sets `dossier`,
  `dossier_source: :scout`, `dossier_stale: false`, `dossier_updated_at`).
  The suggestion-cataloguing step is a no-op for `:scout` responses (no
  `cuts`/`adds` keys), so no special case is needed there.

---

## 4. Briefing injection and degradation

`Briefing.build/4` gains an optional `dossier` opt — the builder stays pure;
the caller (`Consults.request/3`) loads the deck's dossier and passes it in.

With a dossier, the briefing gains a labeled block between the measurements
and the task:

```
Leitura estratégica (dossiê do deck):
- Plano: ...
- Sinergias: ...
- Linhas de vitória: ...
- Fraquezas que os números não veem: ...
```

Plus one rule line: the dossier is the owner's current understanding — trust
it as context, and contradict it explicitly in `leitura` when the list says
otherwise.

**Without a dossier, everything keeps working.** The block is simply absent;
consults run exactly as today. The UI nudges toward generating one first, but
never gates.

A stale dossier is still injected — with one extra line in the block saying
the deck has changed since it was written, so the model weighs it accordingly.

---

## 5. Self-critique: the `leitura` field

Every lens **except `:scout`** gains a required `"leitura"` property. JSON
schema properties carry no order, so "first" is enforced where it can be: the
property is written first in the schema source, and the task block instructs
the model to write its reading before choosing any cut. Its description:

> 2–4 frases: sua leitura do plano deste deck, confrontada com o dossiê
> acima (se houver). Se você discordar do dossiê, diga onde e por quê.

Displayed in the consult card on the deck page, above the diagnosis — the
owner compares the model's reading with the scout's at a glance.

Existing stored consults have no `leitura`; rendering treats it as optional.
The schema requirement applies to new answers only.

---

## 6. Staleness

`dossier_stale` flips to `true` in exactly three places, all in `Deckex.Decks`
mutations: `add_card/3`, `remove_card/2`, and a re-import that overwrites the
list. Nothing else touches it. The deck page shows a "dossiê desatualizado"
badge with the re-run button next to it.

**Known race, accepted in v1:** editing the deck while a scout is running
means the finished dossier clears the flag even though it missed that edit.
Distinguishing "stale since before the scout was requested" from "stale since
after" needs a timestamp we deliberately do not add yet — the window is
minutes, the very next edit re-flags, and the fix is cheap the day it actually
bites someone.

---

## 7. UI

On the deck page, a dossier card in the wide column (above the consults
section):

- **No dossier:** empty state — one sentence on what it is, one button
  ("Gerar dossiê"). The consult form still works without it.
- **Present:** the four fields as labeled prose, `dossier_updated_at`, the
  source ("escrito pelo scout" / "editado por você"), an edit affordance
  (four textareas, save button → `:manual`), and a re-run button
  (`data-confirm` when source is `:manual`).
- **Stale:** the badge, same card.
- **Running:** the scout consult appears in the existing consults list with
  its status, like any consult; the dossier card shows "scout lendo o deck…"
  while one is pending/running.

All user-facing text pt-BR; card names untranslated.

---

## 8. Errors

Nothing new. A failed scout is a failed consult — recorded on the consult row,
surfaced in the consults list, dossier unchanged. `Decks.put_dossier/2`
returns `{:ok, deck}` / `{:error, %Deckex.Error{}}` like every mutation.

---

## 9. Testing

- **Briefing (pure):** block present with dossier, absent without, stale line
  when stale; scout task block forbids suggestions; `leitura` instruction
  references the dossier only when one was injected.
- **Schemas:** `:scout` returns the four required fields; every other lens
  requires `leitura` first.
- **Consults:** `run/1` on a `:scout` success writes the dossier and flips
  staleness; on failure leaves the deck untouched; non-scout success paths
  unchanged (regression).
- **Decks:** `put_dossier/2`; the three staleness triggers, each proven to
  flip the flag; manual edit sets `:manual`.
- **LiveView:** generate button requests a `:scout` consult; badge renders
  when stale; manual edit round-trips; re-run over `:manual` carries the
  confirm attribute; consult card renders `leitura` when present and old
  consults without it still render.
- **Real-deck regression:** one briefing built for the Iroh deck with a
  dossier injected, asserting the block lands between measurements and task.

All through the existing Mox boundaries; no test touches the network.

---

## 10. Decision log

| Decision | Rationale |
|---|---|
| Dossier per deck, not prompt-lapidary per consult | Pays once per deck instead of per consult; no added latency on a 3–4 min call; no paraphrasing model between exact measurements and the analyst. |
| Four prose fields, not free text or nested lists | Structure keeps the scout complete; prose keeps owner edits trivial and injection verbatim. |
| Scout is a lens, not a second pipeline | Frozen briefing, worker, states, history and PubSub for free; `succeed` gains one extra write. |
| `leitura` required in every answer | Forces the model to reason before prescribing, and doubles as a stale-dossier detector via the mandated-disagreement instruction. |
| Staleness is a flag, not a version | Edits are cheap to detect; history is a different feature with a different design. |
| Manual dossier replaced only behind a confirm | Same provenance ethos as `:manual` roles, adapted: never silently. |

## Validation — 2026-08-14, same day

The scout ran on the real Iroh deck (opus, 214s) and wrote a dossier that read
cards no earlier analysis had touched (Stormsplitter, Vivi Ornitier, White
Lotus Hideout) and named the weakness the numbers cannot see: the deck's good
identity costs {3}{G}{U}{R}, and Iroh's flashback does nothing on defence.

Then the thesis test: the same `:full` question to **sonnet** — the model that,
pre-dossier, cut a Lesson without knowing Lessons are the engine — now with
the dossier injected. Result (180s): no Lesson cut; the `leitura` engaged the
dossier exactly as designed, agreeing with its core and **disagreeing on two
specific points with new reasoning** (the deck's extra mana is all R/U and
masks the GG hunger; the only board wipe kills its own token army). The
cheaper model now sees what only opus saw, and the mandated disagreement
produced insight neither the dossier nor the earlier opus answer contained.
