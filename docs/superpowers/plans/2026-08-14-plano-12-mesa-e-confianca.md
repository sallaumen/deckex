# O que a mesa sente + Confiança e custo — Implementation Plan (Plano 12)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Teach the engine to read a deck the way a table reads it — what it is
like to play against, and where it dies — and put the owner in control of which
model answers, what a run may spend, and whether a stage gets computed again.

**Architecture:** Two new analysis lenses feeding the existing findings
pipeline; six new roles read from oracle text; three new contract dials enforced
by the audit guard that already exists; a model floor drawn by what an answer
*changes*; and a stage redo that rewinds everything downstream.

**Tech Stack:** Elixir 1.19.5 / OTP 27, Phoenix 1.8, LiveView 1.2, Ecto,
PostgreSQL 16 (Docker, host port 5435), Oban (queue `:ai`), Mox, ExMachina.

**Specs:** [o que a mesa sente](../specs/2026-08-14-o-que-a-mesa-sente-design.md)
and [confiança e custo](../specs/2026-08-14-confianca-e-custo-design.md). Read
both first; this plan implements them and does not restate their reasoning.

## Global Constraints

- **Code in English, UI in pt-BR, card names never translated.**
- **Errors as data:** `{:ok, _}` / `{:error, %Deckex.Error{}}`.
- **Triad per context:** context, schema, `*Query`. No Repo in LiveViews.
- **Card writes take their locks in `oracle_id` order.** Seed tests through
  `CatalogueFixture`, **once per test, in a single call**.
- **JSONB payloads are string-keyed everywhere.**
- **An informational note is not a problem** — anything in an audit `problems`
  list rejects the suggestion.
- **The model never states a price, a salt score, or a community statistic**,
  and never guesses legality.
- **The engine reports a bracket FLOOR. No 1–10 power level, ever.**
- **We do not consume EDHREC's data** — their ToS forbids scripted requests and
  reproduction. Patterns are measured from oracle text here.
- **Analysis is pure:** no Repo, no HTTP, no process state in `Deckex.Analysis`.
- **A touch target measures from `--size-touch`**, never the rem scale.
- **Quality gate before every commit:** `mix lint` and `mix test`, both green,
  and **never pipe `mix test`** into another command:
  ```bash
  mix test >/dev/null 2>&1 && echo SUITE-GREEN && mix lint >/dev/null 2>&1 && echo LINT-GREEN && git commit ...
  ```
- **Commit directly to `main`.** No PR, no remote.
- **Nothing tuned to the reference deck.** Regressions run on synthetic decks.

## File Structure

**Created:**
- `lib/deckex/cards/roles/table.ex` — the six roles a table notices, one module
- `lib/deckex/analysis/mesa.ex` — table time measured
- `lib/deckex/analysis/fragility.ex` — where this deck dies
- `test/deckex/cards/roles/table_test.exs`
- `test/deckex/analysis/mesa_test.exs`
- `test/deckex/analysis/fragility_test.exs`
- `test/deckex/consults/model_floor_test.exs`
- `test/deckex/optimizations/redo_test.exs`

**Modified:**
- `lib/deckex/cards/role_match.ex` — six kinds join `@kinds`
- `lib/deckex/cards/roles.ex` — register `Table`
- `lib/deckex/analysis/finding.ex` — `:mesa` and `:fragility` join the lens guard
- `lib/deckex/analysis/report.ex` — two new sections
- `lib/deckex/analysis.ex` — measure and collect them
- `lib/deckex/analysis/baselines.ex` — `interaction_max`, `table_time_max`, `source`
- `lib/deckex/analysis/interaction.ex` — the too-much finding
- `lib/deckex/optimizations/salt.ex` — the six new tactics
- `lib/deckex/consults.ex` — `model_rank/1`, `changes_deck?/1`
- `lib/deckex/consults/consult.ex` — `below_floor` flag
- `lib/deckex/optimizations.ex` — floor check at launch, `redo_step/3`, budget guard
- `lib/deckex/consults/audit.ex` — the budget guard
- `lib/deckex/consults/briefing.ex` — table-time dial, archetype vocabulary
- `lib/deckex/consults/schemas.ex` — `arquetipo` + `tema` replace `eixo`
- `lib/deckex/consults/vision.ex`, `visions.ex` — same
- `lib/deckex_web/live/*` — the dials, the redo control, the deck value

