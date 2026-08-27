# A Bancada — the Otimizador mode where the owner executes

**Status:** approved 2026-08-27. Implements on top of
[the Otimizador](2026-08-14-otimizador-design.md) and
[the Reimaginador](2026-08-14-reimaginador-design.md), which this document
extends rather than replaces. Read those first: sandbox, contract, audit,
timeline, versions, shopping list and fork are reused verbatim.

---

## 1. What we are building

Every mode the Otimizador has today ends with **the model choosing cards and
the engine refusing the illegal ones**. The owner watches. He can pause, redo a
stage with another model, lock a card so the next stage cannot touch it — but
the act of choosing is not his, and the two failure modes he actually fears
both live inside it:

- a good card cut for a misreading (Jaheira, cut for "só dá mana a tokens de
  criatura", which is not what she says);
- a mediocre card added because it was the first thing that fit the hole.

**A Bancada is the mode where he chooses.** The pipeline still reads the deck,
still names what is wrong with it, still proposes — but it proposes *vacancies*
with candidates, and a human fills them. The engine keeps every guard it has;
it simply stops being the one who picks.

The bet is not that he is a better deckbuilder than the model. It is that
**the model is better at finding candidates and he is better at judging them**,
because he is the only party in this system who has played the deck.

### Why a mode and not a new feature

The same three reasons the Reimaginador is a mode. The sandbox, the audit, the
budget policy, the keep-list, the bracket ceiling, the flip-flop guard, the
version write-back and the shopping list all apply unchanged. What is new is a
screen and one lens.

### What we are explicitly NOT building (v1)

- **Free card search.** The board offers what the cardápio proposed and nothing
  else. "Add any card you can think of" is deck editing, and the deck page
  already does that.
- **Reordering or re-grouping the vacancies by hand.** The grouping is the
  model's reasoning, and rearranging it would make it his.
- **Multiple candidates chosen per vacancy.** One vacancy, one card, or none.
  Two cards for one hole is two holes.
- **A second cardápio inside one run.** If the menu is bad, the run is cheap to
  discard; re-asking is a new run, priced honestly as one.

---

## 2. The mode and the recipe

`optimizations.mode` gains `:curadoria`. The recipe is four stages:

| # | kind | lens | label | who acts |
|---|------|------|-------|----------|
| 1 | `:plano` | `:plano` | Plano | model |
| 2 | `:cardapio` | `:cardapio` | Cardápio | model |
| 3 | — | — | *(the board)* | **owner** |
| 4 | `:critico` | `:critico` | Crítico | model |
| 5 | — | — | *(the board, again)* | **owner** |

Three consults — the same cost as a `:refine` round. Stage 3 and stage 5 are
not stages: they are the run sitting in `:awaiting_choice` while the owner
works, which is a status the run already has.

`:plano` is reused **verbatim**. It reads everything, proposes nothing, writes
the round's plan and the deck's dossier, and its plan travels into the cardápio
verbatim — the law that a summarised plan is a reinterpreted plan holds here
exactly as it does in `:execucao`.

---

## 3. The cardápio

### 3.1 What a vacancy is

A vacancy is **a reason with candidates**, and the reason is load-bearing: it
is what the board groups by, and it is what makes a "no" cheap. Refusing
`Arcane Signet` is a judgement about a card; refusing *"sua curva quer mais
aceleração de 2 mana"* is a judgement about the deck, and the owner is the one
qualified to make it.

```json
{
  "grupo": "Ramp",
  "vaga": "Você acelera com 3 peças de 2 mana e a curva pede 5 — a mão que não abre com uma delas joga um turno atrás.",
  "candidatos": [
    {"carta": "Arcane Signet", "porque": "..."},
    {"carta": "Fellwar Stone", "porque": "..."},
    {"carta": "Talisman of Resilience", "porque": "..."}
  ]
}
```

Two to three candidates. **One is not a vacancy, it is a suggestion**, and the
schema enforces `minItems: 2`. The engine may still show a one-candidate
vacancy — the critic's corrections are exactly that — but the model may not
produce one.

### 3.2 Counts

The launch modal carries two numbers, defaulting to **10 cortes** and
**20 entradas**. The model is asked for `max(cortes, entradas)` cut vacancies
and `entradas` add vacancies; the cut vacancies past `cortes` are the
**reserva**, ordered last by the model's own conviction.

The reserve exists because of arithmetic the owner will hit on his first run: a
100-card deck that takes fifteen adds needs fifteen cuts, and a board that
offered ten would have to buy another consult to finish. It is collapsed until
the count needs it, and it opens by itself when it does.

### 3.3 The schema (`Deckex.Consults.Schemas.for_lens(:cardapio)`)

```
leitura   string, required — the model's own reading, as every lens has
cortes    array of vacancy, required
adicoes   array of vacancy, required
```

with `vacancy = {grupo, vaga, candidatos[{carta, porque}]}`, all required,
`candidatos` `minItems: 2`, `maxItems: 3`.

No price field anywhere, in either direction. The law that the model never
states a price is not relaxed because the shape changed.

### 3.4 The briefing (`task_block(:cardapio, opts)`)

Says, in pt-BR:

- the plan from stage 1, verbatim;
- how many vacancies of each kind, and that the reserve is ordered by
  conviction;
- that a vacancy names a **need**, not a card — the same need must be
  answerable by any of its candidates;
- that the candidates for one vacancy must be genuinely different choices, not
  three printings of one idea;
- that the deck is at N cards and every add costs a cut, so the owner will not
  take all of them and the model should propose the twenty best rather than
  twenty that must all be taken together;
- that cut vacancies name cards **in the list**, and add vacancies name cards
  **outside** it.

`rules_block/3` is untouched: every universal rule reaches this lens by
construction, which is the law that exists because twice a universal rule was
written into one branch.

---

## 4. The board

Route `/otimizacoes/:id/bancada`, its own LiveView, full-bleed. The run page
keeps the timeline and grows a "Sua vez" call-to-action while the run waits.

### 4.1 Two phases, one screen

**Triagem.** One vacancy at a time. The group and the vacancy's sentence are
the headline; the candidates are card art, side by side, biggest thing on the
screen. `1`/`2`/`3` picks, `0` or `Enter` skips, `←` goes back, `→` re-skips
forward. Every decision advances immediately — there is no confirm button in
triage, because a decision you can change in phase 2 does not need one.

**O quadro.** Every vacancy, decided or not, grouped by `grupo`, in columns.
Any decision can be flipped here. This is where the run is committed.

The two phases are the same LiveView and the same state; the toggle is free and
lives in the header. Triage is where the fun is; the board is where the
thinking is; forcing either one on him would be wrong.

### 4.2 The rail — the scoreboard

Fixed right rail, always visible, recomputed on **every** selection:

- **Cartas 103/100**, alarm-toned when off, the only hard gate on committing.
- **Críticos 2 → 0**, from `Analysis.report` over the simulated snapshot.
- **Entradas R$ X**, against the budget policy — with the exception counters
  the policy actually uses (`n` acima de R$400 de 10, `n` acima de R$600 de 2).
- **A curva**, redrawn.

This is the gamification, and it is deliberately not a badge: it is the deck's
own numbers moving because of something he just did. The machinery is
`Deckex.Analysis` and `Deckex.Consults.Audit`, both already pure, both already
built, run **live** for the first time instead of only at the end of a stage.

### 4.3 The verdict chip

Each selection carries the engine's verdict on that card, inline, at selection
time: `resolve: só 3 remoções pontuais` · `gasta 1 das 2 exceções` ·
`não cabe no bracket 3` · `Lucas travou essa carta`.

A **problem** disables the candidate and says why. A **note** is shown and
changes nothing — the distinction `Audit` already draws, and the one that once
cost every legal Game Changer add by masquerading as a problem.

### 4.4 The gate

Commit is refused off 100 and refused with zero selections. Nothing else is
refused: a board that took two adds and two cuts is a legitimate, small round.

---

## 5. Persistence

`optimization_steps` gains **`selections :map`** (JSONB, string-keyed like
every other payload here):

```json
{"add:3": "Arcane Signet", "cut:0": "Temple of Malady", "add:7": null}
```

The key is `"<action>:<index>"` against the vacancy list in the step's consult
response, which is frozen the moment the consult lands. `null` is an explicit
skip; an absent key is undecided, and the two are different on the board.

Written on every click — one small update, no consult, no network. He can close
the tab mid-triage and come back to exactly where he was.

**On commit** the selections are turned into `Deckex.Consults.Suggestion`
structs and handed to the same `judge`/`split` path every stage uses. `applied`
and `rejected` are written to the step exactly as if a model had produced them,
carrying the vacancy's own sentence as the reason. From that point the run is
indistinguishable from any other: the sandbox advances, the critic reads it,
the version records why each card moved, the shopping list is built.

`selections` is what the owner did; `applied` is what the engine let through.
Keeping both is the same reason `rejected` exists — the record of a refusal is
the audit doing its job, and it must survive.

---

## 6. The critic returns to the board

In `:curadoria` the critic's answer is **not applied**. It is converted to
one-candidate vacancies, the run returns to `:awaiting_choice`, and the owner
decides each one on the same board.

This is the mode's whole premise held to the end. A critic that silently
corrected his curation would make the last word the model's again, and the
owner is the party who has played this deck — the same law that gives the
review stage's note precedence over the model's reading.

If the critic proposes nothing, the run finishes without a second gate.

---

## 7. What the engine still enforces

Unchanged, all of it, and it runs against the owner's choices exactly as it
runs against a model's: colour identity, singleton, Commander legality, cut
targets present in the list, price ceilings, budget policy and its exception
counters, keep-list and live locks, bracket ceiling, salt contract, and the
100-card balance.

Two guards are deliberately **relaxed** for this mode:

- **The flip-flop guard does not bind the owner.** It exists to stop two models
  arguing in circles; a person with new information is not churn, which is the
  law the review stage already states.
- **Nothing refuses a "no".** Skipping every vacancy is a legitimate outcome
  and ends the run with the deck unchanged, said plainly.

---

## 8. Testing

- `Schemas` — the cardápio shape, `minItems: 2`, no price field.
- `Briefing` — the lens gets the universal rules (`BriefingTest` walks
  `Consult.lenses()` and this one is added to it), the plan verbatim, and the
  counts.
- `Optimizations` — recipe for `:curadoria`; `select/3` writes one selection;
  commit off 100 is refused; commit turns selections into audited
  `applied`/`rejected`; the critic in this mode gates instead of applying.
- `Audit` — a selection carrying a problem is rejected with the same message a
  model's would be; a note does not reject.
- LiveView — triage advances on pick, the rail recomputes, a locked card's
  candidate is disabled, commit is refused off 100, and the state survives a
  remount.

A test deck is 100 cards, per the standing law.
