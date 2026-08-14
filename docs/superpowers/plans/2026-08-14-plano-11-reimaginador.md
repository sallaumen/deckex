# O Reimaginador — Implementation Plan (Plano 11)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `:reimagine` mode to the Otimizador that proposes three
directions for the deck, lets the owner pick one while the run waits, enforces a
per-tactic "salt" contract, and allows a commander swap inside the same colour
identity.

**Architecture:** A mode on the existing `optimizations` table, not a new
subsystem. Sandbox, audit, timeline, feedback, fork, pause/resume and the
convergence rule are reused unchanged. The mode selects a recipe, adds fields to
the frozen contract, and adds two engine guards (salt, commander validity).

**Tech Stack:** Elixir 1.19.5 / OTP 27, Phoenix 1.8, LiveView 1.2, Ecto,
PostgreSQL 16 (Docker, host port 5435), Oban (queue `:ai`), Mox, ExMachina.

**Spec:** [`docs/superpowers/specs/2026-08-14-reimaginador-design.md`](../specs/2026-08-14-reimaginador-design.md).
Read it first — this plan implements it and does not restate its reasoning.

## Global Constraints

- **Code in English, UI in pt-BR, card names never translated.** (AGENTS.md)
- **Errors as data:** `{:ok, _}` / `{:error, %Deckex.Error{}}`. No exceptions for
  expected failures.
- **Triad per context:** context module, schema, `*Query`. No `Repo` calls in
  LiveViews.
- **Every card write takes its locks in `oracle_id` order.** Seed tests through
  `Deckex.CatalogueFixture`, **once per test, in a single call**.
- **JSONB payloads are string-keyed everywhere** — contract, recipe, applied,
  rejected, feedback, salt, visao.
- **An informational note is not a problem.** Anything added to an audit
  `problems` list rejects the suggestion and excludes it from the simulation.
- **The model never states a price and never guesses legality.** The app prices
  cards from the catalogue; the engine checks legality.
- **The engine reports a bracket FLOOR, never a bracket. No 1–10 power level.**
- **Building a page never reaches the network.** Fetching happens in workers.
- **Quality gate before every commit:** `mix lint` (format, deps.unlock, credo
  --strict, sobelow, dialyzer) **and** `mix test`, both green. **Never pipe
  `mix test` into another command** — the pipe eats the exit code. Use:
  ```bash
  mix test >/dev/null 2>&1 && echo SUITE-GREEN && mix lint >/dev/null 2>&1 && echo LINT-GREEN && git commit ...
  ```
- **Commit directly to `main`.** No PR, no remote.
- **Nothing may be tuned to the reference deck** (Iroh das Lontra). Regressions
  run on synthetic decks.

## File Structure

**Created:**
- `priv/repo/migrations/20260814230000_add_mode_to_optimizations.exs` — the mode column
- `lib/deckex/cards/roles/mill.ex` — the `:mill` rule, one responsibility
- `lib/deckex/optimizations/salt.ex` — salt vocabulary, presets, role mapping, contradiction check
- `lib/deckex/consults/vision.ex` — one proposed direction, priced and validated
- `lib/deckex/consults/visions.ex` — parses a `:visao` answer into `Vision` structs
- `test/deckex/cards/roles/mill_test.exs`
- `test/deckex/optimizations/salt_test.exs`
- `test/deckex/consults/visions_test.exs`
- `test/deckex/optimizations/reimagine_test.exs` — lifecycle: awaiting_choice, choose, re-ask
- `test/deckex/optimizations/reimagine_regression_test.exs` — end to end
- `test/support/fixtures/scryfall/brain_freeze.json`, `stitchers_supplier.json`

**Modified:**
- `lib/deckex/cards/role_match.ex` — `:mill` joins `@kinds`
- `lib/deckex/cards/roles.ex` — register the Mill module
- `lib/deckex/cards.ex` — `reclassify_all!/0`
- `lib/deckex/optimizations/optimization.ex` — `mode`, `:awaiting_choice`
- `lib/deckex/optimizations/optimization_query.ex` — `running_for_deck` counts awaiting
- `lib/deckex/optimizations.ex` — recipe per mode, choose/ask_again, current_commanders, salt into the audit
- `lib/deckex/consults/audit.ex` — the salt guard
- `lib/deckex/consults/briefing.ex` — salt block, vision task, reconstruction, fidelity target
- `lib/deckex/consults/consult.ex` — `:visao` lens
- `lib/deckex/consults/schemas.ex` — `for_lens(:visao)`
- `lib/deckex/consults.ex` — catalogue vision card names
- `lib/deckex/optimizations/optimization_step.ex` — `:reconstruction` kind
- `lib/deckex_web/live/optimizations_live.ex` — mode toggle, salt controls, contradiction refusal
- `lib/deckex_web/live/optimization_live.ex` — vision cards, choose, ask again
- `lib/deckex_web/live/deck_live.ex` — awaiting-choice wording
- `test/support/factory.ex` — mode on the optimization factory

---

### Task 1: `:mill` joins the role vocabulary

**Files:**
- Create: `lib/deckex/cards/roles/mill.ex`, `test/deckex/cards/roles/mill_test.exs`
- Create: `test/support/fixtures/scryfall/brain_freeze.json`, `test/support/fixtures/scryfall/stitchers_supplier.json`
- Modify: `lib/deckex/cards/role_match.ex`, `lib/deckex/cards/roles.ex`, `lib/deckex/cards.ex`

**Interfaces:**
- Consumes: `Deckex.Cards.RoleMatch.new/3`, `Deckex.Cards.Card`.
- Produces: `:mill` in `RoleMatch.kinds()`; `Deckex.Cards.Roles.Mill.classify/1 :: [RoleMatch.t()]`; `Deckex.Cards.reclassify_all!() :: non_neg_integer()`.

- [ ] **Step 1: Fetch the two fixtures**

```bash
curl -s 'https://api.scryfall.com/cards/named?exact=Brain+Freeze' > test/support/fixtures/scryfall/brain_freeze.json
sleep 1
curl -s "https://api.scryfall.com/cards/named?exact=Stitcher's+Supplier" > test/support/fixtures/scryfall/stitchers_supplier.json
```

Verified oracle text (2026-08-14):
- Brain Freeze — `Target player mills three cards.` plus Storm reminder text.
- Stitcher's Supplier — `When this creature enters or dies, mill three cards.`
  Modern templating omits the subject for **self**-mill, which is exactly what
  makes the rule below separable.

- [ ] **Step 2: Write the failing test**

`test/deckex/cards/roles/mill_test.exs`:

```elixir
defmodule Deckex.Cards.Roles.MillTest do
  use ExUnit.Case, async: true

  alias Deckex.Cards.Roles.Mill
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.ScryfallFixture

  defp card(name) do
    struct!(Deckex.Cards.Card, ScryfallMapper.to_attrs(ScryfallFixture.load!(name)))
  end

  test "milling an opponent is the mill role" do
    assert [%{kind: :mill}] = Mill.classify(card("brain_freeze"))
  end

  test "milling yourself is not — it is a build-around, not a tactic aimed at anyone" do
    assert [] == Mill.classify(card("stitchers_supplier"))
  end

  test "a card with no mill text matches nothing" do
    assert [] == Mill.classify(card("sol_ring"))
  end
end
```

- [ ] **Step 3: Run it and watch it fail**

Run: `mix test test/deckex/cards/roles/mill_test.exs`
Expected: FAIL — `Deckex.Cards.Roles.Mill is not available`.

- [ ] **Step 4: Write the rule**

`lib/deckex/cards/roles/mill.ex`:

```elixir
defmodule Deckex.Cards.Roles.Mill do
  @moduledoc """
  The `:mill` rule: putting cards from an **opponent's** library into their
  graveyard.

  Self-mill is deliberately excluded. A deck that mills itself is a
  graveyard build-around — the reference deck is one — while milling an
  opponent is a tactic aimed at a person, which is why the owner may want to
  avoid it. Counting the two together would let "evitar mill" cut the engine
  out of a graveyard deck.

  The distinction is free because of templating: modern oracle text names the
  victim for targeted mill (`Target player mills three cards`) and omits the
  subject for self-mill (`mill three cards`). The catalogue always stores
  current oracle text, so pre-2021 wording never reaches this rule.
  """

  alias Deckex.Cards.Card
  alias Deckex.Cards.RoleMatch

  @opponent_mill ~r/(target player|target opponent|each opponent|each player|opponents?) mills?/i

  @spec classify(Card.t()) :: [RoleMatch.t()]
  def classify(%Card{} = card) do
    body = card.oracle_text || ""

    if body =~ @opponent_mill do
      [RoleMatch.new(:mill, :high, "moe biblioteca alheia")]
    else
      []
    end
  end
end
```

- [ ] **Step 5: Add `:mill` to the vocabulary and register the module**

In `lib/deckex/cards/role_match.ex`, extend `@kinds`:

```elixir
  @kinds ~w(ramp ritual cost_reduction fixing counter spot_removal board_wipe
            protection draw tutor recursion wincon graveyard_hate stax
            mass_land_denial extra_turn mill)a
```

In `lib/deckex/cards/roles.ex`, add the alias and the module to the list:

```elixir
  alias Deckex.Cards.Roles.Mill
```

```elixir
    [Mana, Interaction, Value, Bracket, Mill]
    |> Enum.flat_map(& &1.classify(card))
    |> best_per_kind()
```

- [ ] **Step 6: Run the test — it passes**

Run: `mix test test/deckex/cards/roles/mill_test.exs`
Expected: 3 tests, 0 failures.

- [ ] **Step 7: Add the reclassification pass**

A new role means every card already in the catalogue was classified before the
rule existed. Without this, "evitar mill" would look enforced and silently miss
every card already stored.

In `lib/deckex/cards.ex`, after `classify_card/1`:

```elixir
  @doc """
  Reclassifies the whole catalogue against today's rules, returning how many
  cards were touched.

  Adding a role to the vocabulary makes every previously-stored card stale: it
  was classified when the rule did not exist. Run this once when a rule ships.
  Ordered by `oracle_id` — the same deadlock law every other card write obeys.
  """
  @spec reclassify_all!() :: non_neg_integer()
  def reclassify_all! do
    Card
    |> order_by(asc: :oracle_id)
    |> Repo.all()
    |> Enum.map(&classify_card/1)
    |> length()
  end
```

Add `import Ecto.Query, only: [order_by: 2]` to the module's imports if it is
not already imported (check the top of the file first — do not duplicate it).

- [ ] **Step 8: Run the reclassification against the dev database**

```bash
mix run -e "IO.puts(Deckex.Cards.reclassify_all!())"
```

Expected: a number equal to the catalogue's card count, and no error. Verify a
milling card picked up the role:

```bash
docker exec deckex-db-1 psql -U postgres -d deckex_dev -tAc "select c.name from cards c join card_roles r on r.card_id = c.id where r.kind = 'mill' order by c.name limit 5"
```

Expected: milling cards listed (empty is a valid answer only if the catalogue
holds none — check with a card you know).

- [ ] **Step 9: Gate and commit**

```bash
mix test >/dev/null 2>&1 && echo SUITE-GREEN && mix lint >/dev/null 2>&1 && echo LINT-GREEN && git add -A && git commit -m "feat: mill joins the role vocabulary, opponents only

Self-mill is a graveyard build-around and milling an opponent is a tactic
aimed at a person; only the second is something an owner asks to avoid.
Templating separates them for free — targeted mill names its victim, self
mill omits the subject.

Adding a role makes the stored catalogue stale, so reclassify_all/0 ships
with it, ordered by oracle_id like every other card write."
```

---

### Task 2: The mode and the `:awaiting_choice` status

**Files:**
- Create: `priv/repo/migrations/20260814230000_add_mode_to_optimizations.exs`
- Modify: `lib/deckex/optimizations/optimization.ex`, `lib/deckex/optimizations/optimization_query.ex`, `test/support/factory.ex`
- Test: `test/deckex/optimizations/optimization_test.exs`

**Interfaces:**
- Consumes: `Deckex.Optimizations.Optimization.changeset/2`.
- Produces: `optimization.mode :: :refine | :reimagine` (default `:refine`); status value `:awaiting_choice`; `OptimizationQuery.running_for_deck/1` treats `:awaiting_choice` as live.

- [ ] **Step 1: Write the migration**

```elixir
defmodule Deckex.Repo.Migrations.AddModeToOptimizations do
  use Ecto.Migration

  def change do
    alter table(:optimizations) do
      add :mode, :string, null: false, default: "refine"
    end
  end
end
```

- [ ] **Step 2: Run it**

Run: `mix ecto.migrate`
Expected: `altered table optimizations`.

- [ ] **Step 3: Write the failing test**