---

### Task 1: The six roles a table notices

**Files:**
- Create: `lib/deckex/cards/roles/table.ex`, `test/deckex/cards/roles/table_test.exs`
- Modify: `lib/deckex/cards/role_match.ex`, `lib/deckex/cards/roles.ex`
- Fixtures: fetch the cards named in Step 1

**Interfaces:**
- Consumes: `RoleMatch.new/3`, `Card`.
- Produces: `:taxation`, `:theft`, `:hoser`, `:forced_sacrifice`, `:free_spell`, `:chaos` in `RoleMatch.kinds()`; `Deckex.Cards.Roles.Table.classify/1`.

- [ ] **Step 1: Fetch fixtures — one match and one near-miss per role**

```bash
cd /Users/tavano/projects/deckex
for pair in "Rhystic+Study:rhystic_study_x" "Smothering+Tithe:smothering_tithe_x" \
            "Tergrid,+God+of+Fright:tergrid" "Humility:humility" \
            "Grave+Pact:grave_pact" "Force+of+Will:force_of_will" \
            "Warp+World:warp_world"; do
  q="${pair%%:*}"; f="${pair##*:}"
  [ -f "test/support/fixtures/scryfall/$f.json" ] || \
    curl -s "https://api.scryfall.com/cards/named?exact=$q" > "test/support/fixtures/scryfall/$f.json"
  sleep 0.6
done
```

`rhystic_study` and `smothering_tithe` already exist — drop the `_x` suffix and
skip those two if the files are present.

- [ ] **Step 2: Write the failing test**

`test/deckex/cards/roles/table_test.exs`: one test per role asserting the match,
plus these near-misses that must NOT match, because each is the mistake the rule
is written to avoid:

- `sol_ring` matches nothing
- `counterspell` is not `:free_spell` (it has a mana cost like any spell)
- `blasphemous_act` is not `:forced_sacrifice` (it destroys, nobody sacrifices)

- [ ] **Step 3: Run it and watch it fail**

Run: `mix test test/deckex/cards/roles/table_test.exs`
Expected: FAIL — `Deckex.Cards.Roles.Table is not available`.

- [ ] **Step 4: Write the rules**

`lib/deckex/cards/roles/table.ex`. The regexes, each with its exclusion:

```elixir
  # "unless that player pays" / "unless its controller pays" — the pay-or-I-profit
  # pattern. Rhystic Study and Smothering Tithe are top-five saltiest cards and
  # nothing in this engine could see them.
  @taxation ~r/unless (that|its|the) (player|controller|owner)[^.]*pays|whenever an opponent (draws|casts)[^.]*you (may )?(draw|create)/i

  # Taking what is not yours: control of a permanent, or casting from another
  # player's zones. NOT a copy effect — a clone leaves the original alone.
  @theft ~r/gain control of|you may cast .* from (any|an opponent's) (graveyard|hand|library)|exile .* from an opponent's[^.]*you may (play|cast)/i

  # A static that removes a whole category of play rather than a resource.
  @hoser ~r/(players?|opponents?) can't (cast|play|activate|search)|can't be activated|activated abilities can't/i

  # Repeatable edicts. "Destroy" is not sacrifice: regeneration, indestructible
  # and the player's own choice all behave differently.
  @forced_sacrifice ~r/each (opponent|other player) sacrifices/i

  # A spell with a non-mana alternative cost.
  @free_spell ~r/rather than pay this spell's mana cost|without paying its mana cost/i

  # Randomness applied to everyone.
  @chaos ~r/flip a coin|roll a (six-sided )?di[ec]|at random.*(each|all) player|shuffle .* all .* libraries/i
```

Each clause returns `[RoleMatch.new(kind, :high, evidence)]` with a pt-BR
evidence string, in the shape `Deckex.Cards.Roles.Mill` already uses.

- [ ] **Step 5: Register and extend the vocabulary**

`@kinds` in `role_match.ex` gains
`taxation theft hoser forced_sacrifice free_spell chaos`; `Roles.classify/1`'s
module list gains `Table`.

- [ ] **Step 6: Reclassify and verify against the real catalogue**

