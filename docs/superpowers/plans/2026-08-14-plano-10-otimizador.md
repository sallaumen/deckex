# Plano 10 — O Otimizador Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans (inline; owner waives checkpoints — "sem ir me pedindo nada"). Spec: `docs/superpowers/specs/2026-08-14-otimizador-design.md`. Read it first; it carries the reasoning this plan compresses.

**Goal:** One button runs a deck through a pipeline of AI stages on a sandbox copy — lenses, checkpoints, validations — with the engine auditing and applying each stage's clean changes, live on a timeline the owner can give feedback on and fork decks from.

**Architecture:** Stages ARE Consults (frozen briefing, ConsultWorker, PubSub — all reused) tagged with `optimization_id`. The sandbox is a plain list on the Optimization; snapshots are built from it via the catalogue. `Consults.succeed/3` hooks an AdvanceWorker: audit → apply → persist → broadcast → next stage. The audit gains three pipeline guards (flip-flop, keep-list, bracket ceiling).

**Tech Stack:** Elixir 1.19 / Phoenix 1.8 / LiveView 1.2 / Ecto / Oban / Mox — exactly the existing stack, no new deps.

## Global Constraints

- All prior laws in `AGENTS.md` apply verbatim, especially: language rule (code EN / UI pt-BR / card names untranslated); errors as data; triad; no test touches the network; gate (`mix format --check-formatted && mix test && mix lint`, chained with `&&`, `mix test` NEVER piped) before every commit; card writes lock in `oracle_id` order; card facts fetched, never hardcoded; the sandbox never writes the real deck.
- Seed test catalogues through `Deckex.CatalogueFixture`, once per test, in a single call.
- **Genericity (spec §8):** no card names in pipeline code; the end-to-end regression runs on a synthetic deck, not Iroh.
- Dev server port 4005; Postgres host port 5435 (password `postgres` for psql checks).

---

### Task 1: Tables, schemas, triad skeleton

**Files:**
- Create: `priv/repo/migrations/<ts>_create_optimizations.exs`, `lib/deckex/optimizations/optimization.ex`, `lib/deckex/optimizations/optimization_step.ex`, `lib/deckex/optimizations/optimization_query.ex`, `lib/deckex/optimizations.ex`
- Modify: `lib/deckex/consults/consult.ex` (add field), `lib/deckex/error.ex` (add code `:optimization_running`), `lib/deckex/events.ex` (optimization topic), `test/support/factory.ex`
- Test: `test/deckex/optimizations/optimization_test.exs`

**Interfaces — Produces (later tasks rely on these exact names):**

```elixir
# optimizations table/schema
status    Ecto.Enum [:running, :paused, :done, :failed, :cancelled]
outcome   :string           # "estabilizou" | "completo" | nil
contract  :map              # string keys: "bracket_max" int, "ceilings" %{"card","land"}, "keep" [names], "matchups" [..], "notes", "model"
recipe    {:array, :map}    # [%{"kind" => "lens"|"checkpoint"|"validation", "lens" => "mana_ramp", "label" => "Mana"}]
list_original {:array, :map} # [%{"name" => .., "quantity" => ..}]
commanders    {:array, :string}
finished_at   :utc_datetime
belongs_to :deck

# optimization_steps
position :integer; kind Ecto.Enum [:lens, :checkpoint, :validation]
lens :string; label :string
status Ecto.Enum [:pending, :running, :done, :skipped, :failed]
belongs_to :consult (nullable); belongs_to :optimization
list_before {:array, :map}
applied  {:array, :map}  # [%{"action" => "add"|"cut", "card" => name, "reason" => ..}]
rejected {:array, :map}  # same + "problems" => [String]
feedback :map, default: %{}  # %{"rating" => "up"|"down"|nil, "favorite" => bool, "note" => ..}

# consults: add
field :optimization_id, Ecto.UUID   # nullable, plain column + index (no assoc needed)

# Events (mirror the consults pattern in lib/deckex/events.ex)
Events.subscribe_optimization(id) / Events.broadcast_optimization(%Optimization{})
# message: {:optimization_updated, id}
```

