# Confiança e custo — which model answers, and what a run may spend

**Status:** approved 2026-08-14. Companion to
[o que a mesa sente](2026-08-14-o-que-a-mesa-sente-design.md); both are
implemented by the same plan. Extends
[the Otimizador](2026-08-14-otimizador-design.md).

---

## 0. The problem, measured

The owner asked for two things and the database agrees with both.

**Cheap models have been proposing card changes.** Across every consult ever
run: `sonnet` produced three full-deck answers and **all three proposed cuts and
adds**. They came from "Comparar modelos", which by design asks the same
question of every model — a legitimate feature that has been quietly seeding the
suggestion tables with answers from models the owner does not trust for that
job. Meanwhile `fable` has run **once** in the project's history.

**The engine has been spending well on the wrong stages.** The `scout` and
`bracket` lenses propose no card changes at all — they write a dossier and
classify a bracket — and both ran on `opus`. The expensive model was used where
it changed nothing, and a cheap model was allowed where it changed everything.

**And a ceiling set in a poorer moment is now costing deck quality.** The only
price refusal in the whole real run was `Boseiju, Who Endures` at R$ 270,65,
blocked by a **land** ceiling of R$ 200 — a card the model had called the direct
answer to the measured finding.

---

## 1. The model floor

Lenses divide cleanly by whether their answer **changes the deck**.

| | lenses | floor |
|---|---|---|
| **Propõem mudança** | `full`, `finding`, `matchup`, `budget`, `upgrade`, `speed_curve`, `mana_ramp`, `interaction`, `consistency`, `alinhamento`, and the reconstruction stage | the configured floor, default `fable` |
| **Só leem** | `scout`, `bracket` | none — anything goes, and the app suggests the cheap one |

`visao` counts as **change-proposing**, even though its answer carries no cuts
and no adds: it names the cards the owner will buy and sets the direction the
other nine stages execute. A cheap answer there is the most expensive mistake
available.

A new setting, `modelo_minimo_para_mudancas`, default `"fable"`, with the model
list ordered by capability in one place — `Deckex.Consults.model_rank/1` — so
"below the floor" is a comparison and not a hardcoded name repeated around the
codebase.

### Enforcement differs by context, deliberately

**In the pipeline it is a refusal.** A run whose contract names a model below
the floor is refused at launch with the reason, exactly like the
self-contradicting salt contract. Nobody is watching a pipeline mid-flight to
catch a cheap answer, and by the time it lands the money is spent.

**On the deck page it is a mark, not a block.** A single consult asked of a
below-floor model still runs, and its suggestion table carries a visible note
saying the answer came from below the owner's floor. Two reasons: "Comparar
modelos" exists precisely to ask cheap models change questions, and it must keep
working; and an owner exploring on purpose should not be argued with.

**Read-only lenses get the opposite nudge.** The dossier and bracket controls
default to the cheapest model rather than the global default, with a line saying
why. Spending opus money on a stage that proposes nothing is the same waste in
the other direction.

---

## 2. Redoing a stage with a different model

The owner reads a stage's answer, decides the model was not up to it, and wants
that stage computed again — by a better model, from the same starting point.

### The rule that makes it honest

Stage N's answer is the input to every stage after it. Recomputing N and keeping
N+1 onward would leave the sandbox describing a history that never happened.

So **redoing stage N rewinds the run to N**:

- a new consult is requested for stage N, with the chosen model, against the
  **same `list_before`** — the same question, asked better
- stages N+1 onward return to `:pending`: `applied`, `rejected`, `consult_id`
  and `list_before` are cleared. `list_before` is derived anyway, so nothing is
  lost that cannot be recomputed
- the run returns to `:running` and continues from N when the new answer lands
- if the run had finished, it is running again, and `outcome` and `finished_at`
  are cleared

**The discarded answers are not deleted.** The old consults stay attached to the
run by `optimization_id`, exactly as declined vision sets do. The timeline shows
that a stage was redone and lets the owner read what the previous model said —
that comparison is most of the value.

### What the owner sees before clicking

The control states the cost in the two currencies that matter: how many stages
will be discarded and re-run, and which model will answer. A stage in the middle
of a ten-stage run is an expensive click and the button says so rather than
discovering it afterwards.

### Vision stages

Redoing the `visao` stage is the existing "pedir outras três" with a model
choice attached; it reuses that path rather than adding a second one. Its rewind
is the same rule — a chosen direction is cleared, because the direction came
from the answer being replaced.

---

## 3. What a run may spend

Per-card ceilings answer "is this one card too expensive". They cannot answer
"how much is this whole round costing me", which is the question an owner with a
real budget actually has.

- `contract["orcamento_total"]` — reais, optional. The audit refuses an add that
  would push the run's applied entries past it, with the running total in the
  reason. Same guard shape as the ceilings and the salt contract; the run page
  already sums **Entradas**, so the number is one the owner is already reading.
- The deck page gains the deck's **total value**, summed from the catalogue.
  A player who says "my decks can reach R$ 8–10 mil" has no way to see where a
  deck currently sits, and the app has held every price all along.

The per-card ceilings stay: a R$ 3.000 single card is a different decision from
R$ 3.000 spread across twenty, and the owner should be able to speak to both.
Their **defaults** are unchanged — they are already editable in Ajustes, and a
number the owner set is not ours to raise. The land ceiling costing the run a
card it wanted is worth saying out loud in the UI, once, where the refusal
appears.

---

## 4. Testing

- `model_rank/1` orders the known models, and an unknown model ranks lowest
  rather than raising.
- Launching a pipeline below the floor is refused with the reason; at or above
  it, it launches.
- A single consult below the floor runs and is marked; a read-only lens below
  the floor is not marked.
- Redo: a scripted three-stage run, redo stage 2 with another model, assert
  stage 3 returned to `:pending` with its results cleared, the run is
  `:running`, stage 2 has a new consult with the new model, and the previous
  consult is still queryable.
- Redo on a finished run clears `outcome` and `finished_at`.
- The total-budget guard refuses the add that crosses the line and not the one
  before it.

---

## 5. Decision log

- **The floor is about what an answer *changes*, not what it costs.** A lens
  that only reads may use any model; a lens that proposes cutting a card from a
  real deck may not. (§1)
- **`visao` is change-proposing.** It names what gets bought and steers nine
  stages. (§1)
- **Refuse in the pipeline, mark on the page.** Nobody supervises a pipeline;
  someone is always supervising a single consult, and model comparison is a
  feature, not an accident. (§1)
- **Redoing a stage rewinds everything after it.** The alternative is a sandbox
  whose history is a lie. (§2)
- **Discarded answers are kept.** Reading what the cheaper model said next to
  what the better one said is most of why the feature exists. (§2)
- **A total budget joins the per-card ceilings rather than replacing them.**
  They answer different questions. (§3)
- **We do not raise the owner's ceilings for them.** We surface, once and where
  it happened, that a ceiling refused a card the analysis wanted. (§3)
