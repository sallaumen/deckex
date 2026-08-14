# Plano 9 — Auditoria do motor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans (inline, owner waived checkpoints). Spec: `docs/superpowers/specs/2026-08-14-auditoria-do-motor-design.md`.

**Goal:** Every AI answer is verified by the pure engine: per-suggestion legality verdicts, and a simulated before→after findings diff.

**Global constraints:** as Plano 8 (language rule, errors as data, no network in tests, gate chained with `&&` — `mix test` NEVER piped before the `&&`).

### Task 1: `Analysis.Simulation` (pure)
- Create `lib/deckex/analysis/simulation.ex`, `test/deckex/analysis/simulation_test.exs`.
- `apply_changes(DeckSnapshot.t(), [{:cut, String.t()} | {:add, CardEntry.t()}]) :: DeckSnapshot.t()`.
- Tests: cut decrements quantity; cut removes at one copy; missing cut is a no-op; add appends; add of existing basic bumps quantity; add violating singleton is a no-op; commanders untouched.

### Task 2: `Analysis.ReportDiff` (pure)
- Create `lib/deckex/analysis/report_diff.ex`, `test/deckex/analysis/report_diff_test.exs`.
- `diff(Report.t(), Report.t()) :: %{resolved: [Finding.t()], remaining: [Finding.t()], introduced: [Finding.t()]}` — by finding code; `resolved`/`remaining` carry the *before* finding, `introduced` the *after*.

### Task 3: `Consults.Audit` + `Consults.audit/2`
- Create `lib/deckex/consults/audit.ex`; modify `lib/deckex/consults.ex`; test `test/deckex/consults/audit_test.exs` (DataCase + CatalogueFixture).
- `%Audit{problems: %{{:cut | :add, String.t()} => [String.t()]}, resolved:, remaining:, introduced:}`.
- Problems (pt-BR): add outside identity — "fora da identidade de cor (X) — ilegal"; non-basic add already in deck — "já está no deck — Commander é singleton"; `commander_legal: false` — "não é legal em Commander"; cut absent from main — "não está na lista principal". Unresolved adds: no problems, excluded from simulation.
- `Consults.audit(snapshot, suggestions)` loads roles via `CardQuery.roles_by_card_ids/1` for resolved adds, builds entries, calls Simulation + two `Analysis.report(snap, Settings.baselines())`, diffs.

### Task 4: DeckLive renders the audit
- Modify `lib/deckex_web/live/deck_live.ex`: in `refresh_consults/1`, compute `audits: %{consult_id => Audit.t()}` for done consults with suggestions (needs snapshot — compute after `assign_deck` sets it; restructure so refresh_consults reads `socket.assigns.snapshot`). Row problems render as `text-sev-critical` micro lines; diff block "Conferido pelo motor" lists resolvidos/persistem/novos with severity dots and codes.
- Test in `test/deckex_web/live/settings_and_table_test.exs` or new file: a done consult with an illegal add shows the verdict; the diff block names a resolved finding code.

### Task 5: Real-deck regression + gate + browser
- Extend `test/deckex/analysis/real_deck_test.exs`: audit a synthetic opus-shaped answer (cut Reliquary Tower/Mountain, add G lands) against the Iroh snapshot; assert `mana.color_starved` lands in resolved or the counts move; assert an out-of-identity add (e.g. "Swords to Plowshares" white) is flagged.
- `mix lint`, browser proof, commit.
