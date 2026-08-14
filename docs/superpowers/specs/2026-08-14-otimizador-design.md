# deckex — O Otimizador — Design Spec

**Date:** 2026-08-14
**Status:** Designed (Fable); awaiting owner review, then implementation (Opus, Plano 10)
**Extends:** every prior spec — this is the feature the rest was built to enable

---

## 1. What we are building

One button that takes a deck through a **pipeline of AI analysis stages** and
shows, stage by stage and live, how the deck evolves. Each stage consults a
model through a specific lens, the engine audits the answer, and the **clean
suggestions are applied automatically — to a sandbox copy, never to the real
deck**. Later stages see everything earlier stages did and may revert it, with
a stated reason. Checkpoint stages look at the whole picture and stabilize;
validation stages stress the result against matchups and against the deck's
own purpose. At the end — or at any intermediate point — the owner can save
the state as a new deck.

The owner's brief, verbatim where it matters:

- *"a cada pipeline, você vai usando uma IA para reanalisar […] Pode discordar
  de uma IA do pipeline anterior e tirar uma carta que o pipeline anterior
  acabou de colocar. Não tem problema."* — disagreement is a feature.
- *"rounds de análise específicas e rounds de análises completas para fazer
  algumas estabilizações"* — the recipe below.
- *"um script validando, por exemplo, outros matchups […] validar se o deck
  está seguindo o propósito dele"* — the validation stages.
- *"deixar genérico para a gente poder expandir isso para outros decks"* —
  the genericity guarantees, §8.
- *"não misturar tudo nessa página principal"* — pipeline consults live on
  their own pages, never in the deck page's consult list.
- *"poder favoritar ou dar feedback em alguns pontos"* — per-stage feedback.
- *"fazer decks a partir de cada ponto"* — save-as-new-deck from any stage.

### Why this is the right next feature

Everything the pipeline needs already exists and is individually validated:
the dossier gives every stage the deck's purpose; the audit gates what may be
applied (legality, singleton, price ceilings, bracket headroom); the
simulation measures each stage's impact; consults give frozen briefings,
background execution and live updates. The Otimizador is those parts
composed into a loop — the only genuinely new machinery is the sandbox, the
state machine that advances it, and the pages that show it.

### What we are explicitly NOT building (v1)

- **No from-scratch deck generation.** "Build me a new deck from a commander"
  is a different product with a different failure mode. The data model leaves
  room (an optimization is just a starting list plus stages), but v1 always
  starts from an existing deck.
- **No recipe editor UI.** The recipe is data (§4), so variants are cheap
  later; v1 ships one default recipe and a launch modal that configures the
  contract, not the stages.
- **No parallel stages.** One consult at a time, in order. The whole point is
  that each stage sees the previous one's work; parallelism would trade the
  feature's essence for speed.
- **No automatic writes to the real deck, ever.** The sandbox is the product.
  Leaving the sandbox is always an explicit owner action (§7).

---

## 2. The sandbox

An **Optimization** owns a working copy of the decklist: plain data,
`[%{"name" => ..., "quantity" => ...}]`, frozen from the deck at launch
(commanders recorded separately and immutable — no stage may cut the
commander). Every stage records the list it received; the list it produces is
derived by applying its accepted changes. The real deck is never touched.

This one decision buys most of the feature:

- **Stages can apply changes automatically** without violating the house law
  that spending and deck edits are the owner's click — the click happened at
  launch, for a declared batch, on a copy.
- **"Create a deck from this point" is trivial**: any stage's list is a
  decklist; saving it is `Decks.import_from_text/2` with a generated name
  ("Iroh das Lontra — otimizado 14/08, etapa 4").
- **The audit stays honest**: each stage's suggestions are audited against
  the sandbox as it stands at that stage, not against the original deck.

Snapshots for analysis are built from the sandbox list via the catalogue
(cards + roles are already there; anything a stage adds was catalogued when
its consult finished). `Analysis` stays pure; the builder lives in the
`Optimizations` context.

---

## 3. The contract

Every optimization freezes a **goal contract** at launch, shown in the launch
modal and injected into every stage's briefing:

| Field | Default | Meaning |
|---|---|---|
| `bracket_max` | the deck's current measured floor | The bracket the result must not exceed. The audit hard-rejects an add that would break it. Configurable: the owner who *wants* to climb to 4 sets it so. |
| `ceilings` | from Settings (`Settings.ceilings(:upgrade)`) | R$ per card / per land, audited against Scryfall prices. |
| `keep` | `[]` | Card names the pipeline must not cut — pet cards. Cuts of these are hard-rejected. Commanders are implicitly kept. |
| `matchups` | `["um deck aggro rápido", "um deck de controle pesado"]` | What the validation stage stresses against. Free text, editable at launch. |
| `notes` | `""` | Anything the owner wants every stage to know ("mantenha o tema de lontras"). |
| `model` | `Settings.model()` | One model for the whole run. Recorded, like every consult. |