Append to `test/deckex/optimizations/optimization_test.exs` (inside the existing
top-level `describe` or as a new one — match the file's existing structure):

```elixir
  describe "the mode" do
    test "defaults to refine" do
      assert insert(:optimization).mode == :refine
    end

    test "accepts reimagine" do
      assert insert(:optimization, mode: :reimagine).mode == :reimagine
    end

    test "a run awaiting the owner's choice still blocks a second run" do
      deck = insert(:deck)
      insert(:optimization, deck: deck, status: :awaiting_choice)

      assert Deckex.Optimizations.running_for_deck(deck.id)
    end
  end
```

- [ ] **Step 4: Run it and watch it fail**

Run: `mix test test/deckex/optimizations/optimization_test.exs`
Expected: FAIL — unknown field `:mode`.

- [ ] **Step 5: Extend the schema**

In `lib/deckex/optimizations/optimization.ex`:

```elixir
  @fields ~w(deck_id mode status outcome contract recipe list_original commanders finished_at)a
  @required ~w(deck_id mode status contract recipe list_original commanders)a
```

```elixir
    field :mode, Ecto.Enum, values: [:refine, :reimagine], default: :refine

    field :status, Ecto.Enum,
      values: [:running, :awaiting_choice, :paused, :done, :failed, :cancelled]
```

In `lib/deckex/optimizations/optimization_query.ex`, `running_for_deck/1`:

```elixir
        where: o.deck_id == ^deck_id and o.status in [:running, :awaiting_choice, :paused],
```

In `test/support/factory.ex`, add `mode: :refine` to `optimization_factory`.

- [ ] **Step 6: Run the tests**

Run: `mix test test/deckex/optimizations/`
Expected: all pass.

- [ ] **Step 7: Gate and commit**

```bash
mix test >/dev/null 2>&1 && echo SUITE-GREEN && mix lint >/dev/null 2>&1 && echo LINT-GREEN && git add -A && git commit -m "feat: optimizations have a mode, and a status for waiting on the owner

awaiting_choice is its own status and not a reuse of paused: 'you stopped
it' and 'it is waiting for you' are different sentences on the screen, and
a run waiting on the owner must still block a second one."
```

---

### Task 3: Salt — the vocabulary, the guard, the contradiction check

**Files:**
- Create: `lib/deckex/optimizations/salt.ex`, `test/deckex/optimizations/salt_test.exs`
- Modify: `lib/deckex/consults/audit.ex`, `lib/deckex/optimizations.ex`, `lib/deckex/consults/briefing.ex`
- Test: `test/deckex/consults/audit_test.exs`

**Interfaces:**
- Consumes: `Deckex.Consults.Audit.run/6` opts, `Deckex.Cards.RoleMatch.kinds/0`.
- Produces:
  - `Salt.tactics() :: [%{key: String.t(), role: atom(), label: String.t()}]`
  - `Salt.avoided(salt_map) :: %{atom() => String.t()}` (role → pt-BR label)
  - `Salt.wanted(salt_map) :: [String.t()]` (pt-BR labels)
  - `Salt.preset(String.t()) :: map()` for `"mesa_tranquila" | "sem_freio"`
  - `Salt.contradiction(contract) :: String.t() | nil`
  - `Audit.run/6` accepts `avoid: %{atom() => String.t()}` in opts.

- [ ] **Step 1: Write the failing test**

`test/deckex/optimizations/salt_test.exs`:

```elixir
defmodule Deckex.Optimizations.SaltTest do
  use ExUnit.Case, async: true

  alias Deckex.Optimizations.Salt

  test "every tactic names a role the engine actually classifies" do
    kinds = Deckex.Cards.RoleMatch.kinds()

    assert Enum.all?(Salt.tactics(), &(&1.role in kinds))
  end

  test "avoided roles come back keyed by role, carrying the label for the refusal" do
    assert %{counter: "counters"} = Salt.avoided(%{"counter" => "evitar"})
  end

  test "wanted and indifferent tactics are not avoided" do
    assert Salt.avoided(%{"counter" => "quero", "stax" => "tanto_faz"}) == %{}
  end

  test "the calm-table preset avoids the tactics that make people quit" do
    preset = Salt.preset("mesa_tranquila")

    assert preset["stax"] == "evitar"
    assert preset["mass_land_denial"] == "evitar"
    assert preset["extra_turn"] == "evitar"
    assert preset["mill"] == "evitar"
  end

  test "no-brakes avoids nothing" do
    assert Salt.avoided(Salt.preset("sem_freio")) == %{}
  end

  test "wanting land denial under bracket 3 is a contract that contradicts itself" do
    contract = %{"bracket_max" => 3, "salt" => %{"mass_land_denial" => "quero"}}

    assert Salt.contradiction(contract) =~ "Bracket 4"
  end

  test "the same wish is fine at bracket 4" do
    contract = %{"bracket_max" => 4, "salt" => %{"mass_land_denial" => "quero"}}

    assert Salt.contradiction(contract) == nil
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `mix test test/deckex/optimizations/salt_test.exs`
Expected: FAIL — `Deckex.Optimizations.Salt is not available`.

- [ ] **Step 3: Write the module**

`lib/deckex/optimizations/salt.ex`:

```elixir
defmodule Deckex.Optimizations.Salt do
  @moduledoc """
  The tactics an owner may ask a run to avoid, and the roles that detect them.

  "Salt" is table slang for the plays that make people stop enjoying the game.
  It is a matter of taste, not of power, which is why it is a per-run contract
  field and never a default: the engine has no opinion about whether counters
  are rude.

  Only `evitar` is enforceable. The audit refuses an add carrying an avoided
  role, exactly like the price ceiling. `quero` goes into the briefing as an
  invitation — no engine can force a model to have an idea, and pretending
  otherwise would be the same overreach as inventing a price.
  """

  @tactics [
    %{key: "counter", role: :counter, label: "counters"},
    %{key: "stax", role: :stax, label: "stax / prisão"},
    %{key: "mass_land_denial", role: :mass_land_denial, label: "destruição de terreno"},
    %{key: "extra_turn", role: :extra_turn, label: "turnos extras"},
    %{key: "graveyard_hate", role: :graveyard_hate, label: "ódio a cemitério"},
    %{key: "mill", role: :mill, label: "mill"}
  ]

  # The two tactics the bracket engine treats as bracket-4 markers. Wanting
  # either under a lower cap is a contract at war with itself.
  @bracket_four ~w(mass_land_denial extra_turn)

  @doc "Every tactic the owner can rule on, in display order."
  @spec tactics() :: [%{key: String.t(), role: atom(), label: String.t()}]
  def tactics, do: @tactics

  @doc "The roles set to `evitar`, keyed by role, carrying the pt-BR label."
  @spec avoided(map() | nil) :: %{atom() => String.t()}
  def avoided(nil), do: %{}

  def avoided(salt) do
    @tactics
    |> Enum.filter(&(Map.get(salt, &1.key) == "evitar"))
    |> Map.new(&{&1.role, &1.label})
  end

  @doc "The pt-BR labels the owner actively asked for."
  @spec wanted(map() | nil) :: [String.t()]
  def wanted(nil), do: []

  def wanted(salt) do
    @tactics |> Enum.filter(&(Map.get(salt, &1.key) == "quero")) |> Enum.map(& &1.label)
  end

  @doc "A named preset, as a full salt map."
  @spec preset(String.t()) :: map()
  def preset("mesa_tranquila") do
    Map.new(@tactics, fn tactic ->
      {tactic.key, if(tactic.key in ["counter", "graveyard_hate"], do: "tanto_faz", else: "evitar")}
    end)
  end

  def preset("sem_freio"), do: Map.new(@tactics, &{&1.key, "tanto_faz"})

  @doc """
  The reason this contract cannot be honoured, or nil.

  Caught at launch rather than mid-run: every such add would be rejected by
  the bracket guard anyway, one paid consult at a time.
  """
  @spec contradiction(map()) :: String.t() | nil
  def contradiction(%{"bracket_max" => max, "salt" => salt}) when is_integer(max) and max <= 3 do
    wanted =
      @tactics
      |> Enum.filter(&(&1.key in @bracket_four and Map.get(salt || %{}, &1.key) == "quero"))
      |> Enum.map(& &1.label)

    if wanted != [] do
      "Você pediu #{Enum.join(wanted, " e ")}, e isso leva o deck ao Bracket 4 — " <>
        "acima do teto de Bracket #{max} que você escolheu. Suba o bracket ou tire o pedido."
    end
  end

  def contradiction(_contract), do: nil
end
```

- [ ] **Step 4: Run the test — it passes**

Run: `mix test test/deckex/optimizations/salt_test.exs`
Expected: 7 tests, 0 failures.

- [ ] **Step 5: Write the failing audit test**

Append to `test/deckex/consults/audit_test.exs`, inside the describe block that
already covers the pipeline guards (search for `"já entrou e saiu"` to find it):

```elixir
    test "an add carrying a tactic the owner avoids is refused", %{snapshot: snapshot} do
      %{"counterspell" => counterspell} = CatalogueFixture.seed_map!(~w(counterspell))
      Cards.classify_card(counterspell)
      roles = Cards.roles_by_card_ids([counterspell.id])

      audit =
        Audit.run(
          snapshot,
          [resolved_add("Counterspell")],
          roles,
          Settings.baselines(),
          %{card: nil, land: nil},
          avoid: %{counter: "counters"}
        )

      assert [problem] = audit.problems[{:add, "Counterspell"}]
      assert problem =~ "evitar counters"
    end
```

Reuse whatever helper the file already has for building a resolved add — read
the top of `audit_test.exs` and match it; do not invent a second helper.

- [ ] **Step 6: Run it and watch it fail**

Run: `mix test test/deckex/consults/audit_test.exs`
Expected: FAIL — no problem recorded for the add.

- [ ] **Step 7: Add the guard**

In `lib/deckex/consults/audit.ex`, extend `pipeline_opts/1`:

```elixir
      bracket_max: Keyword.get(opts, :bracket_max),
      avoid: Keyword.get(opts, :avoid, %{})
```

Add the guard beside the other pipeline guards:

```elixir
  # Taste, not power: the owner said they do not want this kind of card at
  # their table, and inside a pipeline nobody is there to click "no".
  defp salt_problem(entry_roles, %{avoid: avoid}) do
    case Enum.find(avoid, fn {role, _label} -> role in entry_roles end) do
      {_role, label} -> "você marcou evitar #{label} nesta rodada"
      nil -> nil
    end
  end
```

Add it to the `:add` problems list, after `contract_bracket_problem`:

```elixir
        contract_bracket_problem(card, entry_roles, pipeline, snapshot),
        salt_problem(entry_roles, pipeline),
        flip_flop_problem(pipeline, suggestion.name)
```

- [ ] **Step 8: Pass the contract's salt into the audit**

In `lib/deckex/optimizations.ex`, in `judge/4`, add `avoid:` to the `Audit.run`
opts list, next to `bracket_max:`:

```elixir
        avoid: Salt.avoided(optimization.contract["salt"]),
```

Add `alias Deckex.Optimizations.Salt` to the module's aliases (alphabetical
order, after `OptimizationStep`).

- [ ] **Step 9: Put salt in the briefing**

In `lib/deckex/consults/briefing.ex`, inside `optimization_block/1`, add a line
after the ceilings line:

```elixir
    #{salt_line(contract["salt"])}#{keep_line(contract["keep"])}#{notes_line(contract["notes"])}
```

And the helper, beside `keep_line/1`:

```elixir
  defp salt_line(nil), do: ""

  defp salt_line(salt) do
    avoided = salt |> Salt.avoided() |> Map.values()
    wanted = Salt.wanted(salt)

    [
      avoided != [] &&
        "- Do NOT propose: #{Enum.join(avoided, ", ")}. The engine rejects these adds.\n",
      wanted != [] && "- The owner actively wants: #{Enum.join(wanted, ", ")}.\n"
    ]
    |> Enum.filter(& &1)
    |> Enum.join()
  end
```

Add `alias Deckex.Optimizations.Salt` to the briefing's aliases.

- [ ] **Step 10: Run the tests**

Run: `mix test test/deckex/consults/ test/deckex/optimizations/`
Expected: all pass.

- [ ] **Step 11: Gate and commit**

```bash
mix test >/dev/null 2>&1 && echo SUITE-GREEN && mix lint >/dev/null 2>&1 && echo LINT-GREEN && git add -A && git commit -m "feat: salt is a rule the engine applies, not a wish in a prompt

Six tactics, each avoided/indifferent/wanted. Avoided is enforced by the
audit exactly like a price ceiling, with the reason in pt-BR on the
timeline. Wanted is an invitation — no engine forces a model to have an
idea. Asking for land denial under a bracket-3 cap is a contract at war
with itself, and the check for that belongs at launch, before it costs a
consult per rejected add."
```

---

### Task 4: The `:visao` lens and its answer

**Files:**
- Create: `lib/deckex/consults/vision.ex`, `lib/deckex/consults/visions.ex`, `test/deckex/consults/visions_test.exs`
- Modify: `lib/deckex/consults/consult.ex`, `lib/deckex/consults/schemas.ex`, `lib/deckex/consults.ex`, `lib/deckex/consults/briefing.ex`

**Interfaces:**
- Consumes: `Deckex.Cards.get_by_name/1`, `Deckex.Money.brl/1`, `Deckex.Consults.Consult`.
- Produces:
  - `%Deckex.Consults.Vision{nome, tese, custo, eixo, cartas, total_usd, comandante, comandante_problem}`
  - `Visions.for_consult(consult, color_identity) :: [Vision.t()]`
  - `Visions.card_names(consult) :: [String.t()]`
  - `Visions.commander_problem(card_or_nil, color_identity) :: String.t() | nil`
  - `:visao` in `Consult.lenses()`; `Schemas.for_lens(:visao)`.

- [ ] **Step 1: Add the lens and its schema**

In `lib/deckex/consults/consult.ex`, add `:visao` to `@lenses` (after
`:alinhamento`).

In `lib/deckex/consults/schemas.ex`, add a clause **before** the catch-all
`for_lens(_lens)`:

```elixir
  def for_lens(:visao) do
    %{
      "type" => "object",
      "properties" => %{
        "visoes" => %{
          "type" => "array",
          "minItems" => 3,
          "maxItems" => 3,
          "items" => %{
            "type" => "object",
            "properties" => %{
              "nome" => %{
                "type" => "string",
                "description" => "pt-BR: a short name for this direction, 2-4 words."
              },
              "eixo" => %{
                "type" => "string",
                "enum" => ["consistencia", "velocidade", "resiliencia", "eixo_de_vitoria"],
                "description" => "The axis this direction moves. The three visions MUST differ here."
              },
              "tese" => %{
                "type" => "string",
                "description" => "One paragraph, pt-BR: why this makes the deck stronger."
              },
              "custo" => %{
                "type" => "string",
                "description" => "One paragraph, pt-BR: what the deck LOSES going this way. Be honest."
              },
              "cartas_chave" => %{
                "type" => "array",
                "items" => %{"type" => "string"},
                "description" =>
                  "Exact card names, untranslated, that define this direction. Never state a price."
              },
              "comandante" => %{
                "type" => "string",
                "description" =>
                  "Optional: a different commander for this direction. It MUST have exactly the deck's colour identity. Omit to keep the current one."
              }
            },
            "required" => ["nome", "eixo", "tese", "custo", "cartas_chave"]
          }
        }
      },
      "required" => ["visoes"]
    }
  end
```

- [ ] **Step 2: Write the failing test**

`test/deckex/consults/visions_test.exs`:

```elixir
defmodule Deckex.Consults.VisionsTest do
  use Deckex.DataCase, async: true

  alias Deckex.CatalogueFixture
  alias Deckex.Consults.Visions

  defp consult(visoes) do
    build(:consult, lens: :visao, status: :done, response: %{"visoes" => visoes})
  end

  setup do
    CatalogueFixture.seed!(~w(sol_ring counterspell cultivate storm_kiln_artist))

    :ok
  end

  test "a vision is priced by the app from the catalogue" do
    [vision] =
      Visions.for_consult(consult([base_vision(%{"cartas_chave" => ["Sol Ring", "Counterspell"]})]), ~w(U R))

    assert vision.nome == "Controle de Temur"
    assert length(vision.cartas) == 2
    assert Decimal.gt?(vision.total_usd, Decimal.new(0))
  end

  test "card names include the key cards, so the catalogue can fetch them" do
    names = Visions.card_names(consult([base_vision(%{"cartas_chave" => ["Cultivate"]})]))

    assert "Cultivate" in names
  end

  test "a commander outside the deck's identity is refused, and the vision survives" do
    [vision] =
      Visions.for_consult(
        consult([base_vision(%{"comandante" => "Storm-Kiln Artist"})]),
        ~w(U)
      )

    assert vision.comandante_problem =~ "identidade de cor"
    assert vision.nome == "Controle de Temur"
  end

  test "a commander that is not legendary is refused" do
    assert Visions.commander_problem(Deckex.Cards.get_by_name("Sol Ring"), ~w(C)) =~
             "não pode ser comandante"
  end

  defp base_vision(overrides) do
    Map.merge(
      %{
        "nome" => "Controle de Temur",
        "eixo" => "resiliencia",
        "tese" => "Trocar velocidade por respostas.",
        "custo" => "Perde turnos rápidos.",
        "cartas_chave" => []
      },
      overrides
    )
  end
end
```

Note: `Storm-Kiln Artist` is a red creature, so against a mono-blue identity it
fails the identity rule — and it is not legendary, which is why the fourth test
uses `commander_problem/2` directly with a card whose failure is the legendary
rule alone.

- [ ] **Step 3: Run it and watch it fail**

Run: `mix test test/deckex/consults/visions_test.exs`
Expected: FAIL — `Deckex.Consults.Visions is not available`.

- [ ] **Step 4: Write the Vision struct**

`lib/deckex/consults/vision.ex`:

```elixir
defmodule Deckex.Consults.Vision do
  @moduledoc """
  One direction a `:visao` consult proposed, with the app's own numbers on it.

  The model names cards; the app prices them. `total_usd` is summed from the
  catalogue and never from the answer — the price law holds here as everywhere.
  """

  alias Deckex.Cards.Card

  @type card_row :: %{name: String.t(), card: Card.t() | nil, price_usd: Decimal.t() | nil}

  @type t :: %__MODULE__{
          nome: String.t(),
          eixo: String.t(),
          tese: String.t(),
          custo: String.t(),
          cartas: [card_row()],
          total_usd: Decimal.t(),
          comandante: Card.t() | nil,
          comandante_nome: String.t() | nil,
          comandante_problem: String.t() | nil
        }

  defstruct nome: "",
            eixo: "",
            tese: "",
            custo: "",
            cartas: [],
            total_usd: Decimal.new(0),
            comandante: nil,
            comandante_nome: nil,
            comandante_problem: nil
end
```

- [ ] **Step 5: Write the Visions parser**

`lib/deckex/consults/visions.ex`:

```elixir
defmodule Deckex.Consults.Visions do
  @moduledoc """
  Reads a `:visao` answer into `Deckex.Consults.Vision` structs.

  Two jobs the model must not do itself: pricing the key cards (the price law)
  and deciding whether a proposed commander is allowed (the legality law). Both
  happen here, from the catalogue, when the visions are **shown** — so the owner
  never picks a direction and only then learns its commander was refused.
  """

  alias Deckex.Cards
  alias Deckex.Cards.Card
  alias Deckex.Consults.Consult
  alias Deckex.Consults.Vision

  @doc "The visions in a consult's answer, priced and validated."
  @spec for_consult(Consult.t(), [String.t()]) :: [Vision.t()]
  def for_consult(%Consult{} = consult, color_identity) do
    consult |> rows() |> Enum.map(&build(&1, color_identity))
  end

  @doc "Every card name a vision answer mentions, for the catalogue to fetch."
  @spec card_names(Consult.t()) :: [String.t()]
  def card_names(%Consult{} = consult) do
    consult
    |> rows()
    |> Enum.flat_map(&(List.wrap(&1["cartas_chave"]) ++ List.wrap(&1["comandante"])))
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
  end

  @doc """
  Why this card may not be this deck's commander, or nil.

  The identity must match **exactly**. A narrower commander would make every
  card outside its identity illegal at once — a cascade of cuts made for a
  reason that has nothing to do with the deck being better.
  """
  @spec commander_problem(Card.t() | nil, [String.t()]) :: String.t() | nil
  def commander_problem(nil, _identity), do: "não achei essa carta na Scryfall"

  def commander_problem(%Card{} = card, identity) do
    cond do
      not card.commander_legal ->
        "não é legal em Commander"

      not can_be_commander?(card) ->
        "não pode ser comandante (não é criatura lendária)"

      Enum.sort(card.color_identity) != Enum.sort(identity) ->
        "não tem a mesma identidade de cor do deck — trocar mudaria a identidade e tornaria ilegais as cartas que estão fora dela"

      true ->
        nil
    end
  end

  defp rows(%Consult{response: response}) when is_map(response) do
    response |> Map.get("visoes") |> List.wrap()
  end

  defp rows(_no_answer), do: []

  defp build(row, color_identity) do
    cartas = Enum.map(List.wrap(row["cartas_chave"]), &card_row/1)
    commander_name = blank_to_nil(row["comandante"])
    commander = commander_name && Cards.get_by_name(commander_name)

    %Vision{
      nome: row["nome"] || "",
      eixo: row["eixo"] || "",
      tese: row["tese"] || "",
      custo: row["custo"] || "",
      cartas: cartas,
      total_usd: total(cartas),
      comandante: commander,
      comandante_nome: commander_name,
      comandante_problem: commander_name && commander_problem(commander, color_identity)
    }
  end

  defp card_row(name) do
    card = Cards.get_by_name(name)

    %{name: name, card: card, price_usd: card && card.price_usd}
  end

  defp total(cartas) do
    cartas
    |> Enum.map(& &1.price_usd)
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, &1))
  end

  # A legendary creature, or a card that says it can be your commander
  # (Grist and the "can be your commander" background/partner clauses).
  defp can_be_commander?(%Card{} = card) do
    type_line = card.type_line || ""
    text = card.oracle_text || ""

    (String.contains?(type_line, "Legendary") and String.contains?(type_line, "Creature")) or
      String.contains?(text, "can be your commander")
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
```

- [ ] **Step 6: Catalogue the vision's cards**

In `lib/deckex/consults.ex`, `refresh_catalogue/1` currently reads
`Suggestions.names(consult)`. A vision answer has no cuts or adds, so that
returns `[]` and the key cards would never be fetched — leaving every vision
priced at zero.

```elixir
  def refresh_catalogue(%Consult{} = consult) do
    names = Suggestions.names(consult) ++ Visions.card_names(consult)

    case Cards.resolve_names(names) do
      {:ok, %{cards: cards}} ->
        Enum.each(cards, &Cards.classify_card/1)

      {:error, %Error{} = error} ->
        Logger.warning("catalogue refresh failed for consult #{consult.id}: #{error.message}")
    end

    :ok
  end
