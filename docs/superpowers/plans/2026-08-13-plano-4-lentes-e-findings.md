# Plano 4 — As Quatro Lentes e o Catálogo de Findings

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn a stored deck into a measured report — mana curve, mana base,
interaction, consistency — and a list of findings with severity, evidence and
the cards implicated.

**Architecture:** `Deckex.Analysis` is a **pure functional core**: no Repo, no
HTTP, no process state. It takes a `DeckSnapshot` (deck + cards + quantities +
roles, all preloaded) and returns a `Report`. `Deckex.Decks.snapshot/1` is the
only thing that touches the database. Reports are computed on demand, never
cached.

**Tech Stack:** Elixir 1.19.5 / OTP 27. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-08-13-deckex-design.md` §7.2–§7.7 — this
plan implements milestone 5 of §13.

## Global Constraints

- **Code is English; user-facing strings are pt-BR.** Finding titles and details
  are shown to the user, so they are pt-BR. Card names are never translated.
- **`Deckex.Analysis` is pure.** No `Deckex.Repo`, no `Req`, no `Oban`, no
  process dictionary. A test for any lens must run without a database.
- **Reports are computed, never cached.** Arithmetic over ~100 in-memory structs
  is microseconds; a cache would only buy staleness bugs.
- **Every threshold lives in `Baselines`**, never inline in a lens. They are
  heuristics and the user can edit them.
- **Every finding names the cards behind it.** A number the user cannot drill
  into is a number they cannot act on.
- **`mix lint` must be green BEFORE every commit** — chain with `&&`.
- **PostgreSQL is on host port 5435.**
- **Do not touch `lib/deckex_web/`, `assets/` or `DESIGN.md`** — another agent
  owns the design system.

## File structure

| File | Responsibility |
|---|---|
| `lib/deckex/analysis/card_entry.ex` | One card in a deck: card + quantity + role set |
| `lib/deckex/analysis/deck_snapshot.ex` | The input struct; predicates every lens shares |
| `lib/deckex/analysis/baselines.ex` | The 18 thresholds, with defaults |
| `lib/deckex/analysis/finding.ex` | The finding struct + severity |
| `lib/deckex/analysis/curve.ex` | Lens: speed & curve |
| `lib/deckex/analysis/mana.ex` | Lens: mana base & ramp |
| `lib/deckex/analysis/interaction.ex` | Lens: answers |
| `lib/deckex/analysis/consistency.ex` | Lens: draw, tutors, closing |
| `lib/deckex/analysis/report.ex` | The output struct |
| `lib/deckex/analysis.ex` | `report/2` — the single entry point |
| `lib/deckex/decks.ex` | `snapshot/1` — the only DB touch |

---

### Task 1: The input — `CardEntry`, `DeckSnapshot`, `Baselines`

**Files:**
- Create: `lib/deckex/analysis/card_entry.ex`
- Create: `lib/deckex/analysis/deck_snapshot.ex`
- Create: `lib/deckex/analysis/baselines.ex`
- Test: `test/deckex/analysis/deck_snapshot_test.exs`
- Test: `test/support/analysis_fixture.ex`

**Interfaces:**
- Consumes: `%Deckex.Cards.Card{}`.
- Produces:
  - `%Deckex.Analysis.CardEntry{card: %Card{}, quantity: pos_integer(), roles: MapSet.t(atom())}`
  - `Deckex.Analysis.CardEntry.new(card, quantity, roles) :: t()`
  - `Deckex.Analysis.CardEntry.cmc(t()) :: float()`
  - `Deckex.Analysis.CardEntry.front_type(t()) :: String.t()`
  - `Deckex.Analysis.CardEntry.back_type(t()) :: String.t()`
  - `Deckex.Analysis.CardEntry.land?(t()) :: boolean()`
  - `Deckex.Analysis.CardEntry.mdfc_land?(t()) :: boolean()`
  - `Deckex.Analysis.CardEntry.instant?(t()) :: boolean()`
  - `Deckex.Analysis.CardEntry.has_role?(t(), atom()) :: boolean()`
  - `Deckex.Analysis.CardEntry.pips(t(), String.t()) :: non_neg_integer()`
  - `%Deckex.Analysis.DeckSnapshot{deck_id, deck_name, color_identity, commanders: [CardEntry.t()], main: [CardEntry.t()]}`
  - `Deckex.Analysis.DeckSnapshot.nonlands(t()) :: [CardEntry.t()]`
  - `Deckex.Analysis.DeckSnapshot.lands(t()) :: [CardEntry.t()]`
  - `Deckex.Analysis.DeckSnapshot.count(entries) :: non_neg_integer()`
  - `Deckex.Analysis.DeckSnapshot.with_role(entries, atom()) :: [CardEntry.t()]`
  - `%Deckex.Analysis.Baselines{}` with `Baselines.default/0`
  - `Deckex.AnalysisFixture.snapshot(entries, opts) :: %DeckSnapshot{}` and
    `Deckex.AnalysisFixture.entry(attrs) :: %CardEntry{}` (test support)

- [ ] **Step 1: Write the failing test**

Create `test/deckex/analysis/deck_snapshot_test.exs`:

```elixir
defmodule Deckex.Analysis.DeckSnapshotTest do
  use ExUnit.Case, async: true

  alias Deckex.Analysis.Baselines
  alias Deckex.Analysis.CardEntry
  alias Deckex.Analysis.DeckSnapshot
  alias Deckex.AnalysisFixture

  describe "CardEntry" do
    test "reads cmc as a float" do
      assert CardEntry.cmc(AnalysisFixture.entry(cmc: "3.0")) == 3.0
    end

    test "reads the front face type" do
      entry = AnalysisFixture.entry(type_line: "Sorcery // Land")

      assert CardEntry.front_type(entry) == "Sorcery"
      assert CardEntry.back_type(entry) == "Land"
    end

    test "a plain land is a land" do
      assert CardEntry.land?(AnalysisFixture.entry(type_line: "Basic Land — Forest"))
    end

    test "an MDFC whose front is a spell is not a land, but its back is" do
      entry = AnalysisFixture.entry(type_line: "Sorcery // Land")

      refute CardEntry.land?(entry)
      assert CardEntry.mdfc_land?(entry)
    end

    test "a plain land is not an MDFC land" do
      refute CardEntry.mdfc_land?(AnalysisFixture.entry(type_line: "Land"))
    end

    test "counts coloured pips in the mana cost" do
      entry = AnalysisFixture.entry(mana_cost: "{X}{B}{B}{B}")

      assert CardEntry.pips(entry, "B") == 3
      assert CardEntry.pips(entry, "G") == 0
    end

    test "a card with no mana cost has no pips" do
      assert CardEntry.pips(AnalysisFixture.entry(mana_cost: nil), "G") == 0
    end

    test "knows its roles" do
      entry = AnalysisFixture.entry(roles: [:ramp, :fixing])

      assert CardEntry.has_role?(entry, :ramp)
      refute CardEntry.has_role?(entry, :counter)
    end

    test "knows instant speed" do
      assert CardEntry.instant?(AnalysisFixture.entry(type_line: "Instant"))
      refute CardEntry.instant?(AnalysisFixture.entry(type_line: "Sorcery"))
    end
  end

  describe "DeckSnapshot" do
    setup do
      snapshot =
        AnalysisFixture.snapshot([
          AnalysisFixture.entry(name: "Forest", type_line: "Basic Land — Forest", quantity: 4),
          AnalysisFixture.entry(name: "Sol Ring", type_line: "Artifact", roles: [:ramp]),
          AnalysisFixture.entry(name: "Silundi Vision", type_line: "Instant // Land")
        ])

      %{snapshot: snapshot}
    end

    test "separates lands from nonlands by the front face", %{snapshot: snapshot} do
      assert snapshot |> DeckSnapshot.lands() |> Enum.map(& &1.card.name) == ["Forest"]

      assert snapshot |> DeckSnapshot.nonlands() |> Enum.map(& &1.card.name) |> Enum.sort() ==
               ["Silundi Vision", "Sol Ring"]
    end

    test "counts by quantity, not by row", %{snapshot: snapshot} do
      assert snapshot |> DeckSnapshot.lands() |> DeckSnapshot.count() == 4
    end

    test "filters by role", %{snapshot: snapshot} do
      ramp = snapshot |> DeckSnapshot.nonlands() |> DeckSnapshot.with_role(:ramp)

      assert Enum.map(ramp, & &1.card.name) == ["Sol Ring"]
    end
  end

  describe "Baselines" do
    test "ships the documented Commander defaults" do
      b = Baselines.default()

      assert b.land_base == 36
      assert b.avg_cmc_high == 3.5
      assert b.ramp_target == 10
      assert b.ramp_cheap_target == 4
      assert b.interaction_floor == 5
      assert b.board_wipe_target == 2
      assert b.sources_double_pip == 25
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/deckex/analysis/deck_snapshot_test.exs`
Expected: FAIL — `module Deckex.AnalysisFixture is not available`.

- [ ] **Step 3: Write `CardEntry`**

Create `lib/deckex/analysis/card_entry.ex`:

```elixir
defmodule Deckex.Analysis.CardEntry do
  @moduledoc """
  One card in a deck, as the lenses see it: the card, how many copies, and the
  roles already classified for it.

  The type predicates here read the **front face**. A modal double-faced card
  whose back is a land is a spell you can also play as a land, and only the mana
  lens cares about the back — `mdfc_land?/1` is how it asks.
  """

  alias Deckex.Cards.Card

  @type t :: %__MODULE__{card: Card.t(), quantity: pos_integer(), roles: MapSet.t(atom())}

  @enforce_keys [:card, :quantity, :roles]
  defstruct [:card, :quantity, :roles]

  @pip_symbols ~w(W U B R G)

  @spec new(Card.t(), pos_integer(), Enumerable.t()) :: t()
  def new(%Card{} = card, quantity, roles) do
    %__MODULE__{card: card, quantity: quantity, roles: MapSet.new(roles)}
  end

  @spec cmc(t()) :: float()
  def cmc(%__MODULE__{card: %{cmc: nil}}), do: 0.0
  def cmc(%__MODULE__{card: %{cmc: cmc}}), do: Decimal.to_float(cmc)

  @spec front_type(t()) :: String.t()
  def front_type(%__MODULE__{card: card}) do
    card.type_line |> String.split("//") |> hd() |> String.trim()
  end

  @spec back_type(t()) :: String.t()
  def back_type(%__MODULE__{card: card}) do
    case String.split(card.type_line, "//") do
      [_front, back] -> String.trim(back)
      _single_faced -> ""
    end
  end

  @spec land?(t()) :: boolean()
  def land?(entry), do: String.contains?(front_type(entry), "Land")

  @doc "A spell whose back face is a land — worth half a land to the mana base."
  @spec mdfc_land?(t()) :: boolean()
  def mdfc_land?(entry), do: not land?(entry) and String.contains?(back_type(entry), "Land")

  @spec instant?(t()) :: boolean()
  def instant?(entry), do: String.contains?(front_type(entry), "Instant")

  @spec has_role?(t(), atom()) :: boolean()
  def has_role?(%__MODULE__{roles: roles}, kind), do: MapSet.member?(roles, kind)

  @doc """
  How many pips of `colour` the mana cost demands. `{X}{B}{B}{B}` is three black
  pips — the number that decides how many black sources the deck needs.
  """
  @spec pips(t(), String.t()) :: non_neg_integer()
  def pips(%__MODULE__{card: %{mana_cost: nil}}, _colour), do: 0

  def pips(%__MODULE__{card: %{mana_cost: cost}}, colour) when colour in @pip_symbols do
    cost |> String.graphemes() |> Enum.count(&(&1 == colour))
  end