```bash
mix run -e "IO.puts(Deckex.Cards.reclassify_all!())"
docker exec deckex-db-1 psql -U postgres -d deckex_dev -tAc "select r.kind, count(*) from card_roles r where r.kind in ('taxation','theft','hoser','forced_sacrifice','free_spell','chaos') group by r.kind order by 2 desc"
```

Expected: `taxation` finds Rhystic Study, `free_spell` finds Fierce
Guardianship — both are in the reference deck. If a count is zero, the regex is
wrong; fix it before moving on rather than shipping a rule that sees nothing.

- [ ] **Step 7: Gate and commit**

```bash
mix test >/dev/null 2>&1 && echo SUITE-GREEN && mix lint >/dev/null 2>&1 && echo LINT-GREEN && git add -A && git commit -m "feat: six roles for what a table actually notices

Taxation, theft, rule-warping hosers, forced sacrifice, free spells and
chaos — the categories the salt survey's top 100 is actually made of. The
engine could not see any of them, which is why its idea of an unpleasant
deck stopped at counters and land destruction."
```

---

### Task 2: Salt speaks the new vocabulary

**Files:**
- Modify: `lib/deckex/optimizations/salt.ex`, `test/deckex/optimizations/salt_test.exs`

**Interfaces:**
- Produces: `Salt.tactics/0` returning eleven tactics; `:mill` removed from it.

- [ ] **Step 1: Write the failing test**

Assert `Salt.tactics()` contains `taxation`, `theft`, `hoser`,
`forced_sacrifice`, `free_spell` and `chaos`; that `mill` is **absent**; and
that the existing test "every tactic names a role the engine actually
classifies" still passes.

- [ ] **Step 2: Rewrite `@tactics`**

```elixir
  @tactics [
    %{key: "mass_land_denial", role: :mass_land_denial, label: "destruição de terreno"},
    %{key: "stax", role: :stax, label: "stax / prisão"},
    %{key: "taxation", role: :taxation, label: "taxação (pague ou eu lucro)"},
    %{key: "hoser", role: :hoser, label: "desligar jogadas inteiras"},
    %{key: "theft", role: :theft, label: "roubo"},
    %{key: "forced_sacrifice", role: :forced_sacrifice, label: "sacrifício forçado"},
    %{key: "extra_turn", role: :extra_turn, label: "turnos extras"},
    %{key: "free_spell", role: :free_spell, label: "mágicas de graça"},
    %{key: "chaos", role: :chaos, label: "caos"},
    %{key: "counter", role: :counter, label: "counters"},
    %{key: "graveyard_hate", role: :graveyard_hate, label: "ódio a cemitério"}
  ]
```

Update the `"mesa_tranquila"` preset: avoid `mass_land_denial`, `stax`,
`taxation`, `hoser`, `theft`, `forced_sacrifice`, `extra_turn`; leave
`counter`, `graveyard_hate`, `free_spell` and `chaos` at `tanto_faz`. Add a
comment recording that mill left this list because the survey data does not
support it, and that it remains a role.

- [ ] **Step 3: Run the tests, then gate and commit**

```bash
mix test >/dev/null 2>&1 && echo SUITE-GREEN && mix lint >/dev/null 2>&1 && echo LINT-GREEN && git add -A && git commit -m "feat: the salt dials follow the data, and mill leaves them

Mill was the owner's own suggestion and the survey's top 100 does not
contain it, nor group slug, nor plain discard. What tables resent is
lockout and time theft. Mill stays a role; it stops being a dial."
```

---

### Task 3: Table time, measured

**Files:**
- Create: `lib/deckex/analysis/mesa.ex`, `test/deckex/analysis/mesa_test.exs`
- Modify: `lib/deckex/analysis/finding.ex`, `report.ex`, `analysis.ex`, `baselines.ex`

**Interfaces:**
- Produces: `Mesa.measure(snapshot) :: map()`, `Mesa.findings(snapshot, baselines) :: [Finding.t()]`; `report.mesa`; `:mesa` accepted by `Finding.new/6`; `Baselines.table_time_max`.

- [ ] **Step 1: Write the failing test**

A deck holding two `extra_turn` cards and a `taxation` static reports a
`table_time` count of 3 and names all three cards. A deck with none reports 0
and fires no finding.

- [ ] **Step 2: Implement**

