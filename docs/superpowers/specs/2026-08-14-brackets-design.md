# deckex — Commander Brackets — Design Spec

**Date:** 2026-08-14
**Status:** Proposed
**Extends:** `2026-08-13-deckex-design.md`

---

## 1. Why brackets, and why not a power level

The owner asked whether deckex should produce a power level like
[edhpowerlevel.com](https://edhpowerlevel.com/) and the
[Cardsrealm calculator](https://mtg.cardsrealm.com/en-us/tools/commander-power-level-calculator),
and whether it should map decks to the official Commander Brackets.

**Brackets: yes.** They are the Commander Format Panel's official system, and
crucially they are **rules**, not opinions: a bracket is defined by counting
Game Changers, and by the presence or absence of mass land denial, chained
extra turns and early two-card combos. Counting is exactly what this engine
does. The bracket is also the thing you actually say out loud at a table —
the poster calls it "a communication tool to guide pregame conversations",
which is the same job deckex has.

**A 1–10 power level: no**, and this is a deliberate refusal. The founding
law of this project is that we do not build an algorithm that ranks every
Magic card. A 1–10 score is precisely that algorithm wearing a decimal point.
Look at what the two reference tools actually do:

- **edhpowerlevel.com** derives its "impact" score from *card demand and
  price data*. That is a market signal standing in for a gameplay one: it
  makes reserved-list and recently-spiked cards look powerful and makes a
  perfectly tuned budget deck look weak.
- **Cardsrealm** asks *you* to count ramp, draw, tutors, stax, removal and
  counterspells by hand, then scores the counts.

deckex already counts nine of Cardsrealm's twelve inputs automatically and
more accurately — from oracle text, with provenance on every classification.
The gap was never the arithmetic; it was that we never mapped the arithmetic
onto the vocabulary players use. Brackets is that vocabulary.

### What we are NOT building

- **No 1–10 score.** See above. If it is ever wanted, it belongs to the AI as
  an opinion with reasoning, never to the engine as a number.
- **No combo database.** Detecting "Thassa's Oracle + Demonic Consultation"
  needs card-pool knowledge, which is the model's job, not the engine's.

---

## 2. The floor, and the open questions

The engine states a **floor**: the lowest bracket whose deckbuilding rules
this deck provably satisfies. It never states the bracket outright, because
two of the five criteria cannot be measured from a decklist.

**Provable from card data:**

| Signal | Source | Effect on the floor |
|---|---|---|
| Game Changers count | Scryfall's `game_changer` field, on every card object | 0 → floor 1; 1–3 → floor 3; 4+ → floor 4 |
| Mass land denial | oracle-text rule | present → floor 4 |
| Chained extra turns | oracle-text rule | present → floor 4 |

**Not provable — the model's job:**

- Two-card combos that win on the spot, and whether they can assemble early.
- Whether the deck actually closes before the bracket's turn expectation
  (9 / 8 / 6 / 4 / any).

So the deck page shows: *"Piso: Bracket 3 — 2 Game Changers (Rhystic Study,
Smothering Tithe). Para confirmar 3 e não 4, falta saber: tem combo de duas
cartas que ganha antes do turno 6?"* — and a button that asks exactly that.

The Game Changers list is fetched, never typed. It changes a few times a
year, and a list hardcoded here would be wrong within months. Scryfall
carries `game_changer` on every card, so it arrives through the fetch that
already happens — plus `Cards.refresh_game_changers/0` to backfill cards
catalogued before this feature existed.

---

## 3. Components

- `Deckex.Analysis.Bracket` (pure): `floor(snapshot)` →
  `%Bracket{floor: 1..4, game_changers: [CardEntry.t()], mass_land_denial:
  [CardEntry.t()], extra_turns: [CardEntry.t()], open_questions: [String.t()]}`.
  Pure like every lens; the snapshot already carries what it needs.
- `Deckex.Cards.Roles.Bracket` — two new oracle-text rules,
  `mass_land_denial` and `extra_turn`, added to the existing `RoleMatch`
  vocabulary so they carry evidence like every other role.
- `cards.game_changer` boolean, from `ScryfallMapper`.
- A `:bracket` consult lens: the briefing states the measured floor and asks
  the model to confirm the bracket, name any two-card combo it sees, and say
  what single change would move the deck a bracket in either direction.
- UI: a bracket badge on the deck page header and on each Mesa tile — the
  number you say at the table, visible from across the room.

## 4. Testing

Pure rules get pure tests. The floor gets a table-driven test per rule. The
real-deck regression asserts the Iroh deck's floor and lists its Game
Changers by name. No test touches the network; the `game_changer` flag comes
from the committed fixtures.

## 5. Decision log

| Decision | Rationale |
|---|---|
| Brackets, not a 1–10 score | Brackets are rules and can be counted; a power level is a card-ranking algorithm, which this project exists not to build. |
| Floor, not a verdict | Two of the five criteria need card-pool knowledge. Stating a bracket we cannot prove would be the same overreach as inventing a price. |
| Game Changers from Scryfall's field | The list is official and changes; it arrives free with the fetch we already do. A hardcoded list is wrong within months. |
| Combos left to the model | Same law as the rest of the engine: we measure shape, the model knows the card pool. |