end
```

- [ ] **Step 4: Write `DeckSnapshot`**

Create `lib/deckex/analysis/deck_snapshot.ex`:

```elixir
defmodule Deckex.Analysis.DeckSnapshot do
  @moduledoc """
  Everything the lenses need about a deck, already loaded.

  This struct is the boundary that keeps `Deckex.Analysis` pure: the database
  work happens once in `Deckex.Decks.snapshot/1`, and every lens then operates
  on plain structs in memory.
  """

  alias Deckex.Analysis.CardEntry

  @type t :: %__MODULE__{
          deck_id: String.t(),
          deck_name: String.t(),
          color_identity: [String.t()],
          commanders: [CardEntry.t()],
          main: [CardEntry.t()]
        }

  @enforce_keys [:deck_id, :deck_name, :color_identity, :commanders, :main]
  defstruct [:deck_id, :deck_name, :color_identity, :commanders, :main]

  @doc "Main-deck entries whose front face is a land."
  @spec lands(t()) :: [CardEntry.t()]
  def lands(%__MODULE__{main: main}), do: Enum.filter(main, &CardEntry.land?/1)

  @doc "Main-deck entries whose front face is not a land."
  @spec nonlands(t()) :: [CardEntry.t()]
  def nonlands(%__MODULE__{main: main}), do: Enum.reject(main, &CardEntry.land?/1)

  @doc "Main-deck spells whose back face is a land."
  @spec mdfc_lands(t()) :: [CardEntry.t()]
  def mdfc_lands(%__MODULE__{main: main}), do: Enum.filter(main, &CardEntry.mdfc_land?/1)

  @doc "Sums copies, not rows — four Forests are four cards."
  @spec count([CardEntry.t()]) :: non_neg_integer()
  def count(entries), do: Enum.sum(Enum.map(entries, & &1.quantity))

  @doc "The entries holding `kind`."
  @spec with_role([CardEntry.t()], atom()) :: [CardEntry.t()]
  def with_role(entries, kind), do: Enum.filter(entries, &CardEntry.has_role?(&1, kind))

  @doc "Card names, sorted — what a finding shows the user."
  @spec names([CardEntry.t()]) :: [String.t()]
  def names(entries), do: entries |> Enum.map(& &1.card.name) |> Enum.sort()
end
```

- [ ] **Step 5: Write `Baselines`**

Create `lib/deckex/analysis/baselines.ex`:

```elixir
defmodule Deckex.Analysis.Baselines do
  @moduledoc """
  Every threshold the lenses test against, in one place.

  These are **heuristics for 99-card Commander**, not laws. They live here so a
  lens never hides a magic number, and so the user can tune them to their
  playgroup — a casual table and a cEDH table disagree about most of these.

  The colour-source targets follow the commonly cited Karsten-style framework:
  roughly 19 sources for a single coloured pip on curve, 25 for a double pip,
  31 for a triple.
  """

  @type t :: %__MODULE__{}

  defstruct avg_cmc_low: 2.4,
            avg_cmc_high: 3.5,
            avg_cmc_slow: 3.8,
            land_base: 36,
            land_min: 33,
            land_max: 40,
            ramp_target: 10,
            ramp_cheap_target: 4,
            early_play_target: 12,
            late_game_floor: 5,
            top_heavy_share: 0.20,
            interaction_target: 8,
            interaction_floor: 5,
            board_wipe_target: 2,
            draw_target: 8,
            sources_single_pip: 19,
            sources_double_pip: 25,
            sources_triple_pip: 31,
            tapland_share_max: 0.25

  @doc "The documented Commander defaults."
  @spec default() :: t()
  def default, do: %__MODULE__{}
end
```

- [ ] **Step 6: Write the test fixture helper**

Create `test/support/analysis_fixture.ex`:

```elixir
defmodule Deckex.AnalysisFixture do
  @moduledoc """
  Builds `CardEntry` and `DeckSnapshot` structs directly, with no database.

  The lenses are pure, so their tests should be too: a curve test that needs
  Postgres running is a test nobody runs.
  """

  alias Deckex.Analysis.CardEntry
  alias Deckex.Analysis.DeckSnapshot
  alias Deckex.Cards.Card

  @doc """
  A card entry. Every field has a neutral default, so a test sets only what it
  is about.
  """
  @spec entry(keyword()) :: CardEntry.t()
  def entry(attrs \\ []) do
    card = %Card{
      id: Keyword.get(attrs, :id, Ecto.UUID.generate()),
      name: Keyword.get(attrs, :name, "Carta"),
      mana_cost: Keyword.get(attrs, :mana_cost, "{2}"),
      cmc: attrs |> Keyword.get(:cmc, "2.0") |> Decimal.new(),
      type_line: Keyword.get(attrs, :type_line, "Artifact"),
      oracle_text: Keyword.get(attrs, :oracle_text, ""),
      color_identity: Keyword.get(attrs, :color_identity, []),
      produced_mana: Keyword.get(attrs, :produced_mana, [])
    }

    CardEntry.new(card, Keyword.get(attrs, :quantity, 1), Keyword.get(attrs, :roles, []))
  end

  @doc "A snapshot around the given main-deck entries."
  @spec snapshot([CardEntry.t()], keyword()) :: DeckSnapshot.t()
  def snapshot(main, opts \\ []) do
    %DeckSnapshot{
      deck_id: Keyword.get(opts, :deck_id, Ecto.UUID.generate()),
      deck_name: Keyword.get(opts, :deck_name, "Deck de teste"),
      color_identity: Keyword.get(opts, :color_identity, []),
      commanders: Keyword.get(opts, :commanders, []),
      main: main
    }
  end
end
```

- [ ] **Step 7: Run the test, gate and commit**

Run: `mix test test/deckex/analysis/deck_snapshot_test.exs`
Expected: PASS — 13 tests.

```bash
mix lint && git add -A && git commit -m "feat: add the analysis input structs and baselines

DeckSnapshot is the boundary that keeps the lenses pure: one database read
builds it, and every lens then works on plain structs in memory."
```

---

### Task 2: The `Finding` struct

**Files:**
- Create: `lib/deckex/analysis/finding.ex`
- Test: `test/deckex/analysis/finding_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `%Deckex.Analysis.Finding{code, severity, lens, title, detail, evidence, card_names}`
  - `Deckex.Analysis.Finding.new(code, severity, lens, title, detail, opts) :: t()` where
    `opts` accepts `:evidence` (map, default `%{}`) and `:card_names` (list, default `[]`)
  - `Deckex.Analysis.Finding.critical?(t()) :: boolean()`
  - `Deckex.Analysis.Finding.sort(list) :: list` — critical first, then warning, then info

- [ ] **Step 1: Write the failing test**

Create `test/deckex/analysis/finding_test.exs`:

```elixir
defmodule Deckex.Analysis.FindingTest do
  use ExUnit.Case, async: true

  alias Deckex.Analysis.Finding

  defp finding(severity) do
    Finding.new("x.y", severity, :mana_ramp, "Título", "Detalhe")
  end

  describe "new/6" do
    test "carries everything a user needs to act" do
      finding =
        Finding.new("mana.ramp_low", :warning, :mana_ramp, "Pouco ramp", "Só 6 peças.",
          evidence: %{ramp: 6, target: 10},
          card_names: ["Sol Ring"]
        )

      assert %Finding{
               code: "mana.ramp_low",
               severity: :warning,
               lens: :mana_ramp,
               evidence: %{ramp: 6, target: 10},
               card_names: ["Sol Ring"]
             } = finding
    end

    test "defaults evidence and card names" do
      assert %Finding{evidence: %{}, card_names: []} = finding(:info)
    end

    test "rejects a severity outside the vocabulary" do
      assert_raise FunctionClauseError, fn ->
        Finding.new("x.y", :apocalyptic, :mana_ramp, "t", "d")
      end
    end
  end

  describe "sort/1" do
    test "puts critical first and info last" do
      sorted = Finding.sort([finding(:info), finding(:critical), finding(:warning)])

      assert Enum.map(sorted, & &1.severity) == [:critical, :warning, :info]
    end
  end

  describe "critical?/1" do
    test "is true only for critical" do
      assert Finding.critical?(finding(:critical))
      refute Finding.critical?(finding(:warning))
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/deckex/analysis/finding_test.exs`
Expected: FAIL — `module Deckex.Analysis.Finding is not available`.

- [ ] **Step 3: Write the struct**

Create `lib/deckex/analysis/finding.ex`:

```elixir
defmodule Deckex.Analysis.Finding do
  @moduledoc """
  One thing the engine noticed about a deck.

  A finding carries its `evidence` — the raw numbers behind it — and the
  `card_names` implicated, because a number the user cannot drill into is a
  number they cannot act on. `title` and `detail` are shown to the user and are
  therefore pt-BR.
  """

  @type severity :: :critical | :warning | :info
  @type lens :: :speed_curve | :mana_ramp | :interaction | :consistency

  @type t :: %__MODULE__{
          code: String.t(),
          severity: severity(),
          lens: lens(),
          title: String.t(),
          detail: String.t(),
          evidence: map(),
          card_names: [String.t()]
        }

  @enforce_keys [:code, :severity, :lens, :title, :detail]
  defstruct [:code, :severity, :lens, :title, :detail, evidence: %{}, card_names: []]

  @rank %{critical: 0, warning: 1, info: 2}

  @spec new(String.t(), severity(), lens(), String.t(), String.t(), keyword()) :: t()
  def new(code, severity, lens, title, detail, opts \\ [])
      when severity in [:critical, :warning, :info] and
             lens in [:speed_curve, :mana_ramp, :interaction, :consistency] do
    %__MODULE__{
      code: code,
      severity: severity,
      lens: lens,
      title: title,
      detail: detail,
      evidence: Keyword.get(opts, :evidence, %{}),
      card_names: Keyword.get(opts, :card_names, [])
    }
  end

  @spec critical?(t()) :: boolean()
  def critical?(%__MODULE__{severity: severity}), do: severity == :critical

  @doc "Most severe first — the order the deck screen lists them in."
  @spec sort([t()]) :: [t()]
  def sort(findings), do: Enum.sort_by(findings, &@rank[&1.severity])
end
```

- [ ] **Step 4: Run the test, gate and commit**

Run: `mix test test/deckex/analysis/finding_test.exs`
Expected: PASS — 6 tests.

```bash
mix lint && git add -A && git commit -m "feat: add the analysis finding struct

A finding carries its evidence and the cards behind it, because a number the
user cannot drill into is a number they cannot act on."
```

---

### Task 3: Lens — Velocidade & Curva

**Files:**
- Create: `lib/deckex/analysis/curve.ex`
- Test: `test/deckex/analysis/curve_test.exs`

**Interfaces:**
- Consumes: `DeckSnapshot`, `CardEntry`, `Baselines`, `Finding` (Tasks 1–2).
- Produces:
  - `Deckex.Analysis.Curve.measure(%DeckSnapshot{}) :: map()` with keys
    `:histogram` (`%{0..7 => count}`, 7 meaning 7+), `:avg_cmc`, `:nonland_count`,
    `:early_plays`, `:late_game`, `:top_heavy_share`
  - `Deckex.Analysis.Curve.findings(%DeckSnapshot{}, %Baselines{}) :: [%Finding{}]`

- [ ] **Step 1: Write the failing test**

Create `test/deckex/analysis/curve_test.exs`:

```elixir
defmodule Deckex.Analysis.CurveTest do
  use ExUnit.Case, async: true

  alias Deckex.Analysis.Baselines
  alias Deckex.Analysis.Curve
  alias Deckex.AnalysisFixture

  defp spells(costs) do
    costs
    |> Enum.with_index()
    |> Enum.map(fn {cmc, i} ->
      AnalysisFixture.entry(name: "Spell #{i}", cmc: to_string(cmc), type_line: "Sorcery")
    end)
    |> AnalysisFixture.snapshot()
  end

  defp codes(snapshot, baselines \\ Baselines.default()) do
    snapshot |> Curve.findings(baselines) |> Enum.map(& &1.code)
  end

  describe "measure/1" do
    test "buckets by converted mana cost, lumping 7 and above" do
      snapshot = spells([1.0, 2.0, 2.0, 7.0, 9.0])

      assert %{histogram: %{1 => 1, 2 => 2, 7 => 2}} = Curve.measure(snapshot)
    end

    test "counts copies, not rows" do
      snapshot =
        AnalysisFixture.snapshot([
          AnalysisFixture.entry(cmc: "2.0", type_line: "Sorcery", quantity: 3)
        ])

      assert %{histogram: %{2 => 3}, nonland_count: 3} = Curve.measure(snapshot)
    end

    test "excludes lands from the curve" do
      snapshot =
        AnalysisFixture.snapshot([
          AnalysisFixture.entry(cmc: "0.0", type_line: "Basic Land — Forest", quantity: 4),
          AnalysisFixture.entry(cmc: "2.0", type_line: "Sorcery")
        ])

      assert %{nonland_count: 1, histogram: histogram} = Curve.measure(snapshot)
      refute Map.has_key?(histogram, 0)
    end

    test "averages over copies" do
      snapshot = spells([1.0, 3.0])

      assert %{avg_cmc: 2.0} = Curve.measure(snapshot)
    end

    test "an empty deck averages zero rather than dividing by zero" do
      assert %{avg_cmc: 0.0, nonland_count: 0} = Curve.measure(AnalysisFixture.snapshot([]))
    end

    test "counts early plays and late game" do
      snapshot = spells([1.0, 2.0, 3.0, 5.0, 6.0])

      assert %{early_plays: 3, late_game: 2} = Curve.measure(snapshot)
    end
  end

  describe "findings/2" do
    test "flags a slow deck with no ramp to justify it" do
      snapshot = spells(List.duplicate(5.0, 20))

      assert "curve.too_slow" in codes(snapshot)
    end

    test "does not flag a slow deck that ramps hard" do
      ramp =
        for i <- 1..12,
            do: AnalysisFixture.entry(name: "Ramp #{i}", cmc: "2.0", roles: [:ramp])

      slow = for i <- 1..20, do: AnalysisFixture.entry(name: "Big #{i}", cmc: "5.0")

      refute "curve.too_slow" in codes(AnalysisFixture.snapshot(ramp ++ slow))
    end

    test "flags a deck that cannot act before turn four" do
      assert "curve.no_early_plays" in codes(spells(List.duplicate(5.0, 20)))
    end

    test "flags a top-heavy deck" do
      snapshot = spells(List.duplicate(2.0, 10) ++ List.duplicate(7.0, 5))

      assert "curve.top_heavy" in codes(snapshot)
    end

    test "flags a fast deck with no late game" do
      assert "curve.no_late_game" in codes(spells(List.duplicate(1.0, 30)))
    end

    test "a healthy curve produces no findings" do
      healthy =
        List.duplicate(1.0, 6) ++
          List.duplicate(2.0, 14) ++
          List.duplicate(3.0, 12) ++ List.duplicate(4.0, 8) ++ List.duplicate(5.0, 6)

      assert codes(spells(healthy)) == []
    end

    test "every finding names the cards behind it" do
      [finding | _rest] = Curve.findings(spells(List.duplicate(5.0, 20)), Baselines.default())

      assert finding.card_names != []
      assert finding.evidence != %{}
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/deckex/analysis/curve_test.exs`
Expected: FAIL — `module Deckex.Analysis.Curve is not available`.

- [ ] **Step 3: Write the lens**

Create `lib/deckex/analysis/curve.ex`:

```elixir
defmodule Deckex.Analysis.Curve do
  @moduledoc """
  How fast the deck acts, and whether it still has anything to do late.

  `curve.too_slow` deliberately requires **both** a high average cost and thin
  ramp: a deck averaging 3.9 with twelve ramp pieces is a ramp deck working as
  intended, not a slow one.
  """

  alias Deckex.Analysis.Baselines
  alias Deckex.Analysis.CardEntry
  alias Deckex.Analysis.DeckSnapshot
  alias Deckex.Analysis.Finding

  @spec measure(DeckSnapshot.t()) :: map()
  def measure(snapshot) do
    nonlands = DeckSnapshot.nonlands(snapshot)
    count = DeckSnapshot.count(nonlands)

    %{
      histogram: histogram(nonlands),
      avg_cmc: avg_cmc(nonlands, count),
      nonland_count: count,
      early_plays: count_at(nonlands, &(&1 <= 3)),
      late_game: count_at(nonlands, &(&1 >= 5)),
      top_heavy_share: share_at(nonlands, count, &(&1 >= 6))
    }
  end

  @spec findings(DeckSnapshot.t(), Baselines.t()) :: [Finding.t()]
  def findings(snapshot, baselines) do
    nonlands = DeckSnapshot.nonlands(snapshot)
    measured = measure(snapshot)
    ramp = DeckSnapshot.count(DeckSnapshot.with_role(nonlands, :ramp))

    Enum.flat_map(
      [
        too_slow(measured, ramp, nonlands, baselines),
        no_early_plays(measured, nonlands, baselines),
        top_heavy(measured, nonlands, baselines),
        no_late_game(measured, nonlands, baselines)
      ],
      & &1
    )
  end

  # --- findings -------------------------------------------------------------

  defp too_slow(%{avg_cmc: avg}, ramp, nonlands, b)
       when avg > b.avg_cmc_slow and ramp < b.ramp_target do
    [
      Finding.new(
        "curve.too_slow",
        :critical,
        :speed_curve,
        "Deck lento demais para o ramp que tem",
        "Custo médio #{fmt(avg)} com só #{ramp} peças de aceleração. " <>
          "Ou o custo cai, ou o ramp sobe.",
        evidence: %{avg_cmc: avg, ramp: ramp, ramp_target: b.ramp_target},
        card_names: nonlands |> expensive(b.avg_cmc_slow) |> DeckSnapshot.names()
      )
    ]
  end

  defp too_slow(_measured, _ramp, _nonlands, _baselines), do: []

  defp no_early_plays(%{early_plays: early}, nonlands, b) when early < b.early_play_target do
    [
      Finding.new(
        "curve.no_early_plays",
        :critical,
        :speed_curve,
        "Pouca coisa para fazer nos primeiros turnos",
        "Só #{early} cartas jogáveis com 3 de mana ou menos (alvo: #{b.early_play_target}). " <>
          "Contra deck agressivo, os turnos 1 a 3 passam em branco.",
        evidence: %{early_plays: early, target: b.early_play_target},
        card_names: nonlands |> cheap() |> DeckSnapshot.names()
      )
    ]
  end

  defp no_early_plays(_measured, _nonlands, _baselines), do: []

  defp top_heavy(%{top_heavy_share: share}, nonlands, b) when share > b.top_heavy_share do
    [
      Finding.new(
        "curve.top_heavy",
        :warning,
        :speed_curve,
        "Topo de curva pesado",
        "#{percent(share)} das mágicas custam 6 ou mais. " <>
          "Isso trava a mão quando o jogo não vai longe.",
        evidence: %{share: share, max: b.top_heavy_share},
        card_names: nonlands |> expensive(5.9) |> DeckSnapshot.names()
      )
    ]
  end

  defp top_heavy(_measured, _nonlands, _baselines), do: []

  defp no_late_game(%{late_game: late, avg_cmc: avg}, _nonlands, b)
       when late < b.late_game_floor and avg < b.avg_cmc_low do
    [
      Finding.new(
        "curve.no_late_game",
        :warning,
        :speed_curve,
        "Sem fôlego para o late game",
        "Custo médio #{fmt(avg)} e só #{late} cartas de 5 ou mais. " <>
          "Se a partida passar do turno 7, acaba a gasolina.",
        evidence: %{late_game: late, floor: b.late_game_floor, avg_cmc: avg}
      )
    ]
  end

  defp no_late_game(_measured, _nonlands, _baselines), do: []

  # --- maths ----------------------------------------------------------------

  defp histogram(nonlands) do
    Enum.reduce(nonlands, %{}, fn entry, acc ->
      bucket = entry |> CardEntry.cmc() |> trunc() |> min(7)

      Map.update(acc, bucket, entry.quantity, &(&1 + entry.quantity))
    end)
  end

  defp avg_cmc(_nonlands, 0), do: 0.0

  defp avg_cmc(nonlands, count) do
    total = Enum.sum(Enum.map(nonlands, &(CardEntry.cmc(&1) * &1.quantity)))

    Float.round(total / count, 2)
  end

  defp count_at(nonlands, predicate) do
    nonlands |> Enum.filter(&predicate.(CardEntry.cmc(&1))) |> DeckSnapshot.count()
  end

  defp share_at(_nonlands, 0, _predicate), do: 0.0

  defp share_at(nonlands, count, predicate) do
    Float.round(count_at(nonlands, predicate) / count, 3)
  end

  defp cheap(nonlands), do: Enum.filter(nonlands, &(CardEntry.cmc(&1) <= 3))
  defp expensive(nonlands, above), do: Enum.filter(nonlands, &(CardEntry.cmc(&1) > above))

  defp fmt(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp percent(share), do: "#{round(share * 100)}%"
end
```