Migration: two tables (UUID PKs like every other table — copy the `create_consults` migration's style), plus `alter table(:consults), do: add :optimization_id, :binary_id` and `create index(:consults, [:optimization_id])`.

- [ ] Failing test: changeset round-trips every field; a factory `optimization_factory` (status `:running`, contract/recipe/list as above, `deck: build(:deck)`) and `optimization_step_factory` insert cleanly; `Consult` accepts `optimization_id`.
- [ ] Migrate dev + test envs. Suite green. Commit `feat: optimization tables and triad skeleton`.

---

### Task 2: The sandbox — list ops and snapshot builder

**Files:**
- Modify: `lib/deckex/optimizations.ex`
- Test: `test/deckex/optimizations/sandbox_test.exs`

**Interfaces — Produces:**

```elixir
@spec list_from_deck(Deck.t()) :: %{list: [map()], commanders: [String.t()]}
# reads deck_cards via DeckQuery.list_deck_cards/1; :main → list, :commander → names

@spec apply_changes_to_list([map()], [map()]) :: [map()]
# applies applied-shaped maps; add: +1/insert (respecting nothing else — the audit
# already vetted); cut: -1/remove. Pure list arithmetic, no DB.

@spec list_after(OptimizationStep.t()) :: [map()]
# apply_changes_to_list(step.list_before, step.applied) — list_after is DERIVED,
# never stored (one source of truth).

@spec snapshot_for([map()], [String.t()], Deck.t()) :: DeckSnapshot.t()
# builds CardEntries from the catalogue (CardQuery.list_by_normalized_names +
# Cards.roles_by_card_ids), commanders resolved the same way; color_identity and
# names from the deck. A list entry whose card is missing from the catalogue is
# skipped — same behaviour as import.

@spec list_to_text([map()], [String.t()]) :: String.t()
# the inverse of the parser: check lib/deckex/decks/decklist_parser.ex for the
# commander-section convention it reads, and emit exactly that, so
# Decks.import_from_text/2 round-trips it. Add a round-trip test.
```

- [ ] Failing tests first (DataCase + CatalogueFixture): list_from_deck; apply add-new/add-existing/cut-to-zero/cut-decrement; snapshot_for counts quantities and carries roles; **round-trip**: `list_to_text |> Decks.import_from_text |> Decks.snapshot` equals the original snapshot's names+quantities.
- [ ] Suite green. Commit `feat: the optimization sandbox — lists in, snapshots out`.

---

### Task 3: Contract, recipe, lifecycle

**Files:**
- Modify: `lib/deckex/optimizations.ex`, `lib/deckex/optimizations/optimization_query.ex`
- Test: `test/deckex/optimizations/lifecycle_test.exs`

**Interfaces — Produces:**

```elixir
@spec default_contract(Deck.t()) :: map()
# bracket_max: Bracket.floor(Decks.snapshot(deck)).floor  (spec §3: "don't move my bracket")
# ceilings: Settings.ceilings(:upgrade) → %{"card" => _, "land" => _}
# keep: [], matchups: ["um deck aggro rápido", "um deck de controle pesado"],
# notes: "", model: Settings.model()

@spec recipe(Deck.t()) :: [map()]
# spec §4's nine stages. The :scout stage is included only when
# deck.dossier == nil or deck.dossier_stale — decided HERE, at build time,
# so a skipped scout never appears as a stage at all (simpler than :skipped).

@spec start(Deck.t(), map(), [map()] | nil) :: {:ok, Optimization.t()} | {:error, Error.t()}
# recipe override (3rd arg) exists for tests and future variants; nil → recipe(deck)
# refuses with Error.new(:optimization_running, msg pt-BR) when
# OptimizationQuery.running_for_deck(deck) exists. Otherwise: insert optimization
# (contract merged over defaults, recipe, list_original+commanders via
# list_from_deck) + all steps (:pending, position 1..n, list_before: nil except
# step 1 = list_original) in one Repo.transact, then run_step(step1) — defined
# in Task 5; for THIS task stub run_step as `defp run_step(step), do: {:ok, step}`
# and leave a comment saying Task 5 replaces it.

@spec pause(Optimization.t()) :: {:ok, Optimization.t()}   # :running → :paused
@spec resume(Optimization.t()) :: {:ok, Optimization.t()}  # :paused → :running + advance current pending step (Task 5 wires)
@spec cancel(Optimization.t()) :: {:ok, Optimization.t()}
@spec fetch(id) :: {:ok, Optimization.t() (steps preloaded, ordered)} | {:error, _}
@spec list_for_deck(Deck.t()) :: [Optimization.t()]
@spec set_feedback(OptimizationStep.t(), map()) :: {:ok, OptimizationStep.t()}
@spec save_as_deck(Optimization.t(), OptimizationStep.t() | nil) :: {:ok, Deck.t()} | {:error, _}
# list = step && list_after(step) || last done step's list_after || list_original;
# name: "#{deck.name} — otimizado #{Calendar.strftime(date, "%d/%m")}" (dedupe by
# appending the step position when taken); creates via list_to_text + import_from_text.
```

- [ ] Failing tests: defaults derive from deck+settings; scout included only when dossier missing/stale; start freezes list/contract/recipe and refuses a second concurrent run; pause/resume/cancel transitions; set_feedback merges; save_as_deck produces a deck whose snapshot matches the stage list.
- [ ] Suite green. Commit `feat: optimization lifecycle — contract, recipe, start/pause/save-as-deck`.

---

### Task 4: Briefing and lenses for the pipeline

**Files:**
- Modify: `lib/deckex/consults/briefing.ex`, `lib/deckex/consults/consult.ex` (lens `:alinhamento`), `lib/deckex/consults/schemas.ex` (`:alinhamento` uses the default leitura/cuts/adds schema — no change needed, just no special clause), `lib/deckex/consults.ex`, `lib/deckex/consults/consult_query.ex`
- Test: `test/deckex/consults/briefing_test.exs` (extend), `test/deckex/consults_test.exs` (extend)

**Interfaces:**

```elixir
# Briefing.build opts gains :optimization —
# %{contract: map, changelog: [%{label: _, applied: [..], rejected: [..]}], stage_kind: atom}
# Rendered as "## Otimização em andamento" between the dossier and the decklist:
#   - the contract lines (bracket máx, tetos R$, keep list, notes)
#   - per prior stage: applied (with the model's reasons) and rejected (with the
#     engine's problems)
#   - the rule: "You may revert an earlier change, but engage its stated reason.
#     Each card may enter and leave this optimization once — the engine enforces it."
# stage_kind :checkpoint appends to the task: an explicit invitation to revert;
# stage_kind :validation appends: "your job is to find what the tuning missed".

# task_block(:alinhamento, _): the dossier is the fixed reference — propose
# changes ONLY where the current list drifted from the deck's stated purpose.

# task_block(:matchup, opts): accept opts[:against] as binary OR list of binaries
# (joined "; ") — the pipeline sends contract["matchups"].

# Consults.request/3 generalizes minimally:
#   snapshot = opts[:snapshot] || Decks.snapshot(deck)
#   insert! writes optimization_id: opts[:optimization_id]
# compare/4 passes through unchanged.

# ConsultQuery.list_for_deck/1 gains `where: is_nil(c.optimization_id)` — the
# deck page never shows pipeline consults (spec §6). New:
# ConsultQuery.get_by_optimization_step — not needed; steps hold consult_id.
```

- [ ] Failing tests: briefing renders contract + changelog (applied AND rejected entries) + the flip rule; `:alinhamento` task references the dossier as fixed star; matchup accepts a list; `request` with `snapshot:`/`optimization_id:` freezes a briefing built from THAT snapshot (assert a card present only in the sandbox list appears in the briefing) and tags the consult; deck-page listing excludes tagged consults (regression: existing tests keep passing).
- [ ] Suite green. Commit `feat: briefings speak pipeline — contract, changelog, alinhamento`.

---

### Task 5: The audit guards and the AdvanceWorker

**Files:**
- Modify: `lib/deckex/consults/audit.ex`, `lib/deckex/consults.ex` (succeed/fail hooks), `lib/deckex/optimizations.ex` (`run_step/1` real, `advance/1`, `mark_failed/1`), `lib/deckex/workers/consult_worker.ex` (final-failure hook)
- Create: `lib/deckex/workers/optimization_advance_worker.ex`
- Test: `test/deckex/optimizations/advance_test.exs`, extend `test/deckex/consults/audit_test.exs`

**Interfaces:**

```elixir
# Audit.run gains a 6th arg, opts \\ [] :
#   opts[:history]    :: [%{"action" => _, "card" => _}] — all applied changes so far
#   opts[:keep]       :: MapSet.t(String.t())  — contract keep ∪ commanders
#   opts[:bracket_max] :: pos_integer() | nil
# New problems (pt-BR, hard rejects):
#   flip-flop: name appears >= 2x in history → "já entrou e saiu nesta otimização"
#   keep:      cut of kept name → "está na lista de proteção desta otimização"
#   bracket:   when bracket_max <= 3: an add with game_changer && sandbox already
#              at 3 GCs → "seria o 4º Game Changer — o contrato limita ao Bracket 3";
#              an add carrying :mass_land_denial or :extra_turn roles →
#              "leva o deck ao Bracket 4, acima do contrato"
# (Existing 5-arg callers unaffected: opts default [].)

# Optimizations.run_step(step) :: {:ok, OptimizationStep.t()}
#   builds snapshot_for(step.list_before, commanders, deck); report; requests the
#   consult via Consults.request(deck, step.lens_as_atom, snapshot:, optimization_id:,
#   optimization: briefing_payload, model: contract["model"], against: contract["matchups"]);
#   updates step consult_id + :running; broadcasts.

# Optimizations.advance(consult) :: :ok — the worker body:
#   1. step by consult_id; optimization (steps preloaded)
#   2. suggestions = Suggestions.for_consult(consult)
#   3. audit = Consults.audit-like call but assembled here: Audit.run(snapshot,
#      suggestions, roles, Settings.baselines(), contract ceilings (int values),
#      history: all applied of prior steps, keep:, bracket_max:)
#   4. split: applied = clean rows → maps; rejected = rows with problems
#   5. update step :done + applied + rejected
#   6. next = next :pending step. Convergence (spec §4): if next.kind == :checkpoint
#      and zero changes applied since the previous checkpoint inclusive → mark next
#      :skipped, recurse to the one after. list_before of the next runnable step =
#      list_after(current).
#   7. none left → optimization :done, outcome ("estabilizou" if the last checkpoint
#      was skipped, else "completo"), finished_at. Else if optimization :running →
#      run_step(next); if :paused → stop (results persisted, nothing enqueued).
#   8. broadcast_optimization LAST (the broadcast-last law).

# Hooks in lib/deckex/consults.ex:
#   succeed/3, after catalogue(): if done.optimization_id, do:
#     OptimizationAdvanceWorker.enqueue(done.id)   # BEFORE Events.broadcast_consult
#   ConsultWorker.perform: when the AI returns {:error, _} and job.attempt >=
#     job.max_attempts and consult.optimization_id → Optimizations.mark_failed(consult)
#     (step :failed, optimization :paused, broadcast) — retryable errors keep retrying.

# Optimizations.resume/1 now really resumes: :running + run_step(first :pending
# step whose list_before is set, or the :failed step reset to :pending).
```

- [ ] Failing tests, the heart of the feature — each with a concrete scripted sequence (Mox on `Deckex.AI.Mock`, catalogue seeded once):
  - clean suggestions applied, next stage enqueued with the derived list;
  - a revert (stage 2 cuts what stage 1 added) is APPLIED — first flip is disagreement;
  - a second flip is REJECTED with the flip-flop problem;
  - keep-list and commander cuts rejected; GC-over-contract add rejected; mass-land-denial add rejected under bracket_max 3;
  - checkpoint with zero-changes-since-last-checkpoint is skipped and the run ends "estabilizou";
  - final-failure marks step failed + run paused; resume retries;
  - pause: results persist, nothing enqueued.
- [ ] Suite green. Commit `feat: the pipeline advances itself, and the audit stands guard`.

---

### Task 6: The pages

**Files:**
- Create: `lib/deckex_web/live/optimizations_live.ex` (history + launch), `lib/deckex_web/live/optimization_live.ex` (timeline)
- Modify: `lib/deckex_web/router.ex` (`live "/decks/:id/otimizacoes", OptimizationsLive` and `live "/otimizacoes/:id", OptimizationLive`), `lib/deckex_web/live/deck_live.ex` (an "Otimizar" `.button navigate` in the header)
- Test: `test/deckex_web/live/optimization_live_test.exs`

Follow the app's existing look exactly (tokens only — `DesignTokensTest` guards it; `min-h-11` touch targets; `phx-disable-with` on anything that spends; labels on every field — the UI-review laws).

**OptimizationsLive:** header + past runs as cards (status, outcome, stages done/total, started at) linking to their pages; "Nova otimização" opens a modal (reuse the SettingsPanel open/close pattern) with the contract form — bracket_max select (1/2/3/4 — default the measured floor), two ceiling inputs, keep textarea (one name per line), matchups textarea, notes, model select — and the honest declaration: "N etapas, uma consulta de 2–5 min cada". Submit → `Optimizations.start` → `push_navigate` to the run; `{:error, :optimization_running}` → flash with a link to the running one.

**OptimizationLive:** subscribes via `Events.subscribe_optimization` on mount (mount-only — the duplicate-subscription law); `handle_info({:optimization_updated, _}, _)` refetches. Header strip: status + pause/resume/cancel buttons (`data-confirm` on cancel), criticals start→now, bracket floor start→now (compute two reports from list_original and the latest list via `snapshot_for` — computed on read, the house law), net R$ of applied adds, N cartas mudadas. Timeline: one card per step — label + status chip; leitura; applied list (name, R$, reason) and rejected list (name + problems in `text-sev-critical`); findings resolved/introduced chips; feedback row (👍 👎 ★ buttons + note input, `phx-target` events writing `set_feedback`); "Criar deck deste ponto" (`data-confirm`, calls `save_as_deck(opt, step)` → flash with link). Done runs: consolidated diff vs original + "Salvar como novo deck" + copy-list `<textarea readonly>` with the `list_to_text` output.

- [ ] Failing tests: launch modal starts a run and refuses a second; timeline renders a scripted run's stages (statuses, applied, rejected reasons); feedback round-trips; criar-deck creates a deck whose snapshot matches; pause/resume buttons drive the context; deck page shows the Otimizar button and its consult list still excludes pipeline consults.
- [ ] Suite green. Commit `feat: the Otimizador pages — launch, live timeline, feedback, fork`.

---

### Task 7: End-to-end regression, gate, browser

**Files:**
- Create: `test/deckex/optimizations/pipeline_regression_test.exs`

A scripted 4-stage run on a **synthetic mono-G deck** (seeded fixtures only; identity set as in `audit_test.exs`), recipe override via `start/3` (defined in Task 3): `[mana lens, curve lens, checkpoint, checkpoint]`. Mocked answers: stage 1 adds Cultivate + tries an over-ceiling add (rejected); stage 2 cuts Cultivate with a reason (revert, applied) and tries re-adding it (flip-flop, rejected — note both in ONE answer proves per-answer ordering: history includes THIS stage's earlier rows? No — history is prior stages only; the re-add in the SAME answer collides via singleton/no-op rules instead. Move the re-add attempt to stage 3's answer); checkpoint 3 applies zero; checkpoint 4 must be skipped; outcome "estabilizou". Assert: every stage record (applied/rejected/problems), final list == original, run status/outcome, and that `Consults` for the deck page lists none of it.

- [ ] Full `mix lint` green. Browser proof on port 4005: launch a run on a THROWAWAY imported deck (paste a 6-card list) — do NOT spend real consults on the Iroh deck in this task; with the dev server's real AI adapter a launched run WILL spend money, so either verify the launch modal + immediately cancel, or leave the real full run for the owner. Screenshot the timeline page.
- [ ] Commit `test: the pipeline end to end, on a deck that is not Iroh`.

---

## Self-review notes (already applied)

- **Spec coverage:** §2→T1-T2; §3→T3; §4→T3(recipe)+T5(convergence); §5→T4-T5; §6→T3+T5; §7→T6; §8→T7 synthetic deck + no-card-names (enforced by review); §9→each task's tests.
- **Type consistency:** contract/recipe/applied/rejected are string-keyed maps everywhere (JSONB round-trip law from the dossier work); lenses stored as strings on steps, atoms in consults (`String.to_existing_atom` at run_step, safe because `Consult.@lenses` declares them).
- **Known judgment calls, decided:** scout-skip at recipe build time (not a :skipped stage); list_after derived, never stored; feedback stored not fed back (spec §7); one model per run.