```elixir
defmodule Deckex.Analysis.Mesa do
  @moduledoc """
  How much of other people's game this deck spends.

  The research is unusually consistent on this: what ruins a Commander game is
  not power, it is table time somebody else does not get to play. Extra turns,
  untap denial and taxing statics all take the same thing, and no lens here
  measured any of it.

  This counts and names. It does not score — a number out of ten would be the
  power level this project exists to not build.
  """
  @costly_roles [:extra_turn, :stax, :taxation, :hoser, :forced_sacrifice, :theft]
  ...
end
```

`measure/1` returns
`%{table_time: count, by_role: %{role => count}, cards: [names]}`.
`findings/2` fires one `:warning` at `table_time > baselines.table_time_max`
(default 4), titled "O deck toma tempo da mesa", naming the cards.

Add `:mesa` to `Finding.new/6`'s guard list and to `@type lens`. Add
`table_time_max: 4` to `Baselines`. Add `mesa: Mesa.measure(snapshot)` to
`Report` and `Mesa` to the findings module list in `Analysis`.

- [ ] **Step 3: Run, gate, commit**

Commit message: `feat: table time is a measurement now, not a vibe`.

---

### Task 4: Where this deck dies

**Files:**
- Create: `lib/deckex/analysis/fragility.ex`, `test/deckex/analysis/fragility_test.exs`
- Modify: `finding.ex`, `report.ex`, `analysis.ex`

**Interfaces:**
- Produces: `Fragility.measure/1`, `Fragility.findings/2`; `report.fragility`; `:fragility` accepted by `Finding.new/6`.

- [ ] **Step 1: Write the failing test**

- A creature-heavy deck whose ramp sits on creatures, with one board wipe and no
  protection, fires `fragility.board_wipe`.
- A deck with ten graveyard-dependent cards and heavy recursion fires
  `fragility.graveyard_hate`.
- A deck of expensive sorceries fires neither.

- [ ] **Step 2: Implement the three fault lines**

```elixir
  # Board-wipe fragility: how much of the deck's engine is standing on the
  # battlefield. A deck whose MANA comes from creatures loses its mana to a
  # wipe, which is why ramp-on-creatures is counted separately from creature
  # count — the reference deck is exactly this shape.
  defp board_wipe_exposure(snapshot) do ...

  # Graveyard fragility: cards that need the yard to function. `recursion`
  # plus oracle text that casts or returns from a graveyard.
  defp graveyard_exposure(snapshot) do ...

  # Tax fragility: a deck that must cast several spells per turn dies to
  # Rule of Law. Low average CMC plus a high count of cheap spells.
  defp tax_exposure(snapshot) do ...
```

Each returns `{count, card_names}`; `findings/2` turns an exposure over its
threshold into a `:warning` naming the cards. Thresholds live in `Baselines`.

- [ ] **Step 3: Verify against the reference deck**

```bash
mix run -e '
{:ok, deck} = Deckex.Decks.fetch_deck("019ffca7-66ca-7bbf-aeda-6804f7ebe7fe")
report = deck |> Deckex.Decks.snapshot() |> Deckex.Analysis.report()
report.findings |> Enum.filter(&(&1.lens == :fragility)) |> Enum.each(&IO.puts(&1.title <> " — " <> &1.detail))
'
```

Expected: the board-wipe fault line fires (17 creatures, mana on creatures, one
wipe) and the graveyard one fires (10 dependent cards). If neither does, the
thresholds are wrong.

- [ ] **Step 4: Gate and commit**

Commit message: `feat: the lens that says where this deck dies`.

---

### Task 5: Interaction as a band, baselines with a source

**Files:**
- Modify: `lib/deckex/analysis/baselines.ex`, `interaction.ex`, `lib/deckex_web/live/settings_live.ex`
- Test: `test/deckex/analysis/interaction_test.exs`

- [ ] **Step 1: Write the failing test** — a deck with 18 interaction pieces
  fires `interaction.too_much`; one with 9 fires nothing.

- [ ] **Step 2: Add `interaction_max: 14` and `source:` to `Baselines`**