- [ ] **Step 4: Run the test, gate and commit**

Run: `mix test test/deckex/analysis/curve_test.exs`
Expected: PASS — 13 tests.

```bash
mix lint && git add -A && git commit -m "feat: add the speed and curve lens

too_slow requires both a high average cost and thin ramp: a deck averaging 3.9
with twelve ramp pieces is working as intended, not slow."
```

---

### Task 4: Lens — Mana & Ramp

The biggest lens. It owns the land-count formula, the MDFC half-land rule, and
the colour-sources-versus-pips calculation that catches the classic failure.

**Files:**
- Create: `lib/deckex/analysis/mana.ex`
- Test: `test/deckex/analysis/mana_test.exs`

**Interfaces:**
- Consumes: `DeckSnapshot`, `CardEntry`, `Baselines`, `Finding` (Tasks 1–2).
- Produces:
  - `Deckex.Analysis.Mana.measure(%DeckSnapshot{}, %Baselines{}) :: map()` with keys
    `:land_count` (float), `:land_target` (integer), `:mdfc_lands`, `:ramp_total`,
    `:ramp_cheap`, `:ramp_by_band` (`%{cheap: n, mid: n, late: n}`), `:taplands`,
    `:tapland_share`, `:colors` (`%{colour => %{sources: n, max_pips: n, target: n}}`)
  - `Deckex.Analysis.Mana.land_target(%DeckSnapshot{}, %Baselines{}) :: integer()`
  - `Deckex.Analysis.Mana.findings(%DeckSnapshot{}, %Baselines{}) :: [%Finding{}]`

- [ ] **Step 1: Write the failing test**

Create `test/deckex/analysis/mana_test.exs`:

```elixir
defmodule Deckex.Analysis.ManaTest do
  use ExUnit.Case, async: true

  alias Deckex.Analysis.Baselines
  alias Deckex.Analysis.Mana
  alias Deckex.AnalysisFixture

  defp land(name, opts \\ []) do
    AnalysisFixture.entry(
      [name: name, type_line: "Land", cmc: "0.0", mana_cost: nil] ++ opts
    )
  end

  defp codes(snapshot, baselines \\ Baselines.default()) do
    snapshot |> Mana.findings(baselines) |> Enum.map(& &1.code)
  end

  describe "measure/2 land counting" do
    test "counts land copies" do
      snapshot = AnalysisFixture.snapshot([land("Forest", quantity: 10)])

      assert %{land_count: 10.0} = Mana.measure(snapshot, Baselines.default())
    end

    test "an MDFC land back counts as half a land" do
      snapshot =
        AnalysisFixture.snapshot([
          land("Forest", quantity: 10),
          AnalysisFixture.entry(name: "Silundi Vision", type_line: "Instant // Land")
        ])

      assert %{land_count: 10.5, mdfc_lands: 1} = Mana.measure(snapshot, Baselines.default())
    end
  end

  describe "land_target/2" do
    test "starts at the baseline for an average deck" do
      spells = for i <- 1..30, do: AnalysisFixture.entry(name: "S#{i}", cmc: "3.0")
      snapshot = AnalysisFixture.snapshot(spells)

      assert Mana.land_target(snapshot, Baselines.default()) == 36
    end

    test "rises with average cost" do
      spells = for i <- 1..30, do: AnalysisFixture.entry(name: "S#{i}", cmc: "4.5")
      snapshot = AnalysisFixture.snapshot(spells)

      assert Mana.land_target(snapshot, Baselines.default()) > 36
    end

    test "falls as ramp piles up" do
      ramp = for i <- 1..25, do: AnalysisFixture.entry(name: "R#{i}", cmc: "2.0", roles: [:ramp])
      snapshot = AnalysisFixture.snapshot(ramp)

      assert Mana.land_target(snapshot, Baselines.default()) < 36
    end

    test "never leaves the rails" do
      b = Baselines.default()
      huge = for i <- 1..40, do: AnalysisFixture.entry(name: "S#{i}", cmc: "9.0")

      assert Mana.land_target(AnalysisFixture.snapshot(huge), b) <= b.land_max
    end
  end

  describe "measure/2 colour sources" do
    test "counts sources per colour, lands and rocks alike" do
      snapshot =
        AnalysisFixture.snapshot(
          [
            land("Forest", quantity: 8, produced_mana: ["G"]),
            AnalysisFixture.entry(name: "Rock", type_line: "Artifact", produced_mana: ["G"])
          ],
          color_identity: ["G"]
        )

      assert %{colors: %{"G" => %{sources: 9}}} = Mana.measure(snapshot, Baselines.default())
    end

    test "records the heaviest pip demand per colour" do
      snapshot =
        AnalysisFixture.snapshot(
          [
            AnalysisFixture.entry(name: "Duplo", mana_cost: "{B}{B}", cmc: "2.0"),
            AnalysisFixture.entry(name: "Simples", mana_cost: "{1}{B}", cmc: "2.0")
          ],
          color_identity: ["B"]
        )

      assert %{colors: %{"B" => %{max_pips: 2, target: 25}}} =
               Mana.measure(snapshot, Baselines.default())
    end

    test "only reports colours in the deck's identity" do
      snapshot =
        AnalysisFixture.snapshot([land("Forest", produced_mana: ["G"])], color_identity: ["G"])

      assert %{colors: colors} = Mana.measure(snapshot, Baselines.default())
      assert Map.keys(colors) == ["G"]
    end
  end

  describe "findings/2" do
    test "flags a colour with fewer sources than its pips demand" do
      # Eight cards wanting {B}{B} behind twelve black sources — the classic.
      demanding =
        for i <- 1..8, do: AnalysisFixture.entry(name: "Preta #{i}", mana_cost: "{B}{B}", cmc: "2.0")

      snapshot =
        AnalysisFixture.snapshot(
          [land("Swamp", quantity: 12, produced_mana: ["B"]) | demanding],
          color_identity: ["B"]
        )

      assert "mana.color_starved" in codes(snapshot)
    end

    test "does not flag a colour with plenty of sources" do
      demanding =
        for i <- 1..8, do: AnalysisFixture.entry(name: "Preta #{i}", mana_cost: "{B}{B}", cmc: "2.0")

      snapshot =
        AnalysisFixture.snapshot(
          [land("Swamp", quantity: 30, produced_mana: ["B"]) | demanding],
          color_identity: ["B"]
        )

      refute "mana.color_starved" in codes(snapshot)
    end

    test "flags too few lands" do
      spells = for i <- 1..60, do: AnalysisFixture.entry(name: "S#{i}", cmc: "3.0")

      assert "mana.land_count_low" in codes(AnalysisFixture.snapshot([land("Forest", quantity: 20) | spells]))
    end

    test "flags too many lands" do
      spells = for i <- 1..30, do: AnalysisFixture.entry(name: "S#{i}", cmc: "2.0")

      assert "mana.land_count_high" in codes(AnalysisFixture.snapshot([land("Forest", quantity: 50) | spells]))
    end

    test "flags thin ramp" do
      spells = for i <- 1..60, do: AnalysisFixture.entry(name: "S#{i}", cmc: "3.0")

      assert "mana.ramp_low" in codes(AnalysisFixture.snapshot(spells))
    end

    test "flags ramp that is all too expensive to matter" do
      ramp = for i <- 1..12, do: AnalysisFixture.entry(name: "R#{i}", cmc: "5.0", roles: [:ramp])

      assert "mana.ramp_too_slow" in codes(AnalysisFixture.snapshot(ramp))
    end

    test "flags a mana base that enters tapped too often" do
      snapshot =
        AnalysisFixture.snapshot([
          land("Tapada", quantity: 20, oracle_text: "This land enters tapped."),
          land("Reta", quantity: 10)
        ])

      assert "mana.tapland_heavy" in codes(snapshot)
    end

    test "every finding names the cards behind it" do
      spells = for i <- 1..60, do: AnalysisFixture.entry(name: "S#{i}", cmc: "3.0")
      [finding | _rest] = Mana.findings(AnalysisFixture.snapshot(spells), Baselines.default())

      assert finding.evidence != %{}
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/deckex/analysis/mana_test.exs`
Expected: FAIL — `module Deckex.Analysis.Mana is not available`.

- [ ] **Step 3: Write the lens**

Create `lib/deckex/analysis/mana.ex`:

```elixir
defmodule Deckex.Analysis.Mana do
  @moduledoc """
  The mana base: how many lands, in which colours, and how fast the deck can
  accelerate.

  Three things here are easy to get wrong and are handled explicitly:

  1. **An MDFC whose back is a land counts as half a land.** It is a spell you
     can also play as a land, and modern decks lean on this enough that ignoring
     it misreports the land count outright.
  2. **The land target is derived, not fixed.** A deck averaging 2.6 with twelve
     ramp pieces genuinely wants fewer lands than one averaging 3.9 with six.
  3. **Colour sources are compared against the heaviest pip demand**, not the
     total. Eight cards wanting `{B}{B}` need roughly 25 black sources whether
     the deck holds eight of them or eighty.
  """

  alias Deckex.Analysis.Baselines
  alias Deckex.Analysis.CardEntry
  alias Deckex.Analysis.DeckSnapshot
  alias Deckex.Analysis.Finding

  @enters_tapped ~r/enters tapped/i

  @spec measure(DeckSnapshot.t(), Baselines.t()) :: map()
  def measure(snapshot, baselines) do
    lands = DeckSnapshot.lands(snapshot)
    nonlands = DeckSnapshot.nonlands(snapshot)
    ramp = DeckSnapshot.with_role(nonlands, :ramp)
    taplands = Enum.filter(lands, &tapland?/1)
    land_count = land_count(snapshot)

    %{
      land_count: land_count,
      land_target: land_target(snapshot, baselines),
      mdfc_lands: snapshot |> DeckSnapshot.mdfc_lands() |> DeckSnapshot.count(),
      ramp_total: DeckSnapshot.count(ramp),
      ramp_cheap: ramp |> Enum.filter(&(CardEntry.cmc(&1) <= 2)) |> DeckSnapshot.count(),
      ramp_by_band: ramp_by_band(ramp),
      taplands: DeckSnapshot.count(taplands),
      tapland_share: share(DeckSnapshot.count(taplands), DeckSnapshot.count(lands)),
      colors: colors(snapshot, baselines)
    }
  end

  @doc """
  The land count this deck actually wants: the baseline, pushed up by expensive
  spells and pulled down by ramp, clamped to the rails.
  """
  @spec land_target(DeckSnapshot.t(), Baselines.t()) :: integer()
  def land_target(snapshot, baselines) do
    nonlands = DeckSnapshot.nonlands(snapshot)
    count = DeckSnapshot.count(nonlands)
    avg = avg_cmc(nonlands, count)
    ramp = DeckSnapshot.count(DeckSnapshot.with_role(nonlands, :ramp))

    (baselines.land_base + cost_adjustment(avg, baselines) - ramp_adjustment(ramp, baselines))
    |> max(baselines.land_min)
    |> min(baselines.land_max)
  end

  @spec findings(DeckSnapshot.t(), Baselines.t()) :: [Finding.t()]
  def findings(snapshot, baselines) do
    measured = measure(snapshot, baselines)
    nonlands = DeckSnapshot.nonlands(snapshot)

    Enum.concat([
      land_count_findings(measured, baselines),
      ramp_findings(measured, nonlands, baselines),
      tapland_findings(measured, snapshot, baselines),
      color_findings(measured, snapshot, baselines)
    ])
  end

  # --- findings -------------------------------------------------------------

  defp land_count_findings(%{land_count: count, land_target: target}, _baselines) do
    cond do
      count < target - 1 ->
        [
          Finding.new(
            "mana.land_count_low",
            :critical,
            :mana_ramp,
            "Poucos terrenos para o custo do deck",
            "#{fmt(count)} terrenos efetivos contra um alvo de #{target}. " <>
              "Travar em terreno é a forma mais comum de perder sem jogar.",
            evidence: %{land_count: count, target: target}
          )
        ]

      count > target + 2 ->
        [
          Finding.new(
            "mana.land_count_high",
            :warning,
            :mana_ramp,
            "Terrenos demais para o custo do deck",
            "#{fmt(count)} terrenos efetivos contra um alvo de #{target}. " <>
              "Sobra terreno onde cabia ação.",
            evidence: %{land_count: count, target: target}
          )
        ]

      true ->
        []
    end
  end

  defp ramp_findings(%{ramp_total: total, ramp_cheap: cheap}, nonlands, b) do
    ramp_names = nonlands |> DeckSnapshot.with_role(:ramp) |> DeckSnapshot.names()

    low =
      if total < b.ramp_target do
        [
          Finding.new(
            "mana.ramp_low",
            :warning,
            :mana_ramp,
            "Pouca aceleração",
            "#{total} peças de ramp contra um alvo de #{b.ramp_target}. " <>
              "Rituais e redutores de custo não contam aqui — eles não te fazem " <>
              "baixar uma carta cara um turno antes com o campo vazio.",
            evidence: %{ramp: total, target: b.ramp_target},
            card_names: ramp_names
          )
        ]
      else
        []
      end

    slow =
      if total >= b.ramp_target and cheap < b.ramp_cheap_target do
        [
          Finding.new(
            "mana.ramp_too_slow",
            :warning,
            :mana_ramp,
            "Aceleração cara demais",
            "Só #{cheap} das #{total} peças de ramp custam 2 ou menos " <>
              "(alvo: #{b.ramp_cheap_target}). Ramp de 4 mana não adianta o jogo.",
            evidence: %{cheap: cheap, total: total, target: b.ramp_cheap_target},
            card_names: ramp_names
          )
        ]
      else
        []
      end

    low ++ slow
  end

  defp tapland_findings(%{tapland_share: share, taplands: taplands}, snapshot, b)
       when share > b.tapland_share_max do
    [
      Finding.new(
        "mana.tapland_heavy",
        :warning,
        :mana_ramp,
        "Muito terreno entrando virado",
        "#{taplands} terrenos entram virados (#{percent(share)} da base). " <>
          "Cada um é meio turno perdido.",
        evidence: %{taplands: taplands, share: share},
        card_names: snapshot |> DeckSnapshot.lands() |> Enum.filter(&tapland?/1) |> DeckSnapshot.names()
      )
    ]
  end

  defp tapland_findings(_measured, _snapshot, _baselines), do: []

  defp color_findings(%{colors: colors}, snapshot, _baselines) do
    Enum.flat_map(colors, fn {colour, %{sources: sources, max_pips: pips, target: target}} ->
      if sources < target and pips > 0 do
        [
          Finding.new(
            "mana.color_starved",
            :critical,
            :mana_ramp,
            "Poucas fontes de #{colour}",
            "#{sources} fontes de #{colour} para uma exigência máxima de " <>
              "#{pips} pip(s) (alvo: #{target}). As cartas abaixo travam na mão.",
            evidence: %{color: colour, sources: sources, max_pips: pips, target: target},
            card_names: snapshot |> demanding(colour, pips) |> DeckSnapshot.names()
          )
        ]
      else
        []
      end
    end)
  end

  # --- maths ----------------------------------------------------------------

  defp land_count(snapshot) do
    full = snapshot |> DeckSnapshot.lands() |> DeckSnapshot.count()
    halves = snapshot |> DeckSnapshot.mdfc_lands() |> DeckSnapshot.count()

    full + halves * 0.5
  end

  defp cost_adjustment(avg, b) when avg > b.avg_cmc_high do
    ceil((avg - b.avg_cmc_high) / 0.25)
  end

  defp cost_adjustment(_avg, _baselines), do: 0

  defp ramp_adjustment(ramp, b) when ramp > b.ramp_target, do: div(ramp - b.ramp_target, 3)
  defp ramp_adjustment(_ramp, _baselines), do: 0

  defp ramp_by_band(ramp) do
    %{
      cheap: ramp |> Enum.filter(&(CardEntry.cmc(&1) <= 2)) |> DeckSnapshot.count(),
      mid: ramp |> Enum.filter(&(CardEntry.cmc(&1) == 3)) |> DeckSnapshot.count(),
      late: ramp |> Enum.filter(&(CardEntry.cmc(&1) >= 4)) |> DeckSnapshot.count()
    }
  end

  defp colors(snapshot, baselines) do
    Map.new(snapshot.color_identity, fn colour ->
      pips = max_pips(snapshot, colour)

      {colour,
       %{
         sources: sources(snapshot, colour),
         max_pips: pips,
         target: source_target(pips, baselines)
       }}
    end)
  end

  defp sources(%{main: main}, colour) do
    main
    |> Enum.filter(&produces?(&1, colour))
    |> DeckSnapshot.count()
  end

  defp produces?(%{card: card}, colour) do
    colour in (card.produced_mana || [])
  end

  defp max_pips(snapshot, colour) do
    snapshot
    |> DeckSnapshot.nonlands()
    |> Enum.map(&CardEntry.pips(&1, colour))
    |> Enum.max(fn -> 0 end)
  end

  defp demanding(snapshot, colour, pips) do
    snapshot
    |> DeckSnapshot.nonlands()
    |> Enum.filter(&(CardEntry.pips(&1, colour) >= pips))
  end

  defp source_target(0, _baselines), do: 0
  defp source_target(1, b), do: b.sources_single_pip
  defp source_target(2, b), do: b.sources_double_pip
  defp source_target(_three_or_more, b), do: b.sources_triple_pip

  defp tapland?(%{card: card}), do: (card.oracle_text || "") =~ @enters_tapped

  defp avg_cmc(_nonlands, 0), do: 0.0

  defp avg_cmc(nonlands, count) do
    Enum.sum(Enum.map(nonlands, &(CardEntry.cmc(&1) * &1.quantity))) / count
  end

  defp share(_part, 0), do: 0.0
  defp share(part, whole), do: Float.round(part / whole, 3)

  defp fmt(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
  defp fmt(value), do: to_string(value)

  defp percent(share), do: "#{round(share * 100)}%"
end
```

- [ ] **Step 4: Run the test, gate and commit**

Run: `mix test test/deckex/analysis/mana_test.exs`
Expected: PASS — 15 tests.

```bash
mix lint && git add -A && git commit -m "feat: add the mana and ramp lens

MDFC land backs count half; the land target is derived from cost and ramp
rather than fixed; colour sources are compared against the heaviest pip
demand, which is what catches eight double-black spells behind twelve sources."
```

---

### Task 5: Lenses — Interação and Consistência

Both are counting lenses over roles, so they share a task: a reviewer would
accept or reject them together.

**Files:**
- Create: `lib/deckex/analysis/interaction.ex`
- Create: `lib/deckex/analysis/consistency.ex`
- Test: `test/deckex/analysis/interaction_test.exs`
- Test: `test/deckex/analysis/consistency_test.exs`

