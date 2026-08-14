# deckex — Engine audit of AI answers — Design Spec

**Date:** 2026-08-14
**Status:** Approved (owner directive: "melhorar mais ainda, com a definitiva certeza"), pending plan
**Extends:** `2026-08-14-meta-prompt-dossie-design.md`

## 1. What we are building, and why

A consult's suggestions are, today, unverified claims. The engine can verify
them — it already measures decks, it is pure, and it is fast. This feature
closes the loop: **the model proposes; the engine confirms with arithmetic.**

Two verifications, both deterministic and free:

1. **Legality audit, per suggestion.** Each add is checked against the card's
   actual data: colour identity ⊆ deck identity; singleton (already-in-deck
   adds flagged unless basic/any-number); `commander_legal`. Each cut is
   checked to exist in the main board. Verdicts are pt-BR problem strings
   shown on the suggestion row.

2. **Impact simulation.** Apply every applicable suggestion to the snapshot
   *in memory*, re-run `Analysis.report/2`, and diff the findings by code:
   **resolvidos** (gone), **persistem** (still there), **novos** (introduced
   by the change — e.g. cutting a land starves the mana base). Shown as a
   "Conferido pelo motor" block under the suggestion table.

The audit is computed on read, never stored: it always answers "what would
happen if applied **now**", against the deck as it currently is. After the
owner applies a cut, an old consult's audit honestly reports that card as no
longer in the list.

### NOT building
- No second model call, no judge — certainty here is arithmetic, not opinion.
- No auto-apply. The audit informs the click; the click stays the owner's.

## 2. Components

- `Deckex.Analysis.Simulation` (pure): `apply_changes(snapshot, changes)` with
  `{:cut, name_normalized}` and `{:add, CardEntry.t()}`. Cut decrements one
  copy, removing the entry at zero; missing cuts are skipped (the legality
  audit reports them). Add bumps quantity for an existing basic, appends a new
  entry otherwise; adds that would violate singleton are skipped (ditto).
- `Deckex.Analysis.ReportDiff` (pure): `diff(before, after)` →
  `%{resolved: [Finding.t()], remaining: [Finding.t()], introduced: [Finding.t()]}`,
  keyed by finding code.
- `Deckex.Consults.Audit`: the context-side orchestration.
  `Consults.audit(snapshot, suggestions)` loads roles for the added cards,
  builds the simulated snapshot, runs both reports with `Settings.baselines()`,
  and returns an `%Audit{problems: %{{action, name} => [String.t()]}, resolved:, remaining:, introduced:}`.
  Unresolved suggestions (no catalogue card) are excluded from simulation; the
  table already marks them.
- UI: problem strings render on the suggestion row (same slot as the
  "não achei essa carta" warning); the diff block renders under the table for
  done consults with at least one resolved suggestion.

## 3. Testing

Pure modules get pure tests (AnalysisFixture). Audit tests run on DataCase
with the catalogue fixture. LiveView test: a done consult renders its audit
verdicts and diff. Real-deck regression: audit the recorded opus answer shape
against the Iroh snapshot and assert the diff resolves `mana.color_starved`.

## 4. Decision log

| Decision | Rationale |
|---|---|
| Audit computed on read, never stored | The honest question is "if applied now"; storage would freeze a lie as the deck drifts. Reports are arithmetic over ~100 structs — recomputing is free. |
| Skipped-not-crashed on inapplicable changes | The legality audit names the problem; the simulation measures what remains applicable. Two concerns, two outputs. |
| No judge model | A second opinion is still an opinion. The engine's numbers are the definitive certainty the owner asked for. |