```

Add `alias Deckex.Consults.Visions` to the module's aliases.

- [ ] **Step 7: Write the vision task block in the briefing**

In `lib/deckex/consults/briefing.ex`, add a `task_block(:visao, _opts)` clause
beside the other lens task blocks:

```elixir
  defp task_block(:visao, _opts) do
    """
    ## Sua tarefa

    Propose **three different directions** this deck could take to become
    genuinely stronger. This is not a tuning pass: you are allowed to change
    what the deck *is*.

    The three MUST differ in `eixo` — one may make the deck more consistent,
    another faster, another harder to disrupt, another change how it wins.
    Three flavours of the same plan is a failed answer.

    For each direction state, in pt-BR: a short name, the thesis for why it
    makes the deck stronger, and — with the same care — what the deck **loses**
    by going that way. List the key cards that define the direction by exact
    name. **Never state a price**: the app prices them from Scryfall and shows
    the owner the real number in R$.

    You may propose a different commander for a direction, but it must have
    **exactly this deck's colour identity** — the app verifies this and will
    print a refusal on your vision if it does not. Omit it to keep the current
    commander.

    Propose no cuts and no adds here. The owner picks one direction, and the
    stages after you will build it.
    """
  end
```

If the file's `task_block/2` clauses take different arguments, match the
existing arity and shape rather than this signature.

- [ ] **Step 8: Run the tests**

Run: `mix test test/deckex/consults/`
Expected: all pass.

- [ ] **Step 9: Gate and commit**

```bash
mix test >/dev/null 2>&1 && echo SUITE-GREEN && mix lint >/dev/null 2>&1 && echo LINT-GREEN && git add -A && git commit -m "feat: the vision lens — three directions, priced by the app