```elixir
  @doc """
  The shipped defaults, and where they come from.

  Numbers presented without provenance read as facts. These follow the Command
  Zone's 2025 revision (Episode 658) — 10 ramp, 12 card advantage, 12 targeted
  disruption, 6 mass disruption on 38 lands — adapted where this engine counts
  differently. The owner edits every one of them in Ajustes.
  """
```

Raise `draw_target` to 10 and `interaction_target` to 10, and record in the
moduledoc that the previous 8/8 were unsourced and behind the published
revision. Show `source` in the Ajustes panel.

- [ ] **Step 3: The too-much finding**

`:warning`, code `interaction.too_much`, wording that says the documented
failure: if nobody can keep a permanent on the board, nobody gets to play.

- [ ] **Step 4: Gate and commit** — `feat: interaction is a band, and the baselines say who wrote them`.

---

### Task 6: The model floor

**Files:**
- Modify: `lib/deckex/consults.ex`, `lib/deckex/optimizations.ex`, `lib/deckex/settings.ex`, `lib/deckex_web/live/deck_live.ex`, `optimizations_live.ex`
- Create: `test/deckex/consults/model_floor_test.exs`

**Interfaces:**
- Produces: `Consults.model_rank(String.t()) :: integer()`; `Consults.changes_deck?(atom()) :: boolean()`; `Consults.below_floor?(String.t()) :: boolean()`; `Settings.model_floor/0`.

- [ ] **Step 1: Write the failing test**

- `model_rank("fable") > model_rank("opus") > model_rank("sonnet") > model_rank("haiku")`, and an unknown model ranks lowest.
- `changes_deck?(:full)` is true; `changes_deck?(:scout)` and `changes_deck?(:bracket)` are false; `changes_deck?(:visao)` is **true**.
- `Optimizations.start/2` with a contract naming `sonnet` returns `{:error, %Error{}}` whose message names the floor.
- The same contract naming `fable` starts.

- [ ] **Step 2: Implement**

```elixir
  # Ordered by capability, not by price. An unknown alias ranks lowest so a
  # typo can never accidentally clear the floor.
  @model_rank %{"fable" => 4, "opus" => 3, "sonnet" => 2, "haiku" => 1}

  @spec model_rank(String.t()) :: non_neg_integer()
  def model_rank(model), do: Map.get(@model_rank, model, 0)

  # The floor is about what an answer CHANGES, not what it costs. A lens that
  # only reads may use any model; one that proposes cutting a card from a real
  # deck may not.
  @reads_only [:scout, :bracket]

  @spec changes_deck?(atom()) :: boolean()
  def changes_deck?(lens), do: lens not in @reads_only
```

`Settings.model_floor/0` reads `:model_floor`, defaulting to `"fable"`.
`Optimizations.start/3` refuses before the transaction when
`changes_deck?` applies and `model_rank(contract["model"]) < model_rank(floor)`.

- [ ] **Step 3: Mark, do not block, on the deck page**

A consult whose lens changes the deck and whose model is below the floor renders
a note above its suggestion table: *"Resposta de um modelo abaixo do seu piso —
confira antes de aplicar."* Derived at render from `consult.model` and
`consult.lens`; nothing is stored.

- [ ] **Step 4: Nudge the read-only lenses down**

The dossier and bracket controls default to the cheapest model with a line
saying why, rather than the global default.

- [ ] **Step 5: Gate and commit** — `feat: the model floor, drawn by what an answer changes`.

---

### Task 7: Redoing a stage

**Files:**
- Modify: `lib/deckex/optimizations.ex`, `lib/deckex_web/live/optimization_live.ex`
- Create: `test/deckex/optimizations/redo_test.exs`

**Interfaces:**
- Produces: `Optimizations.redo_step(optimization, step_id, model) :: {:ok, Optimization.t()} | {:error, Error.t()}`.

- [ ] **Step 1: Write the failing test**

A scripted three-stage run: redo stage 2 with another model, then assert stage 3
is back to `:pending` with `applied`, `rejected`, `consult_id` and `list_before`
cleared; the run is `:running`; stage 2 has a NEW consult carrying the new
model; the previous consult is still queryable by `optimization_id`; and a redo
on a finished run clears `outcome` and `finished_at`.

- [ ] **Step 2: Implement**

