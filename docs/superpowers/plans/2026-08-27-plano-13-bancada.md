# Plano 13 — A Bancada

Spec: [`2026-08-27-bancada-design.md`](../specs/2026-08-27-bancada-design.md).

Enum columns here are plain `:string`, so `:curadoria`, `:cardapio` and the new
lens cost no migration. Only `selections` does.

## T1 — The shape

- Migration: `optimization_steps.selections :map, default: %{}`.
- `OptimizationStep`: `:selections` field + cast; `kind` gains `:cardapio`.
- `Optimization`: `mode` gains `:curadoria`.
- `Consult`: `@lenses` gains `:cardapio`.
- `Optimizations.recipe(deck, :curadoria)` → plano, cardápio, crítico.
- Tests: recipe shape; changeset round-trips `selections`.

## T2 — The cardápio's answer

- `Schemas.for_lens(:cardapio)` — `leitura`, `cortes`, `adicoes`; a vacancy is
  `{grupo, vaga, candidatos[{carta, porque}]}`, 2–3 candidates, no price field.
- `Briefing.task_block(:cardapio, opts)` — counts, the plan verbatim, "a vacancy
  names a need", "candidates must be real alternatives", "every add costs a cut".
- Tests: schema shape and bounds; briefing carries counts and universal rules
  (`BriefingTest` walks `Consult.lenses()`).

## T3 — `Deckex.Optimizations.Curation`

The one module that knows what a vacancy is. Pure except for `select/3`.

- `vacancies(step)` → `[%Vacancy{action, index, grupo, vaga, candidatos}]`,
  cuts first, reserve flagged.
- `reserve_from(contract)` → how many cut vacancies are principal.
- `select(step, key, card_name | nil)` → persists one decision.
- `chosen(step)` → `[%Suggestion{}]` built from the selections.
- `decided?/undecided_count/net` → the counters the rail reads.
- `commit(optimization, step)` → audits `chosen/1` through the same
  `judge`/`split` path, writes `applied`/`rejected`, advances.
- Tests: selection round-trip, `null` vs absent, suggestions carry the vacancy
  sentence, net arithmetic, commit refused off 100 / with nothing chosen.

## T4 — The gates in the pipeline

- `advance/1`: a `:cardapio` step parks the run in `:awaiting_choice` (the
  existing `vision_step?` branch generalises to `gate_step?`).
- A `:critico` step in `:curadoria` also parks, its answer converted to
  one-candidate vacancies instead of applied.
- `resume/1` refuses while a gate is open, with the mode's own message.
- Tests: pipeline regression for a full curadoria run.

## T5 — `Deckex.Analysis` live preview

- `Curation.preview(optimization, step, deck)` → `{report, audit, count, spend}`
  for the current selections, over the sandbox snapshot. Pure, no Repo beyond
  the catalogue read the audit already does.
- Tests: preview moves when a selection changes; a problem card is reported.

## T6 — `DeckexWeb.BancadaLive`

- Route `live "/otimizacoes/:id/bancada"`.
- Triage phase: one vacancy, art-led candidates, `1`/`2`/`3`/`0`/`←`/`→`.
- Board phase: every vacancy grouped by `grupo`, decisions flippable.
- The rail: `Cartas N/100`, `Críticos a → b`, `Entradas R$`, exception
  counters, curve. Recomputed on every selection.
- Verdict chips from the audit; a problem disables the candidate.
- Commit refused off 100 or with nothing chosen.
- Tests: pick advances, rail moves, locked card disabled, commit gate, remount.

## T7 — The way in and out

- Launch modal: fourth mode, two number fields (cortes / entradas), mode note.
- Run page: a "Sua vez" call-to-action while a gate is open, linking to the
  board; the timeline renders a cardápio step as what he chose.
- Tests: modal launches `:curadoria` with the counts frozen in the contract.

## T8 — The gate

`mix lint` + full suite green, `MIX_ENV=dev mix ecto.migrate` from the
worktree, PR against `main`.