A lens whose answer has no cuts and no adds: three directions that must
differ in axis, each with an honest statement of what the deck loses. The
model names the cards and never a price; the app sums them from the
catalogue. A proposed commander is validated when the vision is shown, not
when it is chosen, so nobody picks a direction and only then learns its
commander was refused."
```

---

### Task 5: The choice — waiting, choosing, asking again

**Files:**
- Modify: `lib/deckex/optimizations.ex`
- Test: `test/deckex/optimizations/reimagine_test.exs` (create)

**Interfaces:**
- Consumes: `Optimizations.run_step/1`, `advance/1`, `transition/2`, `fetch/1`, `Visions.for_consult/2`.
- Produces:
  - `Optimizations.choose_vision(optimization, index :: non_neg_integer()) :: {:ok, Optimization.t()} | {:error, Error.t()}`
  - `Optimizations.ask_again(optimization) :: {:ok, Optimization.t()} | {:error, Error.t()}`
  - `Optimizations.vision_consults(optimization) :: [Consult.t()]` (oldest first)
  - `Optimizations.chosen_vision(optimization) :: map() | nil`
  - `resume/1` refuses `:awaiting_choice` without a chosen vision.

- [ ] **Step 1: Write the failing test**

`test/deckex/optimizations/reimagine_test.exs`:

```elixir
defmodule Deckex.Optimizations.ReimagineTest do
  use Deckex.DataCase, async: true

  import Mox

  alias Deckex.CatalogueFixture
  alias Deckex.Decks
  alias Deckex.Decks.Deck
  alias Deckex.Optimizations
  alias Deckex.Workers.ConsultWorker
  alias Deckex.Workers.OptimizationAdvanceWorker

  setup :verify_on_exit!

  @recipe [
    %{"kind" => "lens", "lens" => "visao", "label" => "Visões"},
    %{"kind" => "reconstruction", "lens" => "full", "label" => "Reconstrução"}
  ]

  @visoes [
    %{
      "nome" => "Mais consistente",
      "eixo" => "consistencia",
      "tese" => "Menos variância.",
      "custo" => "Menos explosão.",
      "cartas_chave" => ["Cultivate"]
    },
    %{
      "nome" => "Mais rápido",
      "eixo" => "velocidade",
      "tese" => "Fecha antes.",
      "custo" => "Frágil.",
      "cartas_chave" => ["Sol Ring"]
    },
    %{
      "nome" => "Mais resiliente",
      "eixo" => "resiliencia",
      "tese" => "Aguenta ódio.",
      "custo" => "Mais lento.",
      "cartas_chave" => ["Counterspell"]
    }
  ]

  defp deck_with_run do
    CatalogueFixture.seed!(~w(sol_ring forest cultivate counterspell))

    stub(Deckex.Scryfall.Mock, :fetch_by_names, fn names ->
      {:ok, %{found: [], not_found: names}}
    end)

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n4 Forest", %{name: "Sintético", source: :paste})

    deck = deck |> Deck.changeset(%{color_identity: ["G", "U"]}) |> Deckex.Repo.update!()

    {:ok, optimization} =
      Optimizations.start(deck, %{"mode" => :reimagine}, @recipe)

    {deck, optimization}
  end

  defp answer_visions(optimization, visoes) do
    expect(Deckex.AI.Mock, :complete, fn _p, _s, _o -> {:ok, %{"visoes" => visoes}} end)

    {:ok, fetched} = Optimizations.fetch(optimization.id)
    step = Enum.find(fetched.steps, &(&1.status == :running))

    :ok = perform_job(ConsultWorker, %{consult_id: step.consult_id})
    :ok = perform_job(OptimizationAdvanceWorker, %{consult_id: step.consult_id})

    Optimizations.fetch(optimization.id)
  end

  test "the run waits for the owner instead of advancing" do
    {_deck, optimization} = deck_with_run()
    {:ok, waiting} = answer_visions(optimization, @visoes)

    assert waiting.status == :awaiting_choice
    assert Enum.at(waiting.steps, 1).status == :pending
    assert length(Optimizations.vision_consults(waiting)) == 1
  end

  test "resuming without a choice is refused with a reason" do
    {_deck, optimization} = deck_with_run()
    {:ok, waiting} = answer_visions(optimization, @visoes)

    assert {:error, error} = Optimizations.resume(waiting)
    assert error.message =~ "escolha uma direção"
  end

  test "choosing a vision freezes it and runs the next stage" do
    {_deck, optimization} = deck_with_run()
    {:ok, waiting} = answer_visions(optimization, @visoes)

    expect(Deckex.AI.Mock, :complete, fn _p, _s, _o ->
      {:ok,
       %{
         "leitura" => "l",
         "diagnosis" => "d",
         "cuts" => [],
         "adds" => []
       }}
    end)

    {:ok, running} = Optimizations.choose_vision(waiting, 1)

    assert running.status == :running
    assert Optimizations.chosen_vision(running)["nome"] == "Mais rápido"
    assert Enum.at(running.steps, 1).status == :running
  end

  test "asking again spends another consult and keeps the declined set" do
    {_deck, optimization} = deck_with_run()
    {:ok, waiting} = answer_visions(optimization, @visoes)

    expect(Deckex.AI.Mock, :complete, fn _p, _s, _o ->
      {:ok, %{"visoes" => @visoes}}
    end)

    {:ok, asked} = Optimizations.ask_again(waiting)
    assert asked.status == :running

    step = Enum.find(asked.steps, &(&1.status == :running))
    :ok = perform_job(ConsultWorker, %{consult_id: step.consult_id})
    :ok = perform_job(OptimizationAdvanceWorker, %{consult_id: step.consult_id})

    {:ok, waiting_again} = Optimizations.fetch(optimization.id)

    assert waiting_again.status == :awaiting_choice
    # Both sets are on the record; positions never moved.
    assert length(Optimizations.vision_consults(waiting_again)) == 2
    assert length(waiting_again.steps) == 2
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `mix test test/deckex/optimizations/reimagine_test.exs`
Expected: FAIL — `Optimizations.vision_consults/1 is undefined`.

- [ ] **Step 3: Make `start/3` accept the mode**

In `lib/deckex/optimizations.ex`, `start/3` builds the record. The mode arrives
in `contract_attrs` as `"mode"`; pull it out so it lands on the row, not in the
contract:

```elixir
      {mode, contract_attrs} = Map.pop(contract_attrs, "mode", :refine)
      recipe = recipe_override || recipe(deck, mode)
      contract = Map.merge(default_contract(deck), contract_attrs)
```

and add `mode: mode` to the `Optimization.changeset/2` attrs map.

- [ ] **Step 4: Stop advancing when a vision lands**

In `advance/1`, after the step is marked `:done` and before `settle/2`, branch:

```elixir
    if vision_step?(step) do
      {:ok, _waiting} = transition(optimization, :awaiting_choice)
      Events.broadcast_optimization(optimization)
      :ok
    else
      settle(optimization, done_step)
    end
```

Match the surrounding code's variable names when you apply this — read
`advance/1` first; it fetches the optimization and broadcasts LAST, and that
ordering is a law (the event is a promise the state is readable).

```elixir
  defp vision_step?(%OptimizationStep{lens: "visao"}), do: true
  defp vision_step?(_step), do: false
```

- [ ] **Step 5: Add the choice functions**

```elixir
  @doc "The visions the run has asked for, oldest first. Declined sets stay."
  @spec vision_consults(Optimization.t()) :: [Consult.t()]
  def vision_consults(%Optimization{} = optimization) do
    ConsultQuery.list_for_optimization(optimization.id, :visao)
  end

  @doc "The direction the owner picked, or nil while the run still waits."
  @spec chosen_vision(Optimization.t()) :: map() | nil
  def chosen_vision(%Optimization{} = optimization), do: optimization.contract["visao"]

  @doc """
  Freezes the chosen direction into the contract and resumes the run.

  `index` is the position in the most recent vision answer — what the owner
  clicked.
  """
  @spec choose_vision(Optimization.t(), non_neg_integer()) ::
          {:ok, Optimization.t()} | {:error, Error.t()}
  def choose_vision(%Optimization{} = optimization, index) do
    visions =
      optimization
      |> vision_consults()
      |> List.last()
      |> case do
        nil -> []
        consult -> List.wrap(consult.response["visoes"])
      end

    case Enum.at(visions, index) do
      nil ->
        {:error, Error.new(:vision_not_found, "Não achei essa direção nesta rodada.")}

      vision ->
        contract = Map.put(optimization.contract, "visao", vision)

        optimization
        |> Optimization.changeset(%{contract: contract})
        |> Repo.update!()
        |> resume()
    end
  end

  @doc "Spends one more consult on a fresh set of directions."
  @spec ask_again(Optimization.t()) :: {:ok, Optimization.t()} | {:error, Error.t()}
  def ask_again(%Optimization{} = optimization) do
    case Enum.find(optimization.steps, &vision_step?/1) do
      nil ->
        {:error, Error.new(:no_vision_step, "Essa rodada não tem etapa de visões.")}

      step ->
        {:ok, _running} = transition(optimization, :running)
        {:ok, _step} = run_step(step)

        fetch(optimization.id)
    end
  end
```

`run_step/1` already repoints `consult_id` and sets the step to `:running`, so
re-running the same step is all "ask again" needs — no position moves and the
unique index on `[optimization_id, position]` is untouched.

- [ ] **Step 6: Guard `resume/1`**

At the top of `resume/1`:

```elixir
  def resume(%Optimization{status: :awaiting_choice} = optimization) do
    if chosen_vision(optimization) do
      do_resume(optimization)
    else
      {:error,
       Error.new(
         :vision_not_chosen,
         "Essa rodada está esperando: escolha uma direção para continuar."
       )}
    end
  end

  def resume(%Optimization{} = optimization), do: do_resume(optimization)
```

Rename the existing body to `do_resume/1`.

- [ ] **Step 7: Add the query**

In `lib/deckex/optimizations/optimization_query.ex` — no; consults belong to the
consult triad. In `lib/deckex/consults/consult_query.ex`:

```elixir
  @doc "One optimization's consults for a lens, oldest first."
  @spec list_for_optimization(String.t(), atom()) :: [Consult.t()]
  def list_for_optimization(optimization_id, lens) do
    Repo.all(
      from c in Consult,
        where: c.optimization_id == ^optimization_id and c.lens == ^lens,
        order_by: [asc: c.inserted_at]
    )
  end
```

Add `alias Deckex.Consults.ConsultQuery` to `Optimizations` if it is not already
aliased.

- [ ] **Step 8: Run the tests**

Run: `mix test test/deckex/optimizations/reimagine_test.exs`
Expected: 4 tests, 0 failures.

- [ ] **Step 9: Gate and commit**

```bash
mix test >/dev/null 2>&1 && echo SUITE-GREEN && mix lint >/dev/null 2>&1 && echo LINT-GREEN && git add -A && git commit -m "feat: the run waits for the owner to choose a direction

A vision answer does not advance the pipeline: it parks the run in
awaiting_choice until someone picks. Choosing freezes the direction into
the contract like every other contract field; asking again re-runs the same
step, so positions never move and the declined sets stay on the record.
Resuming without a choice is refused with a reason rather than running the
next stage against no direction."
```