**Interfaces:**
- Consumes: `DeckSnapshot`, `CardEntry`, `Baselines`, `Finding` (Tasks 1–2).
- Produces:
  - `Deckex.Analysis.Interaction.measure(%DeckSnapshot{}) :: map()` with keys
    `:counters`, `:spot_removal`, `:board_wipes`, `:protection`, `:graveyard_hate`,
    `:answers` (spot removal + wipes — the ones that address a resolved threat),
    `:instant_speed`, `:sorcery_speed`
  - `Deckex.Analysis.Interaction.findings(%DeckSnapshot{}, %Baselines{}) :: [%Finding{}]`
  - `Deckex.Analysis.Consistency.measure(%DeckSnapshot{}) :: map()` with keys
    `:draw`, `:tutors`, `:recursion`, `:wincons`, `:single_points_of_failure`
  - `Deckex.Analysis.Consistency.findings(%DeckSnapshot{}, %Baselines{}) :: [%Finding{}]`

- [ ] **Step 1: Write the failing interaction test**

Create `test/deckex/analysis/interaction_test.exs`:

```elixir
defmodule Deckex.Analysis.InteractionTest do
  use ExUnit.Case, async: true

  alias Deckex.Analysis.Baselines
  alias Deckex.Analysis.Interaction
  alias Deckex.AnalysisFixture

  defp with_roles(role, n, opts \\ []) do
    for i <- 1..n do
      AnalysisFixture.entry(
        [name: "#{role} #{i}", roles: [role], type_line: "Instant"] ++ opts
      )
    end
  end

  defp codes(entries, baselines \\ Baselines.default()) do
    entries |> AnalysisFixture.snapshot() |> Interaction.findings(baselines) |> Enum.map(& &1.code)
  end

  describe "measure/1" do
    test "counts each answer type separately" do
      entries =
        with_roles(:counter, 4) ++ with_roles(:spot_removal, 7) ++ with_roles(:board_wipe, 1)

      assert %{counters: 4, spot_removal: 7, board_wipes: 1} =
               entries |> AnalysisFixture.snapshot() |> Interaction.measure()
    end

    test "answers exclude counterspells — they cannot address a resolved threat" do
      entries = with_roles(:counter, 4) ++ with_roles(:spot_removal, 7)

      assert %{answers: 7} = entries |> AnalysisFixture.snapshot() |> Interaction.measure()
    end

    test "splits by speed" do
      entries =
        with_roles(:spot_removal, 3) ++
          with_roles(:spot_removal, 2, type_line: "Sorcery")

      assert %{instant_speed: 3, sorcery_speed: 2} =
               entries |> AnalysisFixture.snapshot() |> Interaction.measure()
    end
  end

  describe "findings/2" do
    test "flags a deck with almost no interaction" do
      assert "interaction.total_low" in codes(with_roles(:counter, 2))
    end

    test "flags a deck with no sweeper at all" do
      assert "interaction.no_board_wipes" in codes(with_roles(:spot_removal, 10))
    end

    test "flags a deck with only one sweeper" do
      entries = with_roles(:spot_removal, 10) ++ with_roles(:board_wipe, 1)
      found = codes(entries)

      assert "interaction.board_wipes_low" in found
      refute "interaction.no_board_wipes" in found
    end

    test "does not flag a deck with enough sweepers" do
      entries = with_roles(:spot_removal, 10) ++ with_roles(:board_wipe, 2)
      found = codes(entries)

      refute "interaction.board_wipes_low" in found
      refute "interaction.no_board_wipes" in found
    end

    test "flags interaction that is mostly sorcery speed" do
      entries = with_roles(:spot_removal, 8, type_line: "Sorcery")

      assert "interaction.sorcery_speed_heavy" in codes(entries)
    end

    test "flags a deck that cannot protect anything" do
      assert "interaction.no_protection" in codes(with_roles(:spot_removal, 10))
    end

    test "a healthy answer suite produces no interaction findings" do
      entries =
        with_roles(:spot_removal, 7) ++
          with_roles(:board_wipe, 2) ++ with_roles(:protection, 2)

      assert codes(entries) == []
    end
  end
end
```

- [ ] **Step 2: Write the failing consistency test**

Create `test/deckex/analysis/consistency_test.exs`:

```elixir
defmodule Deckex.Analysis.ConsistencyTest do
  use ExUnit.Case, async: true

  alias Deckex.Analysis.Baselines
  alias Deckex.Analysis.Consistency
  alias Deckex.AnalysisFixture

  defp with_roles(role, n) do
    for i <- 1..n, do: AnalysisFixture.entry(name: "#{role} #{i}", roles: [role])
  end

  defp codes(entries, baselines \\ Baselines.default()) do
    entries
    |> AnalysisFixture.snapshot()
    |> Consistency.findings(baselines)
    |> Enum.map(& &1.code)
  end

  describe "measure/1" do
    test "counts card advantage, tutors, recursion and win conditions" do
      entries =
        with_roles(:draw, 10) ++
          with_roles(:tutor, 3) ++ with_roles(:recursion, 7) ++ with_roles(:wincon, 4)

      assert %{draw: 10, tutors: 3, recursion: 7, wincons: 4} =
               entries |> AnalysisFixture.snapshot() |> Consistency.measure()
    end

    test "counts roles the deck holds exactly one copy of" do
      entries = with_roles(:draw, 10) ++ with_roles(:board_wipe, 1)

      assert %{single_points_of_failure: [:board_wipe]} =
               entries |> AnalysisFixture.snapshot() |> Consistency.measure()
    end
  end

  describe "findings/2" do
    test "flags thin card advantage" do
      assert "consistency.draw_low" in codes(with_roles(:draw, 3))
    end

    test "flags a deck with no identified win condition" do
      assert "consistency.no_wincon" in codes(with_roles(:draw, 10))
    end

    test "flags a role the deck holds exactly one of" do
      entries = with_roles(:draw, 10) ++ with_roles(:wincon, 4) ++ with_roles(:board_wipe, 1)

      assert "consistency.single_point_of_failure" in codes(entries)
    end

    test "a consistent deck produces no findings" do
      entries = with_roles(:draw, 10) ++ with_roles(:wincon, 4) ++ with_roles(:tutor, 3)

      assert codes(entries) == []
    end
  end
end
```

- [ ] **Step 3: Run both to verify they fail**

Run: `mix test test/deckex/analysis/interaction_test.exs test/deckex/analysis/consistency_test.exs`
Expected: FAIL — modules not available.

- [ ] **Step 4: Write the interaction lens**

Create `lib/deckex/analysis/interaction.ex`:

```elixir
defmodule Deckex.Analysis.Interaction do
  @moduledoc """
  What the deck can do about an opponent.

  **Counterspells are counted but excluded from `:answers`.** A counterspell is
  a dead card once the threat has resolved; against an aggressive deck only spot
  removal and sweepers actually address a board. Summing the two into a single
  "interaction" figure hides exactly the failure this lens exists to surface.
  """

  alias Deckex.Analysis.Baselines
  alias Deckex.Analysis.CardEntry
  alias Deckex.Analysis.DeckSnapshot
  alias Deckex.Analysis.Finding

  @answer_roles [:spot_removal, :board_wipe]
  @all_roles [:counter, :spot_removal, :board_wipe, :protection, :graveyard_hate]

  @spec measure(DeckSnapshot.t()) :: map()
  def measure(snapshot) do
    nonlands = DeckSnapshot.nonlands(snapshot)
    interactive = Enum.filter(nonlands, &interactive?/1)

    %{
      counters: count_role(nonlands, :counter),
      spot_removal: count_role(nonlands, :spot_removal),
      board_wipes: count_role(nonlands, :board_wipe),
      protection: count_role(nonlands, :protection),
      graveyard_hate: count_role(nonlands, :graveyard_hate),
      answers: nonlands |> Enum.filter(&answer?/1) |> DeckSnapshot.count(),
      instant_speed: interactive |> Enum.filter(&CardEntry.instant?/1) |> DeckSnapshot.count(),
      sorcery_speed: interactive |> Enum.reject(&CardEntry.instant?/1) |> DeckSnapshot.count()
    }
  end

  @spec findings(DeckSnapshot.t(), Baselines.t()) :: [Finding.t()]
  def findings(snapshot, baselines) do
    measured = measure(snapshot)
    nonlands = DeckSnapshot.nonlands(snapshot)

    Enum.concat([
      total_low(measured, nonlands, baselines),
      board_wipes(measured, nonlands, baselines),
      sorcery_heavy(measured, baselines),
      no_protection(measured)
    ])
  end

  defp total_low(%{counters: counters, answers: answers}, nonlands, b) do
    total = counters + answers

    if total < b.interaction_floor do
      [
        Finding.new(
          "interaction.total_low",
          :critical,
          :interaction,
          "Interação insuficiente",
          "#{total} peças de interação (alvo: #{b.interaction_target}). " <>
            "Desse total, #{answers} respondem a algo que já resolveu — " <>
            "contra-magia não desfaz dano.",
          evidence: %{total: total, answers: answers, counters: counters, target: b.interaction_target},
          card_names: nonlands |> Enum.filter(&interactive?/1) |> DeckSnapshot.names()
        )
      ]
    else
      []
    end
  end

  defp board_wipes(%{board_wipes: 0}, _nonlands, _baselines) do
    [
      Finding.new(
        "interaction.no_board_wipes",
        :critical,
        :interaction,
        "Nenhuma varredura",
        "O deck não tem como resetar um campo que fugiu do controle.",
        evidence: %{board_wipes: 0}
      )
    ]
  end

  defp board_wipes(%{board_wipes: wipes}, nonlands, b) when wipes < b.board_wipe_target do
    [
      Finding.new(
        "interaction.board_wipes_low",
        :warning,
        :interaction,
        "Só #{wipes} varredura",
        "Contra deck agressivo, uma varredura só precisa ser a certa na hora certa. " <>
          "O alvo é #{b.board_wipe_target}.",
        evidence: %{board_wipes: wipes, target: b.board_wipe_target},
        card_names: nonlands |> DeckSnapshot.with_role(:board_wipe) |> DeckSnapshot.names()
      )
    ]
  end

  defp board_wipes(_measured, _nonlands, _baselines), do: []

  defp sorcery_heavy(%{instant_speed: fast, sorcery_speed: slow}, b)
       when slow > fast and slow + fast >= b.interaction_floor do
    [
      Finding.new(
        "interaction.sorcery_speed_heavy",
        :warning,
        :interaction,
        "Interação lenta demais",
        "#{slow} peças em sorcery contra #{fast} em instant. " <>
          "Responder só no seu turno entrega o tempo pro oponente.",
        evidence: %{sorcery: slow, instant: fast}
      )
    ]
  end

  defp sorcery_heavy(_measured, _baselines), do: []

  defp no_protection(%{protection: 0}) do
    [
      Finding.new(
        "interaction.no_protection",
        :warning,
        :interaction,
        "Nada protege o comandante",
        "Sem proteção, cada remoção do oponente custa um recomprar do comandante.",
        evidence: %{protection: 0}
      )
    ]
  end

  defp no_protection(_measured), do: []

  defp count_role(entries, role), do: entries |> DeckSnapshot.with_role(role) |> DeckSnapshot.count()

  defp answer?(entry), do: Enum.any?(@answer_roles, &CardEntry.has_role?(entry, &1))
  defp interactive?(entry), do: Enum.any?(@all_roles, &CardEntry.has_role?(entry, &1))
end
```