```elixir
  @doc """
  Recomputes one stage with a different model, rewinding everything after it.

  Stage N's answer is the input to N+1, so recomputing N and keeping the rest
  would leave the sandbox describing a history that never happened. The stages
  after N return to `:pending`; their `list_before` is derived and costs
  nothing to rebuild. The discarded consults stay attached to the run — reading
  what the cheaper model said beside the better one is most of the point.
  """
  @spec redo_step(Optimization.t(), String.t(), String.t()) ::
          {:ok, Optimization.t()} | {:error, Error.t()}
```

Guard: refuse with a reason when the step is not found, or when the run is
`:running` with a consult in flight (redoing under a live stage would race it).

- [ ] **Step 3: The control**

On every done stage: a model select and a "refazer" button whose `data-confirm`
states how many later stages will be discarded.

- [ ] **Step 4: Gate and commit** — `feat: redo a stage with a better model, and rewind what followed`.

---

### Task 8: What a run may spend, and what a deck is worth

**Files:**
- Modify: `lib/deckex/consults/audit.ex`, `lib/deckex/optimizations.ex`, `lib/deckex_web/live/optimizations_live.ex`, `deck_live.ex`
- Test: `test/deckex/consults/audit_test.exs`

- [ ] **Step 1: Write the failing test** — with `orcamento_total` at R$ 100 and
  R$ 90 already applied, an add of R$ 20 is refused with the running total in
  the reason; an add of R$ 5 passes.

- [ ] **Step 2: Implement the guard** in the same shape as the ceiling guard,
  taking `spent:` in the audit opts and `orcamento_total` from the contract.

- [ ] **Step 3: The deck's total value** on the deck page, summed from the
  catalogue, beside the bracket. A player who says their decks reach R$ 8–10
  mil has no way to see where one sits today.

- [ ] **Step 4: Gate and commit** — `feat: a budget for the run, a price for the deck`.

---

### Task 9: Archetype and theme replace the invented axis

**Files:**
- Modify: `lib/deckex/consults/schemas.ex`, `vision.ex`, `visions.ex`, `briefing.ex`, `lib/deckex_web/live/optimization_live.ex`
- Test: `test/deckex/consults/visions_test.exs`

- [ ] **Step 1: Write the failing test** — a vision answer carrying
  `arquetipo` and `tema` parses into those fields; the three visions must differ
  in `arquetipo`.

- [ ] **Step 2: Replace `eixo`** in the schema with `arquetipo` (enum:
  `aggro midrange controle combo stax ramp politica grupo`) and `tema` (free
  string). The briefing lists the community theme names as vocabulary to choose
  from, never as an enum the engine validates — the list grows every set.

- [ ] **Step 3: Render both** on the vision card, as two chips.

- [ ] **Step 4: Gate and commit** — `feat: visions speak archetype and theme, not an axis we invented`.

---

### Task 10: The whole thing, on a deck that is not Iroh

- [ ] **Step 1** Extend `reimagine_regression_test.exs`: the run's contract
  carries a table-time dial and a total budget, and the reconstruction has an
  add refused by each.
- [ ] **Step 2** Full `mix lint` and `mix test`.
- [ ] **Step 3** Browser proof: the deck page shows the two new finding groups
  and the deck's value; the launcher shows the new dials; a done stage shows its
  redo control. Screenshot each.
- [ ] **Step 4** Write the new laws into `AGENTS.md`: the model floor, the
  rewind rule, and that EDHREC's data is off limits.
- [ ] **Step 5** Gate and commit.

---

## Self-Review

**Spec coverage:** mesa §1 roles → T1; §1 mill → T2; §2 table time → T3;
§3 fragility → T4; §4 interaction band and sourced baselines → T5; §5 archetype
→ T9. confiança §1 floor → T6; §2 redo → T7; §3 budget and deck value → T8.
Regression → T10.

**Placeholders:** the rule regexes, the model rank map and the lens split are
given literally. T3/T4's `measure` bodies are specified by their return shape
and their thresholds rather than line by line, because both follow the existing
lens modules exactly and the implementer will read one first.

**Type consistency:** `Salt.tactics/0`'s `role` keys in T2 are the atoms T1 adds
to `RoleMatch.kinds()`. `Mesa`'s `@costly_roles` and `Fragility`'s exposures
consume those same atoms. `model_rank/1` and `changes_deck?/1` from T6 are used
by T7's redo control and T6's launch guard.