The contract is the answer to "cuidado para não forçar o formato desse deck":
nothing deck-specific lives in code; the purpose comes from the deck's own
dossier, the constraints from the contract, the numbers from the engine.

---

## 4. The recipe

A list of stage specs — **data, frozen at launch**, so future variants are
configuration rather than code:

```
1. Dossiê          :scout        (skipped if the dossier is fresh)
2. Mana            :mana_ramp
3. Early game      :speed_curve
4. Interação       :interaction
5. Consistência    :consistency
6. Estabilização 1 :full         CHECKPOINT
7. Matchups        :matchup      VALIDATION (one consult covering contract.matchups)
8. Propósito       :alinhamento  VALIDATION (new lens: does the list still do what the dossier says?)
9. Estabilização 2 :full         CHECKPOINT
```

Nine stages, typically eight consults (the scout usually skips), ~30–45
minutes end to end. The launch modal states exactly this before the button.

**Stage kinds** decide behaviour, not code paths: `:lens` stages propose
changes through their lens; `:checkpoint` stages see everything and stabilize
(their briefing explicitly invites reverts); `:validation` stages test rather
than tune — they may still propose changes, but their task is to find what
the tuning missed. All three produce the same shape (leitura, diagnosis,
cuts, adds) and go through the same audit.

**Convergence:** a checkpoint is **skipped** when every stage since the
previous checkpoint (inclusive) applied zero changes — a second look at an
unchanged picture buys noise with money. In the default recipe that means:
Estabilização 1 finding nothing does *not* skip the validations (they ask new
questions of a stable deck, which is exactly when their answers are
trustworthy), but if the validations also change nothing, Estabilização 2 is
skipped and the run ends as "estabilizou". A failed consult pauses the run
(never cancels it): the stage shows the error and a "Tentar de novo" button;
everything already done is kept.

**The `:alinhamento` lens** is the one new lens: "here is the dossier, here
is the current list after N stages of changes — does this deck still do what
its dossier says? Propose changes only where the optimization drifted from
the purpose." It is the owner's *"validar se o deck está seguindo o propósito
dele"*, and the dossier — written before any changes — is the fixed star it
steers by.

---

## 5. One stage, end to end

```
list_before ──► snapshot (catalogue) ──► report ──► briefing ──► consult (Oban)
                                                                     │ done
     applied/rejected ◄── audit (contract-aware) ◄── suggestions ◄───┘
          │
          ├── applied  → next stage's list_before
          └── rejected → recorded with the engine's reasons, visible on the timeline
```

The briefing carries everything a stage needs to disagree intelligently:

- the **contract** (§3) and the deck's **dossier**;
- the sandbox's **measured report** (not the original deck's);
- the **changelog**: every prior stage's applied changes with the model's
  reasons, and its rejected ones with the engine's reasons;
- the rule: *you may revert an earlier change, but engage its stated reason;
  each card may enter and leave this optimization once — the engine enforces
  it.*

**The audit gains three pipeline rules**, all hard problems (rejected, not
noted):

1. **Flip-flop guard**: a card that was already added and cut (or cut and
   added) in this run cannot flip again. Ping-pong between stages is the
   failure mode of chained critics, and it is countable, so the engine counts
   it. First flip is legitimate disagreement; second is churn.
2. **Keep-list guard**: cuts of contract-kept cards (and commanders) are
   rejected.
3. **Bracket guard**: an add whose Game Changer status would push the
   sandbox past `contract.bracket_max` is rejected — the existing headroom
   *note* becomes a hard rule inside a pipeline, because here nobody is
   clicking per-suggestion.

Only **clean** suggestions are applied. Rejections are not failures — they
are the engine doing its job, and the timeline shows them with reasons, which
is itself feedback the owner asked for.

---

## 6. Execution model

- `Optimizations.start(deck, contract)` creates the run + stages, freezes
  the list, and enqueues stage 1. **One running optimization per deck** —
  a second start while one runs is refused with a pointer to it.
- Each stage is a **Consult** with a new nullable `optimization_id` column —
  frozen briefing, ConsultWorker, model recording, everything reused. The
  deck page's consult list filters `optimization_id: nil`, which satisfies
  "não misturar tudo nessa página principal" with one `where`.
- When a pipeline consult succeeds, `Consults.succeed/3` (which already
  delivers dossiers and catalogues cards, then broadcasts last) additionally
  enqueues **AdvanceWorker**: audit → apply → persist stage → broadcast →
  enqueue next stage or finish. The broadcast-last law holds: the
  optimization event fires only after the stage's results are readable.