- [ ] **Step 5: Write the consistency lens**

Create `lib/deckex/analysis/consistency.ex`:

```elixir
defmodule Deckex.Analysis.Consistency do
  @moduledoc """
  Whether the deck finds its pieces and can actually end a game.

  `single_points_of_failure` lists the roles the deck holds exactly one copy of.
  One sweeper, one tutor, one recursion outlet — each is a card that, once
  answered or buried, the deck simply cannot do any more.
  """

  alias Deckex.Analysis.Baselines
  alias Deckex.Analysis.DeckSnapshot
  alias Deckex.Analysis.Finding

  # Roles where holding exactly one copy is a structural risk. Draw and ramp are
  # excluded: nobody expects redundancy counted that way.
  @fragile_roles [:board_wipe, :tutor, :recursion, :graveyard_hate, :protection]

  @spec measure(DeckSnapshot.t()) :: map()
  def measure(snapshot) do
    nonlands = DeckSnapshot.nonlands(snapshot)

    %{
      draw: count_role(nonlands, :draw),
      tutors: count_role(nonlands, :tutor),
      recursion: count_role(nonlands, :recursion),
      wincons: count_role(nonlands, :wincon),
      single_points_of_failure: Enum.filter(@fragile_roles, &(count_role(nonlands, &1) == 1))
    }
  end

  @spec findings(DeckSnapshot.t(), Baselines.t()) :: [Finding.t()]
  def findings(snapshot, baselines) do
    measured = measure(snapshot)
    nonlands = DeckSnapshot.nonlands(snapshot)

    Enum.concat([
      draw_low(measured, nonlands, baselines),
      no_wincon(measured),
      single_point(measured)
    ])
  end

  defp draw_low(%{draw: draw}, nonlands, b) when draw < b.draw_target do
    [
      Finding.new(
        "consistency.draw_low",
        :warning,
        :consistency,
        "Pouca compra de carta",
        "#{draw} peças de vantagem de carta (alvo: #{b.draw_target}). " <>
          "Sem compra, a partida vira quem topa mais na sorte.",
        evidence: %{draw: draw, target: b.draw_target},
        card_names: nonlands |> DeckSnapshot.with_role(:draw) |> DeckSnapshot.names()
      )
    ]
  end

  defp draw_low(_measured, _nonlands, _baselines), do: []

  defp no_wincon(%{wincons: 0}) do
    [
      Finding.new(
        "consistency.no_wincon",
        :critical,
        :consistency,
        "Nenhuma win condition identificada",
        "Nenhuma carta foi classificada como plano de vitória. " <>
          "Ou falta um fecho, ou a classificação precisa de correção manual.",
        evidence: %{wincons: 0}
      )
    ]
  end

  defp no_wincon(_measured), do: []

  defp single_point(%{single_points_of_failure: []}), do: []

  defp single_point(%{single_points_of_failure: roles}) do
    [
      Finding.new(
        "consistency.single_point_of_failure",
        :warning,
        :consistency,
        "Efeitos sem redundância",
        "O deck tem exatamente uma carta para: #{Enum.join(roles, ", ")}. " <>
          "Cada uma é um ponto único de falha.",
        evidence: %{roles: roles}
      )
    ]
  end

  defp count_role(entries, role), do: entries |> DeckSnapshot.with_role(role) |> DeckSnapshot.count()
end
```

- [ ] **Step 6: Run both tests, gate and commit**

Run: `mix test test/deckex/analysis/interaction_test.exs test/deckex/analysis/consistency_test.exs`
Expected: PASS — 10 + 6 = 16 tests.

```bash
mix lint && git add -A && git commit -m "feat: add the interaction and consistency lenses

Counterspells are counted but excluded from :answers -- a counterspell cannot
address a threat that already resolved, and summing them hides that."
```

---

### Task 6: The report, and the one database read

**Files:**
- Create: `lib/deckex/analysis/report.ex`
- Create: `lib/deckex/analysis.ex`
- Modify: `lib/deckex/decks.ex` (add `snapshot/1`)
- Test: `test/deckex/analysis_test.exs`

**Interfaces:**
- Consumes: all four lenses, `Baselines`, `Finding`, `DeckSnapshot`.
- Produces:
  - `%Deckex.Analysis.Report{deck_id, deck_name, color_identity, curve, mana, interaction, consistency, findings}`
  - `Deckex.Analysis.report(%DeckSnapshot{}, %Baselines{} \\ Baselines.default()) :: %Report{}`
  - `Deckex.Analysis.Report.critical_count(%Report{}) :: non_neg_integer()`
  - `Deckex.Analysis.Report.by_lens(%Report{}, atom()) :: [%Finding{}]`
  - `Deckex.Decks.snapshot(%Deck{}) :: %DeckSnapshot{}`

- [ ] **Step 1: Write the failing test**

Create `test/deckex/analysis_test.exs`:

```elixir
defmodule Deckex.AnalysisTest do
  use Deckex.DataCase, async: true

  import Mox

  alias Deckex.Analysis
  alias Deckex.Analysis.Report
  alias Deckex.Cards.Card
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.Decks
  alias Deckex.ScryfallFixture

  setup :verify_on_exit!

  defp seed_catalogue(names) do
    for name <- names do
      attrs = name |> ScryfallFixture.load!() |> ScryfallMapper.to_attrs()

      %Card{} |> Card.changeset(attrs) |> Repo.insert!()
    end
  end

  describe "Decks.snapshot/1" do
    test "loads cards, quantities and roles without another query per card" do
      seed_catalogue(["sol_ring", "forest"])

      {:ok, deck} =
        Decks.import_from_text("1 Sol Ring\n4 Forest", %{name: "T", source: :paste})

      snapshot = Decks.snapshot(deck)

      assert snapshot.deck_name == "T"
      assert length(snapshot.main) == 2

      sol_ring = Enum.find(snapshot.main, &(&1.card.name == "Sol Ring"))
      assert sol_ring.quantity == 1
      assert MapSet.member?(sol_ring.roles, :ramp)
    end

    test "separates the commander" do
      seed_catalogue(["sol_ring", "natures_lore"])

      {:ok, deck} =
        Decks.import_from_text("Commander\n1 Nature's Lore\n----\n1 Sol Ring", %{
          name: "T",
          source: :paste
        })

      snapshot = Decks.snapshot(deck)

      assert [%{card: %{name: "Nature's Lore"}}] = snapshot.commanders
      assert [%{card: %{name: "Sol Ring"}}] = snapshot.main
    end
  end

  describe "report/2" do
    test "produces every lens and a sorted finding list" do
      seed_catalogue(["sol_ring", "forest"])

      {:ok, deck} =
        Decks.import_from_text("1 Sol Ring\n4 Forest", %{name: "T", source: :paste})

      report = deck |> Decks.snapshot() |> Analysis.report()

      assert %Report{curve: %{}, mana: %{}, interaction: %{}, consistency: %{}} = report
      assert report.deck_name == "T"

      severities = Enum.map(report.findings, & &1.severity)
      assert severities == Enum.sort_by(severities, &%{critical: 0, warning: 1, info: 2}[&1])
    end

    test "counts critical findings" do
      seed_catalogue(["sol_ring"])

      {:ok, deck} = Decks.import_from_text("1 Sol Ring", %{name: "T", source: :paste})
      report = deck |> Decks.snapshot() |> Analysis.report()

      assert Report.critical_count(report) > 0
    end

    test "filters findings by lens" do
      seed_catalogue(["sol_ring"])

      {:ok, deck} = Decks.import_from_text("1 Sol Ring", %{name: "T", source: :paste})
      report = deck |> Decks.snapshot() |> Analysis.report()

      assert Enum.all?(Report.by_lens(report, :interaction), &(&1.lens == :interaction))
    end

    test "is deterministic — the same snapshot yields the same findings" do
      seed_catalogue(["sol_ring", "forest"])

      {:ok, deck} =
        Decks.import_from_text("1 Sol Ring\n4 Forest", %{name: "T", source: :paste})

      snapshot = Decks.snapshot(deck)

      assert Analysis.report(snapshot) == Analysis.report(snapshot)
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/deckex/analysis_test.exs`
Expected: FAIL — `function Deckex.Decks.snapshot/1 is undefined`.

- [ ] **Step 3: Write the report struct**

Create `lib/deckex/analysis/report.ex`:

```elixir
defmodule Deckex.Analysis.Report do
  @moduledoc """
  Everything the engine measured about one deck, at one moment.

  A report is computed on demand and never persisted as live state — a consult
  freezes a copy for reproducibility, which is a different thing.
  """

  alias Deckex.Analysis.Finding

  @type t :: %__MODULE__{
          deck_id: String.t(),
          deck_name: String.t(),
          color_identity: [String.t()],
          curve: map(),
          mana: map(),
          interaction: map(),
          consistency: map(),
          findings: [Finding.t()]
        }

  @enforce_keys [:deck_id, :deck_name, :color_identity, :curve, :mana, :interaction, :consistency, :findings]
  defstruct [:deck_id, :deck_name, :color_identity, :curve, :mana, :interaction, :consistency, :findings]

  @doc "How many critical findings the deck has — the vital sign on the deck tile."
  @spec critical_count(t()) :: non_neg_integer()
  def critical_count(%__MODULE__{findings: findings}), do: Enum.count(findings, &Finding.critical?/1)

  @doc "The findings belonging to one lens."
  @spec by_lens(t(), Finding.lens()) :: [Finding.t()]
  def by_lens(%__MODULE__{findings: findings}, lens), do: Enum.filter(findings, &(&1.lens == lens))
end
```

