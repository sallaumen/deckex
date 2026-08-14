# O Reimaginador — a second mode for the Otimizador

**Status:** approved 2026-08-14. Implements on top of
[the Otimizador](2026-08-13-deckex-design.md) and its spec,
[2026-08-14-otimizador-design.md](2026-08-14-otimizador-design.md), which this
document extends rather than replaces. Read that one first: every mechanism it
describes — sandbox, contract, audit, timeline, fork — is reused verbatim here.

---

## 1. What we are building

The Otimizador refines. Every stage is anchored to the deck's stated purpose,
the `:alinhamento` stage exists specifically to catch drift from it, and the
default contract caps the bracket at the deck's *current* floor. That is the
right default and it is deliberately conservative: it makes the deck a better
version of what it already is.

The Reimaginador is the other half. It asks a different question — *what would
make this deck genuinely stronger, even if that means a different deck?* — and
it is allowed to answer with big changes: a new axis of victory, a different
posture at the table, even a different commander in the same colours.

It is a **mode of the same feature**, not a new one. An optimization is born
`:refine` (today's behaviour, the default) or `:reimagine`. Same table, same
pages, same history, same audit. The differences are three: the recipe, what
the contract carries, and what the engine enforces.

### Why a mode and not a separate feature

Three reasons, in order of weight:

1. **Everything expensive is already built and proven.** The sandbox that never
   touches the real deck, the audit that refuses with a reason, the live
   timeline, per-stage feedback, fork-to-deck, pause/resume, the convergence
   rule — all of it applies unchanged. A parallel feature would duplicate every
   one of them and drift from them within a month.
2. **The owner compares runs.** A refine run and a reimagine run over the same
   deck belong in the same history, side by side, with a badge saying which is
   which. Two histories in two places would make the comparison manual.
3. **The recipe is already data.** `Optimizations.start/3` takes a recipe
   override, and stages are rows. A second recipe is the smallest possible
   change that produces the new behaviour.

### What we are explicitly NOT building (v1)

- **Commander changes that alter colour identity.** See §5 — this is a hard
  correctness boundary, not a scope compromise.
- **Running the three visions to completion in parallel.** The owner picks one.
  Three full pipelines is 3× the cost for a comparison the fork feature already
  approximates (fork the run at any stage, run again from there).
- **A collection model.** The app does not know which cards the owner owns, so
  it cannot prefer them. Price ceilings are the only cost control.
- **Deckbuilding from nothing.** The deck is the starting point, always.

---

## 2. The mode

A new column, `optimizations.mode`, `Ecto.Enum` of `[:refine, :reimagine]`,
default `:refine`. Existing rows are `:refine` and read exactly as they do
today.

Everything keyed off the mode is derived from it at the call site — no
behaviour is stored twice:

| | `:refine` | `:reimagine` |
|---|---|---|
| recipe | today's 8 (or 9 with scout) | §6's 11 |
| `bracket_max` default | the deck's measured floor | the deck's measured floor |
| dossier in the briefing | the target to stay faithful to | context: *what the deck was* |
| final validation | fidelity to the dossier | fidelity to **the chosen vision** |
| salt controls | not shown | shown, enforced |
| commander | frozen | may change under §5's rules |

`bracket_max` defaulting to the measured floor in **both** modes is deliberate:
"reimagine" is permission to change the deck's plan, not permission to change
the table it belongs at. The owner raises it in the launcher if they want to
climb, in either mode.

---

## 3. The Visions and the choice

### The stage

A new lens, `:visao`, and a response schema unlike every other one: it proposes
no cuts and no adds. It returns **three directions**, each with:

- `nome` — a short name the owner will see on a button ("Controle de Temur")
- `tese` — why this makes the deck stronger, in one paragraph
- `custo` — what the deck **loses** by going this way, stated honestly
- `eixo` — the axis it moves: `consistencia | velocidade | resiliencia | eixo_de_vitoria`
- `cartas_chave` — the cards that define the direction (names only)
- `comandante` — optional, a proposed commander (see §5)

The briefing demands that the three differ **in axis**, not merely in card
choices. Three flavours of the same plan is the failure mode this rule exists to
prevent, and the engine cannot check it — so the briefing states it as a
requirement and the owner is the judge.

**The model names cards; the app prices them.** `cartas_chave` goes through the
same catalogue resolution every other answer does (`Consults.refresh_catalogue/1`
must learn to collect names from a vision response, or the prices will be
missing), and the vision card in the UI shows the total in R$ computed from the
catalogue. The price law is untouched: the model never states a price.

### The choice

When the vision stage lands, the run does not advance. It transitions to a new
status, `:awaiting_choice`.

This is a distinct status and not a reuse of `:paused` because the two mean
different things to the person reading the screen: `paused` means *you stopped
it*, `awaiting_choice` means *it is waiting for you*. Deriving the second from
"mode is reimagine and no vision is chosen and the vision step is done" would
work and would be exactly the kind of implicit state that becomes a bug.

Consequences, all small and all required:

- `running_for_deck/1` counts `:awaiting_choice` as live — one run per deck
  still holds, and a run waiting on the owner must not be lapped by a new one.
- The deck page's button reads "Otimização esperando você →".
- `resume/1` from `:awaiting_choice` requires `contract["visao"]` to be set;
  without it the transition is refused with a reason rather than silently
  running the next stage against no direction.

The timeline renders the three visions as cards — name, thesis, cost, key cards
with the computed R$ — each with a **"Seguir esta"** button. Choosing writes the
vision into the contract (frozen from then on, like every other contract field)
and resumes the run.

A fourth button, **"Pedir outras três"**, spends one more consult for a fresh
set. Its label says so. The rejected set stays on the timeline: what the owner
turned down is part of the record, and the next vision stage is told which
directions were already declined so it does not re-propose them.

Mechanically the re-ask **re-runs the same step** — a new consult at the same
position, with `step.consult_id` repointed to it. No step is inserted, so
positions stay stable and the unique index on `[optimization_id, position]`
holds. Earlier vision consults remain attached to the run by `optimization_id`
and are rendered in order above the current set; a query for the run's
`:visao` consults is what the timeline reads, not `step.consult` alone.

**A vision's commander is validated when the vision is shown, not when it is
chosen.** The owner must not pick a direction and only then learn its commander
was refused. A vision whose commander fails §5's rules is still selectable — the
refusal is printed on its card and the commander simply does not change.

Nothing expires. A run in `:awaiting_choice` waits indefinitely, spends nothing,
and can be cancelled from the same page.

---

## 4. Salt as a rule of the engine

Six tactics, each set to `evitar | tanto_faz | quero`:

| tactic (UI, pt-BR) | role |
|---|---|
| Counters | `:counter` |
| Stax / prisão | `:stax` |
| Destruição de terreno | `:mass_land_denial` |
| Turnos extras | `:extra_turn` |
| Ódio a cemitério | `:graveyard_hate` |
| Mill | `:mill` — **new**, see below |

Stored as `contract["salt"]`, a string-keyed map (`%{"counter" => "evitar"}`),
absent keys meaning `tanto_faz`.

**`evitar` is enforced, not requested.** A new audit guard, in the same shape as
the price ceiling and the bracket guard: an add whose classified roles include
an avoided tactic is rejected, with the reason in pt-BR on the timeline —
*"você marcou evitar counters nesta rodada"*. This works because the audit
already receives `roles_for_adds`; the guard is a set intersection.

**`quero` is an invitation, not a command.** It goes into the briefing. No
engine can force a model to have an idea, and pretending otherwise would be the
same overreach as inventing a price.

Two presets fill all six at once: **mesa tranquila** (avoid stax, land denial,
extra turns and mill; the rest indifferent) and **sem freio** (nothing avoided).

### The launch-time contradiction check

`mass_land_denial` and `extra_turn` push the measured bracket floor to 4. Asking
for either while capping the contract at bracket 3 is a contract that contradicts
itself, and every such add would be rejected mid-run — after the consult is paid
for. The launcher refuses the contract at submit time with the reason, before
anything spends.

### The `:mill` role

`:mill` joins `RoleMatch`'s vocabulary with a rule in the existing style
(oracle text, in `Deckex.Cards.Roles`). It is the one tactic the owner named
that the engine could not yet see. Being a role, it also becomes visible
everywhere roles already are — the deck page, the audit, the briefing — which is
the argument for adding it as a role rather than as a special case of salt.

Mill is **not** a bracket criterion. Adding the role changes no bracket floor.

**Adding a role means reclassifying the catalogue.** Every card already stored
was classified before `:mill` existed, so without a pass over them the guard
would silently miss the very cards the owner asked to avoid — a rule that looks
enforced and is not. The migration is a one-off reclassification of the existing
catalogue, ordered by `oracle_id` per the deadlock law, run once as part of
shipping this. Cards arriving afterwards are classified on the way in, as they
already are.

---

## 5. The commander swap

A vision may propose a different commander. The engine validates three things
before the swap is allowed, and refuses with a reason if any fails:

1. **Legal in Commander** — `commander_legal` on the catalogue row.
2. **Can actually be a commander** — a legendary creature, or a card whose
   oracle text carries the "can be your commander" clause.
3. **Exactly today's colour identity** — not a subset, not a superset.

The third is the load-bearing one. If the deck is Temur and the new commander
were Izzet, every green card in the list would become illegal at once — a
cascade the pipeline would have to resolve by cutting cards for a reason that
has nothing to do with the deck being better. Requiring the identity to match
exactly means **no existing card ever becomes illegal**, and every rule the
audit already applies keeps working untouched.

The card count takes care of itself: the old commander leaves, the new one
enters, the 99-card list is unchanged, and the deck is still 100.

Mechanically, `optimization.commanders` stays **frozen as the original** — it is
what the before/after diff is measured against. The chosen commander lives in
`contract["visao"]["comandante"]`, and a single derived function,
`Optimizations.current_commanders/1`, returns the contract's commander when
present and the frozen ones otherwise. Every consumer — snapshot, list export,
the keep-list that protects commanders from being cut — reads that function.
One source of truth, derived, never stored twice.

---

## 6. The recipe

```
1.  Visões          lens :visao        → three directions, then :awaiting_choice
2.  Reconstrução    lens :full         → the big swap that implements the vision
3.  Mana            lens :mana_ramp
4.  Early game      lens :speed_curve
5.  Interação       lens :interaction
6.  Consistência    lens :consistency
7.  Estabilização 1 checkpoint
8.  Matchups        validation :matchup
9.  Fidelidade      validation :alinhamento   → against the VISION
10. Estabilização 2 checkpoint
```

Ten stages, ten consults, ~55 min at the 5.5 min/consult measured on
2026-08-14's real run. The choice between stages 1 and 2 costs nothing and takes
as long as the owner takes.

Stages 3–10 are **the refine recipe verbatim**, and that is the point: once the
direction is chosen and the big swap is done, making the new deck good is the
same work the Otimizador already does well. The only change is stage 9's target.

No scout stage: a reimagining does not need the deck's current purpose written
down first, and if a dossier exists it is passed as context regardless.

**Reconstrução** is the one genuinely new stage. Its briefing carries the chosen
vision and says: cut what does not serve this direction and add what does; you
have more freedom here than any other stage; the flip-flop guard still applies,
and so do the ceilings, the identity rule and the salt contract.

---

## 7. What the UI gains

Everything lands on the two pages that already exist.

**The launcher** gains a mode toggle as its first control — *Refinar* /
*Reimaginar* — which switches the copy, the stage count on the button, and
reveals the salt controls. The salt block is six rows of three-way controls plus
the two preset buttons. Everything else in the modal is unchanged.

**The timeline** gains the vision cards (only while `:awaiting_choice`), the
per-stage salt refusals (which need no new UI — they are audit problems, already
rendered), and a line in the header naming the chosen vision once there is one.

**The history page** gains a badge per run: *refinar* or *reimaginar*, and the
vision's name when there is one.

**The deck page** button already switches on a live run; it gains the
`:awaiting_choice` wording.

---

## 8. Genericity

The same guarantee the Otimizador makes, restated because this mode is more
tempting to over-fit: **nothing here may be tuned to the reference deck.** The
salt vocabulary comes from the role engine, the identity rule comes from the
Commander rules, the commander validation reads the catalogue, and the vision
briefing describes a *kind* of answer, never a strategy. A synthetic deck in
another colour pair must run the whole pipeline with no special case.

The regression test is the enforcement, and it runs on a deck that is not the
reference deck.

---

## 9. Testing

Unit, on seeded fixtures:

- the salt guard: an avoided-tactic add is rejected with the pt-BR reason; the
  same add passes with the tactic set to `tanto_faz`
- the commander validation: each of the three refusals, and one accepted swap
- the `:mill` rule: a real milling card matches, a card that merely draws does not
- the launch-time contradiction check
- `current_commanders/1`: frozen before a choice, the vision's after

End-to-end, on a synthetic deck, mirroring
`pipeline_regression_test.exs`: a scripted vision stage returning three
directions, the run landing in `:awaiting_choice`, a choice made, the
reconstruction applying, a salt-violating add rejected, a commander swapped, the
final list at exactly 100, and the deck page showing none of it.

Then a real run on a throwaway deck before the reference deck, because the
lesson of 2026-08-14 is that the real run finds what tests do not: the count
that nothing measured, and the transient failure that swallowed a real card.

---

## 10. Decision log

- **A mode, not a feature.** Reuse beats duplication when the reused parts are
  proven and the owner wants runs side by side. (§1)
- **Three visions, owner chooses, run waits.** The owner asked for the AI's
  ideas, not for the AI's decision. Seeing the direction before paying for the
  other nine stages is the whole point. (§3)
- **`:awaiting_choice` is its own status.** "You stopped it" and "it is waiting
  for you" are different sentences on the screen, and derived state here would
  be a bug in waiting. (§3)
- **The model names cards; the app prices them.** The vision shows a real R$
  total without the model ever stating a price. (§3)
- **Salt is enforced, not requested — but only in one direction.** `evitar` is a
  rule the audit applies; `quero` is an invitation, because no engine can force
  an idea. (§4)
- **Mill becomes a role, not a special case.** It is a property of cards, so it
  belongs in the vocabulary where everything else can see it. (§4)
- **The new commander must match the colour identity exactly.** A subset makes
  existing cards illegal in a cascade that has nothing to do with the deck being
  better. This is a correctness boundary. (§5)
- **`commanders` stays frozen; the swap is derived.** The diff needs the
  original, and two stored copies of one fact drift. (§5)
- **Stages 3–10 are the refine recipe verbatim.** Once the direction is set,
  making the deck good is work that already works. (§6)
- **`bracket_max` still defaults to the measured floor.** Permission to change
  the plan is not permission to change the table. (§2)