---

### Task 6: The commander swap, derived

**Files:**
- Modify: `lib/deckex/optimizations.ex`
- Test: `test/deckex/optimizations/reimagine_test.exs`

**Interfaces:**
- Consumes: `Visions.commander_problem/2`, `Optimizations.chosen_vision/1`.
- Produces: `Optimizations.current_commanders(optimization) :: [String.t()]` — every consumer of `optimization.commanders` that describes *the sandbox now* reads this instead.

- [ ] **Step 1: Write the failing test**

Append to `test/deckex/optimizations/reimagine_test.exs`:

```elixir
  test "a chosen vision's valid commander becomes the sandbox's commander" do
    {_deck, optimization} = deck_with_run()

    visoes =
      List.update_at(@visoes, 0, &Map.put(&1, "comandante", "Baral, Chief of Compliance"))

    {:ok, waiting} = answer_visions(optimization, visoes)

    assert Optimizations.current_commanders(waiting) == waiting.commanders

    expect(Deckex.AI.Mock, :complete, fn _p, _s, _o ->
      {:ok, %{"leitura" => "l", "diagnosis" => "d", "cuts" => [], "adds" => []}}
    end)

    {:ok, chosen} = Optimizations.choose_vision(waiting, 0)

    assert Optimizations.current_commanders(chosen) == ["Baral, Chief of Compliance"]
    # The frozen original is untouched — the diff is measured against it.
    assert chosen.commanders != Optimizations.current_commanders(chosen)
  end

  test "a commander the engine refused never reaches the sandbox" do
    {_deck, optimization} = deck_with_run()

    visoes = List.update_at(@visoes, 0, &Map.put(&1, "comandante", "Sol Ring"))
    {:ok, waiting} = answer_visions(optimization, visoes)

    expect(Deckex.AI.Mock, :complete, fn _p, _s, _o ->
      {:ok, %{"leitura" => "l", "diagnosis" => "d", "cuts" => [], "adds" => []}}
    end)

    {:ok, chosen} = Optimizations.choose_vision(waiting, 0)

    assert Optimizations.current_commanders(chosen) == chosen.commanders
  end
```

The test needs a legal UG-identity legendary creature in the catalogue. Add
`baral_chief_of_compliance` to the fixtures first:

```bash
curl -s 'https://api.scryfall.com/cards/named?exact=Baral,+Chief+of+Compliance' > test/support/fixtures/scryfall/baral_chief_of_compliance.json
```

Baral is mono-blue (`["U"]`), so the deck in `deck_with_run/0` must be mono-blue
for the swap to be legal. Change its identity line to `["U"]` and its list to
`"1 Sol Ring\n4 Island"`, seeding `island` instead of `forest`. Fetch the island
fixture if it is missing:

```bash
curl -s 'https://api.scryfall.com/cards/named?exact=Island' > test/support/fixtures/scryfall/island.json
```

Adjust the other tests in the file that referenced Cultivate (a green card) to
use a blue card already seeded — `Counterspell` — so the whole file agrees on
one identity.

- [ ] **Step 2: Run it and watch it fail**

Run: `mix test test/deckex/optimizations/reimagine_test.exs`
Expected: FAIL — `Optimizations.current_commanders/1 is undefined`.

- [ ] **Step 3: Implement the derivation**

In `lib/deckex/optimizations.ex`:

```elixir
  @doc """
  The sandbox's commanders as they stand now.

  `optimization.commanders` stays frozen as the original — the before/after
  diff is measured against it — so a vision's commander swap lives in the
  contract and is derived here. One source of truth, never two stored copies.

  A commander the engine refused is not applied: the refusal was already shown
  on the vision card, and a refused swap silently taking effect would be worse
  than the swap being impossible.
  """
  @spec current_commanders(Optimization.t()) :: [String.t()]
  def current_commanders(%Optimization{} = optimization) do
    with vision when is_map(vision) <- chosen_vision(optimization),
         name when is_binary(name) and name != "" <- vision["comandante"],
         card when not is_nil(card) <- Cards.get_by_name(name),
         nil <- Visions.commander_problem(card, identity_of(optimization)) do
      [card.name]
    else
      _keep_the_original -> optimization.commanders
    end
  end

  defp identity_of(%Optimization{} = optimization) do
    {:ok, deck} = Decks.fetch_deck(optimization.deck_id)

    deck.color_identity
  end
```

Add `alias Deckex.Consults.Visions` to the module's aliases.

- [ ] **Step 4: Route every "now" consumer through it**

Replace `optimization.commanders` with `current_commanders(optimization)` in
these places **only** — each describes the sandbox as it stands, not the
original:

- `run_step/1` — the snapshot handed to the consult
- `judge/4` — the snapshot the audit reads
- `save_as_deck/2` — the list exported to a new deck
- the keep-list that protects commanders from being cut (search for `commanders`
  inside the `judge/4` keep construction)
- `current_list/1` callers in the LiveViews that build a snapshot

Leave `list_original`/`commanders` untouched wherever the ORIGINAL is meant:
the report labelled "original" on the run page, and the frozen row itself.

Verify with: `grep -n "\.commanders" lib/deckex/optimizations.ex lib/deckex_web/live/optimization_live.ex` and check each hit against the rule above.

- [ ] **Step 5: Run the tests**

Run: `mix test test/deckex/optimizations/ test/deckex_web/live/`
Expected: all pass.

- [ ] **Step 6: Gate and commit**

```bash
mix test >/dev/null 2>&1 && echo SUITE-GREEN && mix lint >/dev/null 2>&1 && echo LINT-GREEN && git add -A && git commit -m "feat: a vision may swap the commander, inside the same colours

The frozen commanders stay frozen — the diff needs the original — and the
swap is derived from the contract by current_commanders/1. Exact identity
is the trade that makes this safe: a narrower commander would make every
card outside its identity illegal at once, a cascade of cuts made for a
reason that has nothing to do with the deck being better."
```

---

### Task 7: The reimagine recipe and its briefings

**Files:**
- Modify: `lib/deckex/optimizations.ex`, `lib/deckex/optimizations/optimization_step.ex`, `lib/deckex/consults/briefing.ex`
- Test: `test/deckex/consults/briefing_test.exs`, `test/deckex/optimizations/optimization_test.exs`

**Interfaces:**
- Consumes: `Optimizations.recipe/1`.
- Produces: `Optimizations.recipe(deck, mode :: :refine | :reimagine) :: [map()]`; step kind `:reconstruction`; briefing stage line for `:reconstruction`; `:alinhamento` targets the vision when the contract carries one.

- [ ] **Step 1: Write the failing test**

In `test/deckex/optimizations/optimization_test.exs`:

```elixir
  describe "the reimagine recipe" do
    test "opens with the visions and closes with two checkpoints" do
      recipe = Optimizations.recipe(insert(:deck), :reimagine)

      assert hd(recipe)["lens"] == "visao"
      assert Enum.at(recipe, 1)["kind"] == "reconstruction"
      assert List.last(recipe)["kind"] == "checkpoint"
      assert length(recipe) == 10
    end

    test "it never asks for a scout — a reimagining does not need the old purpose written down" do
      deck = insert(:deck, dossier: nil, dossier_stale: true)

      refute Enum.any?(Optimizations.recipe(deck, :reimagine), &(&1["lens"] == "scout"))
    end

    test "refine is unchanged" do
      deck = insert(:deck, dossier: %{"plano" => "x"}, dossier_stale: false)

      assert length(Optimizations.recipe(deck, :refine)) == 8
    end
  end
```

In `test/deckex/consults/briefing_test.exs`, add to the optimization describe:

```elixir
    test "the reconstruction stage is told it has more room than the others" do
      briefing =
        build(:full, optimization: %{@optimization | stage_kind: :reconstruction})

      assert briefing =~ "reconstruction"
    end

    test "with a vision chosen, alinhamento measures against the vision, not the dossier" do
      optimization = Map.put(@optimization, :contract, Map.put(@optimization.contract, "visao", %{"nome" => "Mais rápido", "tese" => "Fecha antes."}))
      briefing = build(:alinhamento, optimization: optimization)

      assert briefing =~ "Mais rápido"
    end
```

- [ ] **Step 2: Run and watch them fail**

Run: `mix test test/deckex/optimizations/optimization_test.exs test/deckex/consults/briefing_test.exs`
Expected: FAIL — `recipe/2 is undefined`.

- [ ] **Step 3: Add the kind and the recipe**

In `lib/deckex/optimizations/optimization_step.ex`, extend the kind enum:

```elixir
    field :kind, Ecto.Enum, values: [:lens, :checkpoint, :validation, :reconstruction]
```

In `lib/deckex/optimizations.ex`, keep `recipe/1` delegating to the new arity:

```elixir
  @spec recipe(Deck.t()) :: [map()]
  def recipe(%Deck{} = deck), do: recipe(deck, :refine)

  @doc """
  The stages, as data.

  `:refine` opens with a scout only when the dossier is missing or stale.
  `:reimagine` opens with the visions and never scouts: a reimagining does not
  need the deck's current purpose written down first, and the dossier — when
  there is one — is passed as context regardless.

  Stages 3-10 of the reimagine recipe are the refine recipe verbatim. Once the
  direction is chosen and the big swap is done, making the new deck good is the
  work the Otimizador already does well.
  """
  @spec recipe(Deck.t(), :refine | :reimagine) :: [map()]
  def recipe(%Deck{} = deck, :refine) do
    scout =
      if deck.dossier == nil or deck.dossier_stale do
        [%{"kind" => "lens", "lens" => "scout", "label" => "Dossiê"}]
      else
        []
      end

    scout ++ tuning_stages()
  end

  def recipe(%Deck{} = _deck, :reimagine) do
    [
      %{"kind" => "lens", "lens" => "visao", "label" => "Visões"},
      %{"kind" => "reconstruction", "lens" => "full", "label" => "Reconstrução"}
    ] ++ tuning_stages()
  end

  defp tuning_stages do
    [
      %{"kind" => "lens", "lens" => "mana_ramp", "label" => "Mana"},
      %{"kind" => "lens", "lens" => "speed_curve", "label" => "Early game"},
      %{"kind" => "lens", "lens" => "interaction", "label" => "Interação"},
      %{"kind" => "lens", "lens" => "consistency", "label" => "Consistência"},
      %{"kind" => "checkpoint", "lens" => "full", "label" => "Estabilização 1"},
      %{"kind" => "validation", "lens" => "matchup", "label" => "Matchups"},
      %{"kind" => "validation", "lens" => "alinhamento", "label" => "Propósito"},
      %{"kind" => "checkpoint", "lens" => "full", "label" => "Estabilização 2"}
    ]
  end
```

Note the reimagine recipe's `Propósito` stage keeps the `:alinhamento` lens —
only its *target* changes, in the briefing, driven by the contract.

- [ ] **Step 4: Teach the briefing the new stage and target**

In `lib/deckex/consults/briefing.ex`, add a `stage_kind_line/1` clause:

```elixir
  defp stage_kind_line(:reconstruction) do
    "\nThis is the **reconstruction**: the stage that turns the chosen direction into a deck. You have more room here than any other stage — cut what does not serve the direction and add what does. The ceilings, the colour identity, the salt contract and the flip-flop rule still hold."
  end
```

In `optimization_block/1`, add the chosen vision after the contract lines:

```elixir
    #{vision_line(optimization[:contract]["visao"])}
```

```elixir
  defp vision_line(nil), do: ""

  defp vision_line(vision) do
    """

    ### A direção escolhida: #{vision["nome"]}

    #{vision["tese"]}

    O dono aceitou este custo: #{vision["custo"]}

    This is the target now. The deck's old dossier, if one appears above, is
    **what the deck was** — context, not the goal.
    """
  end
```

In `task_block(:alinhamento, opts)`, branch on the vision:

```elixir
  defp task_block(:alinhamento, opts) do
    target =
      case opts[:optimization][:contract]["visao"] do
        nil -> "the dossier above, which is a fixed reference"
        vision -> "the chosen direction, \"#{vision["nome"]}\""
      end

    """
    ## Sua tarefa

    Check the deck against #{target}. Report ONLY where the optimization
    drifted from it — a card that no longer serves it, a hole the changes
    opened. If nothing drifted, say so and propose nothing.
    """
  end
```

Match the existing clause's exact shape and argument names when you edit it;
this shows the change, not a replacement of the whole file.

- [ ] **Step 5: Run the tests**

Run: `mix test test/deckex/optimizations/ test/deckex/consults/`
Expected: all pass.

- [ ] **Step 6: Gate and commit**

```bash
mix test >/dev/null 2>&1 && echo SUITE-GREEN && mix lint >/dev/null 2>&1 && echo LINT-GREEN && git add -A && git commit -m "feat: the reimagine recipe — visions, reconstruction, then the tuning we trust

Ten stages, and eight of them are the refine recipe verbatim: once the
direction is chosen and the big swap is done, making the new deck good is
work that already works. The Propósito stage keeps its lens and changes
only its target — with a vision in the contract it measures fidelity to
the direction, and the old dossier becomes context rather than the goal."
```

---

### Task 8: The pages

**Files:**
- Modify: `lib/deckex_web/live/optimizations_live.ex`, `lib/deckex_web/live/optimization_live.ex`, `lib/deckex_web/live/deck_live.ex`
- Test: `test/deckex_web/live/optimization_live_test.exs`

**Interfaces:**
- Consumes: everything produced by Tasks 2–7.
- Produces: no new module interfaces — UI only.

- [ ] **Step 1: Write the failing tests**

In `test/deckex_web/live/optimization_live_test.exs`, add a describe block:

```elixir
  describe "reimaginar" do
    test "the launcher starts a reimagine run with salt", %{conn: conn} do
      deck = deck()
      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}/otimizacoes")

      live |> element("button[phx-click='abrir-lancador']") |> render_click()
      live |> element("button[phx-click='modo'][phx-value-modo='reimagine']") |> render_click()

      assert {:error, {:live_redirect, _}} =
               live
               |> form("#launch-form",
                 contract: %{
                   "bracket_max" => "3",
                   "ceiling_card" => "800",
                   "ceiling_land" => "200",
                   "keep" => "",
                   "matchups" => "",
                   "notes" => "",
                   "model" => "sonnet",
                   "salt" => %{"stax" => "evitar"}
                 }
               )
               |> render_submit()

      assert [run] = Optimizations.list_for_deck(deck.id)
      assert run.mode == :reimagine
      assert run.contract["salt"]["stax"] == "evitar"
    end

    test "a contract that contradicts itself is refused at launch", %{conn: conn} do
      deck = deck()
      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}/otimizacoes")

      live |> element("button[phx-click='abrir-lancador']") |> render_click()
      live |> element("button[phx-click='modo'][phx-value-modo='reimagine']") |> render_click()

      html =
        live
        |> form("#launch-form",
          contract: %{
            "bracket_max" => "3",
            "ceiling_card" => "",
            "ceiling_land" => "",
            "keep" => "",
            "matchups" => "",
            "notes" => "",
            "model" => "sonnet",
            "salt" => %{"mass_land_denial" => "quero"}
          }
        )
        |> render_submit()

      assert html =~ "Bracket 4"
      assert Optimizations.list_for_deck(deck.id) == []
    end
  end
```

- [ ] **Step 2: Run and watch them fail**

Run: `mix test test/deckex_web/live/optimization_live_test.exs`
Expected: FAIL — no element matching the mode button.

- [ ] **Step 3: The launcher gains the mode and the salt block**

In `lib/deckex_web/live/optimizations_live.ex`:

Add `mode: :refine` to the mount assigns, a handler, and the recipe per mode:

```elixir
  def handle_event("modo", %{"modo" => modo}, socket) do
    mode = String.to_existing_atom(modo)

    {:noreply,
     assign(socket, mode: mode, recipe: Optimizations.recipe(socket.assigns.deck, mode))}
  end

  def handle_event("preset-salt", %{"preset" => preset}, socket) do
    {:noreply, assign(socket, salt: Salt.preset(preset))}
  end
```

In `handle_event("comecar", ...)`, carry the salt and the mode, and check the
contradiction before spending:

```elixir
    contract = %{
      "bracket_max" => String.to_integer(params["bracket_max"]),
      "ceilings" => %{
        "card" => parse_int(params["ceiling_card"]),
        "land" => parse_int(params["ceiling_land"])
      },
      "keep" => lines(params["keep"]),
      "matchups" => lines(params["matchups"]),
      "notes" => String.trim(params["notes"] || ""),
      "model" => params["model"],
      "salt" => params["salt"] || %{}
    }

    case Salt.contradiction(contract) do
      nil -> launch(socket, Map.put(contract, "mode", socket.assigns.mode))
      reason -> {:noreply, put_flash(socket, :error, reason)}
    end
```

with `launch/2` holding the existing `Optimizations.start/2` case.

In the modal, above the existing grid, add the toggle and (only for reimagine)
the salt rows. Use the design tokens the file already uses; every interactive
element needs `min-h-11` for the touch-target law:

```heex
<div class="flex gap-2">
  <button
    :for={{mode, label} <- [{:refine, "Refinar"}, {:reimagine, "Reimaginar"}]}
    type="button"
    phx-click="modo"
    phx-value-modo={mode}
    class={[
      "min-h-11 flex-1 rounded-md border px-3 py-2 text-caption transition-colors",
      @mode == mode && "border-hairline-strong bg-inlay text-ink",
      @mode != mode && "border-hairline-soft text-ink-faint hover:text-ink"
    ]}
  >
    {label}
  </button>
</div>

<p class="text-micro text-ink-muted">
  {if @mode == :refine,
    do: "Melhora o deck dentro do plano que ele já tem.",
    else: "A IA propõe três direções novas, você escolhe uma, e o pipeline reconstrói o deck em cima dela."}
</p>

<div :if={@mode == :reimagine} class="space-y-2">
  <div class="flex items-center justify-between">
    <span class="text-caption font-semibold text-ink-secondary">O que você não quer na mesa</span>
    <div class="flex gap-2">
      <button
        :for={{preset, label} <- [{"mesa_tranquila", "mesa tranquila"}, {"sem_freio", "sem freio"}]}
        type="button"
        phx-click="preset-salt"
        phx-value-preset={preset}
        class="-my-2 inline-flex min-h-11 items-center px-1 py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 hover:text-ink"
      >
        {label}
      </button>
    </div>
  </div>

  <div :for={tactic <- Salt.tactics()} class="flex items-center justify-between gap-3">
    <span class="text-caption text-ink-secondary">{tactic.label}</span>
    <div class="flex gap-1">
      <label
        :for={{value, label} <- [{"evitar", "evitar"}, {"tanto_faz", "tanto faz"}, {"quero", "quero"}]}
        class={[
          "inline-flex min-h-11 cursor-pointer items-center rounded-md border px-2 text-micro transition-colors",
          Map.get(@salt, tactic.key, "tanto_faz") == value &&
            "border-hairline-strong bg-inlay text-ink",
          Map.get(@salt, tactic.key, "tanto_faz") != value &&
            "border-hairline-soft text-ink-faint hover:text-ink"
        ]}
      >
        <input
          type="radio"
          name={"contract[salt][#{tactic.key}]"}
          value={value}
          checked={Map.get(@salt, tactic.key, "tanto_faz") == value}
          class="sr-only"
        />
        {label}
      </label>
    </div>
  </div>
</div>
```