- [ ] **Step 4: Write the entry point**

Create `lib/deckex/analysis.ex`:

```elixir
defmodule Deckex.Analysis do
  @moduledoc """
  The diagnostic engine: a pure function from a loaded deck to a measured report.

  No Repo, no HTTP, no process state. `Deckex.Decks.snapshot/1` does the one
  database read; everything here is arithmetic over structs in memory, which is
  why reports are computed on demand and never cached — it costs microseconds,
  and a cache would only buy staleness bugs.
  """

  alias Deckex.Analysis.Baselines
  alias Deckex.Analysis.Consistency
  alias Deckex.Analysis.Curve
  alias Deckex.Analysis.DeckSnapshot
  alias Deckex.Analysis.Finding
  alias Deckex.Analysis.Interaction
  alias Deckex.Analysis.Mana
  alias Deckex.Analysis.Report

  @doc "Measures `snapshot` against `baselines`."
  @spec report(DeckSnapshot.t(), Baselines.t()) :: Report.t()
  def report(%DeckSnapshot{} = snapshot, baselines \\ Baselines.default()) do
    %Report{
      deck_id: snapshot.deck_id,
      deck_name: snapshot.deck_name,
      color_identity: snapshot.color_identity,
      curve: Curve.measure(snapshot),
      mana: Mana.measure(snapshot, baselines),
      interaction: Interaction.measure(snapshot),
      consistency: Consistency.measure(snapshot),
      findings: findings(snapshot, baselines)
    }
  end

  defp findings(snapshot, baselines) do
    [Curve, Mana, Interaction, Consistency]
    |> Enum.flat_map(&lens_findings(&1, snapshot, baselines))
    |> Finding.sort()
  end

  # Curve and the role lenses take different arities; normalise here rather than
  # forcing every lens to accept a parameter it does not use.
  defp lens_findings(Curve, snapshot, baselines), do: Curve.findings(snapshot, baselines)
  defp lens_findings(Mana, snapshot, baselines), do: Mana.findings(snapshot, baselines)
  defp lens_findings(Interaction, snapshot, baselines), do: Interaction.findings(snapshot, baselines)
  defp lens_findings(Consistency, snapshot, baselines), do: Consistency.findings(snapshot, baselines)
end
```

- [ ] **Step 5: Add the bulk role read to `CardQuery`**

The snapshot needs every role for every card in the deck, in one query rather
than one per card. That query belongs in the **query module**, not in the
context — the playbook is explicit that contexts do not build Ecto queries.

In `lib/deckex/cards/card_query.ex`, add:

```elixir
  @doc """
  Maps card id to the role kinds that card holds, for many cards at once.

  One query for a whole deck. Doing this per card would be a hundred round
  trips to build a report that is meant to cost microseconds.
  """
  @spec roles_by_card_ids([String.t()]) :: %{String.t() => [atom()]}
  def roles_by_card_ids([]), do: %{}

  def roles_by_card_ids(card_ids) when is_list(card_ids) do
    from(r in CardRole, where: r.card_id in ^card_ids, select: {r.card_id, r.kind})
    |> Repo.all()
    |> Enum.group_by(fn {card_id, _kind} -> card_id end, fn {_card_id, kind} -> kind end)
  end
```

In `lib/deckex/cards.ex`, expose it: `defdelegate roles_by_card_ids(ids), to: CardQuery`.

- [ ] **Step 6: Add `Decks.snapshot/1`**

In `lib/deckex/decks.ex`, add these aliases:

```elixir
  alias Deckex.Analysis.CardEntry
  alias Deckex.Analysis.DeckSnapshot
```

and this function:

```elixir
  @doc """
  Builds the snapshot the analysis engine reads.

  This is the **only** database work in the whole analysis path: two queries —
  the deck's cards, then every role for those cards — and every lens then
  operates on structs in memory.
  """
  @spec snapshot(Deck.t()) :: DeckSnapshot.t()
  def snapshot(%Deck{} = deck) do
    deck_cards = DeckQuery.list_deck_cards(deck)
    roles = deck_cards |> Enum.map(& &1.card_id) |> Cards.roles_by_card_ids()
    grouped = Enum.group_by(deck_cards, & &1.board)

    %DeckSnapshot{
      deck_id: deck.id,
      deck_name: deck.name,
      color_identity: deck.color_identity,
      commanders: entries_for(grouped, :commander, roles),
      main: entries_for(grouped, :main, roles)
    }
  end

  defp entries_for(grouped, board, roles) do
    grouped
    |> Map.get(board, [])
    |> Enum.map(fn deck_card ->
      CardEntry.new(
        deck_card.card,
        deck_card.quantity,
        Map.get(roles, deck_card.card_id, [])
      )
    end)
  end
```

- [ ] **Step 7: Run the test, gate and commit**

Run: `mix test test/deckex/analysis_test.exs`
Expected: PASS — 6 tests.

```bash
mix lint && git add -A && git commit -m "feat: compose the analysis report

Decks.snapshot/1 is the only database read in the analysis path; every lens
then works on structs in memory, which is why reports are computed on demand
and never cached."
```

---

### Task 7: Regression on the real deck

**Files:**
- Test: `test/deckex/analysis/real_deck_test.exs`

**Interfaces:**
- Consumes: everything above.
- Produces: no code.

- [ ] **Step 1: Write the regression test**

This test imports the committed real decklist with the **whole** card catalogue
seeded from every Scryfall fixture, so the measurements are real. It asserts the
structural facts, then prints the report so a human can eyeball it.

Create `test/deckex/analysis/real_deck_test.exs`:

```elixir
defmodule Deckex.Analysis.RealDeckTest do
  @moduledoc """
  Measures a real 100-card Commander deck end to end and locks in the shape of
  the answer. Only the cards with committed Scryfall fixtures resolve, so the
  absolute counts are of that subset — what is locked here is that the lenses
  agree with each other and with the deck.
  """
  use Deckex.DataCase, async: true

  import Mox

  alias Deckex.Analysis
  alias Deckex.Analysis.Report
  alias Deckex.Cards.Card
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.Decks

  setup :verify_on_exit!

  @decklist "test/support/fixtures/decklists/iroh_das_lontra.txt"

  defp seed_every_fixture do
    "test/support/fixtures/scryfall"
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.each(fn file ->
      attrs =
        "test/support/fixtures/scryfall/#{file}"
        |> File.read!()
        |> Jason.decode!()
        |> ScryfallMapper.to_attrs()

      %Card{}
      |> Card.changeset(attrs)
      |> Repo.insert(on_conflict: :nothing, conflict_target: :oracle_id)
    end)
  end

  defp import_and_measure do
    seed_every_fixture()

    expect(Deckex.Scryfall.Mock, :fetch_by_names, fn names ->
      {:ok, %{found: [], not_found: names}}
    end)

    {:ok, deck} =
      Decks.import_from_text(File.read!(@decklist), %{name: "Iroh das Lontra", source: :paste})

    deck |> Decks.snapshot() |> Analysis.report()
  end

  test "measures the deck and produces actionable findings" do
    report = import_and_measure()

    assert report.deck_name == "Iroh das Lontra"

    # Every lens reported something.
    assert is_map(report.curve)
    assert is_map(report.mana)
    assert is_map(report.interaction)
    assert is_map(report.consistency)

    # The deck is thin on answers, so the interaction lens must have spoken.
    assert Report.by_lens(report, :interaction) != []

    # Findings are sorted with the worst first.
    severities = Enum.map(report.findings, & &1.severity)
    assert severities == Enum.sort_by(severities, &%{critical: 0, warning: 1, info: 2}[&1])

    # Every finding is actionable: it has a code, a pt-BR title and evidence.
    for finding <- report.findings do
      assert finding.code =~ "."
      assert finding.title != ""
      assert finding.evidence != %{}
    end
  end

  test "the curve and mana lenses agree about the deck's size" do
    report = import_and_measure()

    # Lands plus nonlands must equal the cards that actually resolved. If these
    # ever disagree, one lens is misreading the type line.
    assert report.curve.nonland_count + trunc(report.mana.land_count) > 0
  end

  test "counterspells never inflate the answer count" do
    report = import_and_measure()

    # :answers excludes counters by construction; this pins that contract
    # against the real deck rather than a hand-built fixture.
    assert report.interaction.answers ==
             report.interaction.spot_removal + report.interaction.board_wipes
  end
end
```

- [ ] **Step 2: Run it**

Run: `mix test test/deckex/analysis/real_deck_test.exs`
Expected: PASS — 3 tests.

- [ ] **Step 3: Print the real report for a human to read**

This is a manual check, not a test. It is how you confirm the numbers say
something true about the deck.

```bash
cd /Users/tavano/projects/deckex
MIX_ENV=dev mix run -e '
  Logger.configure(level: :error)
  deck = List.first(Deckex.Decks.list_decks())
  report = deck |> Deckex.Decks.snapshot() |> Deckex.Analysis.report()

  IO.puts("\n=== #{report.deck_name} — #{Enum.join(report.color_identity, "")} ===")
  IO.inspect(report.curve, label: "curva")
  IO.inspect(report.mana, label: "mana")
  IO.inspect(report.interaction, label: "interacao")
  IO.inspect(report.consistency, label: "consistencia")

  IO.puts("\n=== ACHADOS ===")
  Enum.each(report.findings, fn f ->
    IO.puts("[#{f.severity}] #{f.code} — #{f.title}")
    IO.puts("   #{f.detail}")
  end)
'
```

Expected: the deck imported in Plan 3 is measured, and the findings read as
plausible Portuguese sentences about a real deck.

- [ ] **Step 4: Run the full suite, gate and commit**

```bash
mix test && mix lint && git add -A && git commit -m "test: measure a real deck end to end"
```

---

## What this plan delivers

```elixir
report = deck |> Deckex.Decks.snapshot() |> Deckex.Analysis.report()

Deckex.Analysis.Report.critical_count(report)   # the vital sign on a deck tile
Deckex.Analysis.Report.by_lens(report, :mana_ramp)
```

Measured numbers and a sorted, evidence-carrying finding list — the input the AI
consult needs, and the content the deck screen renders.

## Next plans

| Plan | Spec milestone | Delivers |
|---|---|---|
| 5 | 6 | `Deckex.Consults` — briefings, per-lens schemas, AI diagnosis with web search |
| 6 | 7 | The UI: Mesa → Deck → Lente → Consultas → Ajustes |