- **Pause** stops advancing after the current consult lands (a running model
  call is never killed — it is money already spent); **resume** re-enqueues.
  **Cancel** marks the run cancelled; everything done stays readable.

---

## 7. The pages

Two routes, separate from the deck page:

**`/decks/:id/otimizacoes`** — history: past runs with their outcomes (status,
stages run, criticals start→end, cost delta), and the launcher. The launch
modal shows the recipe, the contract (editable: bracket_max, ceilings, keep,
matchups, notes, model) and the honest price of the button: *"9 etapas, uma
consulta de 2–5 min cada, modelo opus"*. One click starts it.

**`/otimizacoes/:id`** — the run, live. A vertical timeline, one card per
stage, updating by PubSub as consults land:

- stage label, status, the model's `leitura`;
- **applied** changes (with R$ prices) and **rejected** ones with the
  engine's reasons;
- the measured impact: findings resolved / introduced at this stage;
- **feedback**: 👍/👎 and a favorite star per stage, with an optional note —
  stored on the stage. v1 stores and displays it (it is the owner's margin
  notes and the raw material for tuning prompts later); it does not yet feed
  back into prompts;
- **"Criar deck deste ponto"** — saves that stage's list as a new deck.

A header strip tracks the evolution: criticals at start → now, bracket floor
at start → now, net cost of applied adds in R$, cards changed. When the run
finishes: the consolidated diff against the original list, export (copy /
CSV), and "Salvar como novo deck".

The deck page itself gains exactly one element: an "Otimizar" button linking
to the history page.

---

## 8. Genericity guarantees

Checked, not hoped for:

- **No card names in pipeline code.** The flip-flop, keep and bracket guards
  operate on the contract and the run's own history. (The rules engine's
  oracle-text patterns are card-generic already.)
- **Purpose is the deck's own dossier** — a Golgari graveyard deck optimizes
  toward *its* dossier with zero code changes.
- **Defaults derive from the deck and Settings**, never from constants tuned
  to the reference deck: `bracket_max` from the measured floor, ceilings from
  Settings, matchups editable text.
- **The regression suite runs the pipeline on a synthetic mono-G deck**, not
  on Iroh — the reference deck stays a *validation* fixture, not the shape
  the code fits.

---

## 9. Testing

All through Mox; no network, no real spending in tests.

- **Context**: start freezes list/contract/recipe; one-per-deck guard; scout
  skip when dossier fresh; snapshot builder from a sandbox list.
- **AdvanceWorker**: applies clean changes and records rejections with
  reasons; flip-flop, keep and bracket guards each proven with a concrete
  sequence; checkpoint-zero-changes ends the run early; consult failure
  pauses rather than cancels; pause stops advancement, resume continues.
- **Briefing**: contract block, changelog block with both applied and
  rejected entries, `:alinhamento` task block.
- **LiveView**: launch modal starts a run and refuses a second; timeline
  renders stages live; feedback round-trips; criar-deck-deste-ponto creates a
  real deck whose snapshot matches the stage list; deck page consult list
  excludes pipeline consults.
- **End-to-end regression**: a scripted 4-stage run on a synthetic deck with
  mocked answers that include one revert (accepted, with reason) and one
  flip-flop attempt (rejected), asserting the final list and every stage
  record.

## 10. Decision log

| Decision | Rationale |
|---|---|
| Sandbox, never the real deck | Auto-apply and owner-safety stop conflicting: the launch click authorizes a declared batch on a copy. Save-as-new-deck falls out for free. |
| Stages are Consults | Frozen briefing, worker, model recording, PubSub, audit — all reused. The pipeline is composition, not new machinery. |
| Advance on the server, not the page | A pipeline that only advances while a browser tab is open is a toy. AdvanceWorker hooks the same succeed path that delivers dossiers. |
| Flip-flop guard in the engine | Ping-pong is chained critics' known failure mode and it is countable. First flip is disagreement (wanted); second is churn (rejected). |
| Checkpoint-zero-changes ends the run | "Estabilizou" is the honest convergence signal. Running the remaining stages after it buys noise with money. |
| Failure pauses, never cancels | Stages already paid for stay; the owner retries one stage, not the run. |
| Feedback stored, not yet fed back | Storing is cheap and the notes are the raw material for prompt tuning later; closing that loop well is its own design. |
| One model per run | A per-stage model matrix is configuration surface without evidence. The comparison feature exists for choosing the model; the run records it. |
| `:alinhamento` as a lens | The purpose check is a question to a model like any other; the dossier written before the changes is the fixed reference point. |