Add `salt: Salt.preset("sem_freio")` to the mount assigns and
`alias Deckex.Optimizations.Salt`.

- [ ] **Step 4: The timeline shows the visions**

In `lib/deckex_web/live/optimization_live.ex`, in `load/2`:

```elixir
      visions: vision_cards(optimization, deck),
```

```elixir
  # Only while the run is waiting: the most recent set is the live one, and
  # earlier sets stay above it as the record of what was declined.
  defp vision_cards(%{status: :awaiting_choice} = optimization, deck) do
    optimization
    |> Optimizations.vision_consults()
    |> List.last()
    |> case do
      nil -> []
      consult -> Visions.for_consult(consult, deck.color_identity)
    end
  end

  defp vision_cards(_settled, _deck), do: []
```

Handlers:

```elixir
  def handle_event("escolher-visao", %{"index" => index}, socket) do
    case Optimizations.choose_vision(socket.assigns.optimization, String.to_integer(index)) do
      {:ok, optimization} ->
        {:noreply, socket |> load(optimization) |> put_flash(:info, "Direção escolhida.")}

      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("outras-visoes", _params, socket) do
    case Optimizations.ask_again(socket.assigns.optimization) do
      {:ok, optimization} ->
        {:noreply, socket |> load(optimization) |> put_flash(:info, "Pedindo outras três…")}

      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end
```

The section, rendered above the timeline when `@visions != []`:

```heex
<section :if={@visions != []} class="mb-8">
  <h2 class="mb-1 text-heading font-semibold text-ink">Escolha uma direção</h2>
  <p class="mb-4 text-caption text-ink-muted">
    A rodada está esperando você. Nada é gasto até você escolher.
  </p>

  <ul class="grid gap-4 sm:grid-cols-3">
    <li
      :for={{vision, index} <- Enum.with_index(@visions)}
      class="flex flex-col rounded-xl border border-hairline-soft bg-surface p-5"
    >
      <h3 class="text-heading font-semibold text-ink">{vision.nome}</h3>
      <p class="mt-2 flex-1 text-caption text-ink-secondary">{vision.tese}</p>

      <p class="mt-3 text-caption text-ink-muted">
        <span class="font-semibold">O que perde:</span> {vision.custo}
      </p>

      <p :if={vision.comandante_nome} class="mt-3 text-caption">
        <span class="text-ink-muted">Comandante:</span>
        <span class="text-ink">{vision.comandante_nome}</span>
        <span :if={vision.comandante_problem} class="text-sev-critical">
          — {vision.comandante_problem}
        </span>
      </p>

      <ul class="mt-3 space-y-1">
        <li :for={carta <- vision.cartas} class="text-caption text-ink-secondary">
          <span class="text-ink">{carta.name}</span>
          <span class="font-mono text-ink-faint">{Money.brl(carta.price_usd)}</span>
        </li>
      </ul>

      <p class="mt-3 font-mono text-caption text-ink">
        entradas: {Money.brl(vision.total_usd)}
      </p>

      <.button
        type="button"
        phx-click="escolher-visao"
        phx-value-index={index}
        phx-disable-with="seguindo…"
        variant="primary"
        class="mt-4"
      >
        Seguir esta
      </.button>
    </li>
  </ul>

  <button
    type="button"
    phx-click="outras-visoes"
    phx-disable-with="pedindo…"
    data-confirm="Pedir outras três direções? Isso gasta mais uma consulta."
    class="-my-2 mt-4 inline-flex min-h-11 items-center px-1 py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 hover:text-ink"
  >
    Pedir outras três (mais uma consulta)
  </button>
</section>
```

Add `alias Deckex.Consults.Visions` to the LiveView.

Add the status label:

```elixir
  defp run_status_label(:awaiting_choice), do: "esperando você escolher"
```

and, in the header, name the chosen direction once there is one:

```heex
<p :if={vision = Optimizations.chosen_vision(@optimization)} class="mt-1 text-caption text-ink-muted">
  direção: <span class="text-ink">{vision["nome"]}</span>
</p>
```

- [ ] **Step 5: The history page and the deck page**

In `lib/deckex_web/live/optimizations_live.ex`, add the badge to each run row:

```heex
<span class="rounded-md border border-hairline-soft px-2 py-0.5 font-mono text-micro text-ink-faint">
  {if run.mode == :reimagine, do: "reimaginar", else: "refinar"}
</span>
```

and `defp status_label(:awaiting_choice), do: "esperando escolha"`.

In `lib/deckex_web/live/deck_live.ex`, extend the live-run button wording:

```elixir
            {cond do
              @running_optimization.status == :awaiting_choice -> "Otimização esperando você →"
              @running_optimization.status == :paused -> "Otimização pausada →"
              true -> "Otimização rodando →"
            end}
```

- [ ] **Step 6: Run the tests**

Run: `mix test test/deckex_web/live/`
Expected: all pass.

- [ ] **Step 7: Gate and commit**

```bash
mix test >/dev/null 2>&1 && echo SUITE-GREEN && mix lint >/dev/null 2>&1 && echo LINT-GREEN && git add -A && git commit -m "feat: the pages learn the second mode

One launcher with a toggle, because a refine run and a reimagine run over
the same deck belong in the same history side by side. The salt block only
appears where it applies, the contradiction is refused before it costs a
consult, and a waiting run puts the three directions on the timeline with
the price the app computed — never one the model stated."
```

---

### Task 9: End to end, then the real thing

**Files:**
- Create: `test/deckex/optimizations/reimagine_regression_test.exs`
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: everything above.
- Produces: the regression that keeps the mode honest.

- [ ] **Step 1: Write the regression**

`test/deckex/optimizations/reimagine_regression_test.exs` — a scripted run on a
synthetic deck, mirroring `pipeline_regression_test.exs`. Recipe override:
`[visao, reconstruction, checkpoint]`. Scripted answers:

1. the vision stage returns three directions, one carrying a legal commander
2. the run parks in `:awaiting_choice`; assert the next step is still `:pending`
3. `choose_vision/2` picks the one with the commander
4. the reconstruction proposes one legal add, one add carrying an avoided salt
   role (rejected, with the reason), and one cut
5. the checkpoint applies nothing
6. assert: run `:done`, `current_commanders/1` is the vision's commander, the
   salt refusal is on the step's `rejected`, the final list is exactly 100
   cards, and `Consults.list_for_deck(deck) == []`

Use `Optimizations.card_count/1` for the count and the `beat/1` helper shape
from `pipeline_regression_test.exs`. Seed every fixture in **one**
`CatalogueFixture.seed!/1` call.

- [ ] **Step 2: Run it until green**

Run: `mix test test/deckex/optimizations/reimagine_regression_test.exs`
Expected: 1 test, 0 failures.

- [ ] **Step 3: Write down what this taught**

Append to `AGENTS.md`'s "Project-specific laws":

```markdown
- **A new role makes the stored catalogue stale.** Cards already in the
  catalogue were classified before the rule existed, so a guard reading that
  role silently misses them — a rule that looks enforced and is not. Ship a
  rule together with `Deckex.Cards.reclassify_all!/0`, ordered by `oracle_id`.
- **Self-mill is not mill.** Milling yourself is a graveyard build-around;
  milling an opponent is a tactic aimed at a person. Only the second is
  something an owner asks to avoid, and templating separates them for free.
- **A commander swap must preserve the colour identity exactly.** A narrower
  commander makes every card outside its identity illegal at once — a cascade
  of cuts for a reason that has nothing to do with the deck being better.
```

- [ ] **Step 4: Full gate and commit**

```bash
mix test >/dev/null 2>&1 && echo SUITE-GREEN && mix lint >/dev/null 2>&1 && echo LINT-GREEN && git add -A && git commit -m "test: the reimagine pipeline end to end, on a deck that is not Iroh

Visions proposed, the run parking to wait, a direction chosen, a commander
swapped inside the identity, a salt-violating add refused with its reason,
and the copy closing at exactly 100 — with the deck page none the wiser."
```

- [ ] **Step 5: Browser proof on a throwaway deck**

Start the server through the preview tool (never `mix phx.server` in a shell),
open `/decks/<throwaway>/otimizacoes`, switch the launcher to **Reimaginar**,
set a salt tactic to *evitar*, and verify:

- the stage count reads 10
- the contradiction check fires for land denial under bracket 3
- launching parks the run at "esperando você escolher" with three priced cards

Then **cancel** — do not spend the remaining nine consults on a throwaway deck.

- [ ] **Step 6: The real run**

Only on the owner's word: launch a reimagine run on the reference deck, watch it
to completion, and report what the visions proposed and which direction won.
The lesson of 2026-08-14 stands — the real run finds what the tests do not.

---

## Self-Review

**Spec coverage:** §2 mode → T2. §3 visions/choice/re-ask/awaiting → T4, T5.
§4 salt, presets, contradiction, mill role, reclassification → T1, T3. §5
commander swap → T4 (validation), T6 (derivation). §6 recipe → T7. §7 UI → T8.
§8 genericity → T9's synthetic regression. §9 testing → tests in every task.

**Placeholders:** none — every step carries the code or the exact command.
Task 9 Step 1 describes the regression as a numbered script rather than full
source; that is deliberate, because it mirrors an existing file the implementer
must read anyway, and the assertions are enumerated exactly.

**Type consistency:** `Salt.avoided/1` returns `%{atom() => String.t()}` in T3
and is consumed with that shape by `Audit`'s `avoid:` opt and by
`salt_line/1`. `Visions.commander_problem/2` takes `(Card.t() | nil, [String.t()])`
in T4 and is called that way in T6. `Optimizations.recipe/2` is defined in T7
and used by T8's mode handler. `chosen_vision/1` is defined in T5 and used in
T6, T7 and T8.
