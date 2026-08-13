# Plano 2 — Classificação de Papéis de Carta

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Classify every card in the catalogue by the role it plays — ramp,
ritual, cost reduction, fixing, counter, spot removal, board wipe, protection,
draw, tutor, recursion, graveyard hate, stax — using deterministic rules for the
obvious majority and the Claude CLI only for the residue, caching every verdict
on the card forever.

**Architecture:** A pure rule engine (`Deckex.Cards.Roles`, split into three
focused submodules) returns `%RoleMatch{}` structs with a confidence and the
evidence that produced them. Cards no rule can confidently place are batched to
an AI port. Results persist to `card_roles` with `source` (`:rule` / `:ai` /
`:manual`); a `:manual` verdict is never overwritten.

**Tech Stack:** Elixir 1.19.5 / OTP 27, Ecto 3.13, Oban, Mox, and the `claude`
CLI in headless JSON-schema mode.

**Spec:** `docs/superpowers/specs/2026-08-13-deckex-design.md` §7.1 — this plan
implements milestone 3 of §13.

## Global Constraints

- **Code is English; user-facing strings are pt-BR; card names are never
  translated.**
- **Every aggregate is a triad.** Reads live in `*Query` modules; edges never
  build Ecto queries.
- **Errors are data:** `{:ok, _}` / `{:error, %Deckex.Error{}}`.
- **Every external service is a port:** behaviour + facade + adapter +
  `Application.compile_env` selector + Mox mock. **No test performs network or
  subprocess I/O.**
- **UUID v7 primary keys** via `use Deckex.Schema`; `:utc_datetime` timestamps.
- **The rule engine is pure.** No Repo, no HTTP, no process state — it takes a
  `%Card{}` and returns a list of structs.
- **A `:manual` role is never overwritten** by a later rule or AI pass.
- **`mix lint` must be green BEFORE every commit** — chain it with `&&`, never
  as a separate line.
- **PostgreSQL is on host port 5435.** After editing an applied migration, the
  test database keeps the old schema: `MIX_ENV=test mix ecto.drop`.

## File structure

| File | Responsibility |
|---|---|
| `lib/deckex/cards/role_match.ex` | The struct rules produce. Pure, no DB. |
| `lib/deckex/cards/roles/mana.ex` | ramp · ritual · cost_reduction · fixing |
| `lib/deckex/cards/roles/interaction.ex` | counter · spot_removal · board_wipe · protection |
| `lib/deckex/cards/roles/value.ex` | draw · tutor · recursion · graveyard_hate · stax |
| `lib/deckex/cards/roles.ex` | Composition: `classify/1`, `residue?/1` |
| `lib/deckex/cards/card_role.ex` | Ecto schema for a persisted role |
| `lib/deckex/cards/role_ai.ex` | Residue classification through the AI port |
| `lib/deckex/cli.ex` | Bounded `System.cmd` runner |
| `lib/deckex/ai.ex` · `lib/deckex/ai/client.ex` · `lib/deckex/ai/claude_cli.ex` | The AI port |
| `lib/deckex/workers/classify_cards_worker.ex` | Async residue pass |

The rule engine is split three ways rather than living in one module because
each group keys off different card properties and will keep growing; a single
`roles.ex` would become the junk drawer the playbook warns about.

---

### Task 1: `RoleMatch`, the role vocabulary, and the mana rules

**Files:**
- Create: `lib/deckex/cards/role_match.ex`
- Create: `lib/deckex/cards/roles/mana.ex`
- Test: `test/deckex/cards/roles/mana_test.exs`
- Create: 9 fixtures under `test/support/fixtures/scryfall/`

**Interfaces:**
- Consumes: `%Deckex.Cards.Card{}` (Plan 1), `Deckex.ScryfallFixture.load!/1`,
  `Deckex.Cards.ScryfallMapper.to_attrs/1`.
- Produces:
  - `%Deckex.Cards.RoleMatch{kind: atom(), confidence: :high | :medium | :low, evidence: String.t()}`
  - `Deckex.Cards.RoleMatch.kinds() :: [atom()]` — the 14 role kinds
  - `Deckex.Cards.RoleMatch.new(kind, confidence, evidence) :: t()`
  - `Deckex.Cards.Roles.Mana.classify(%Card{}) :: [%RoleMatch{}]`

- [ ] **Step 1: Download the fixtures**

Real responses, committed so tests never touch the network.

```bash
cd /Users/tavano/projects/deckex
UA='deckex/0.1 (personal deck analysis tool)'
fetch() {
  curl -sS -H "User-Agent: $UA" -H 'Accept: application/json' \
    --get --data-urlencode "exact=$1" \
    'https://api.scryfall.com/cards/named' -o "test/support/fixtures/scryfall/$2.json"
  sleep 0.5
}
fetch 'Desperate Ritual' desperate_ritual
fetch 'Goblin Electromancer' goblin_electromancer
fetch 'Arid Mesa' arid_mesa
fetch "Nature's Lore" natures_lore
fetch 'Storm-Kiln Artist' storm_kiln_artist
fetch 'Steam Vents' steam_vents
fetch 'Llanowar Elves' llanowar_elves
fetch 'Smothering Tithe' smothering_tithe
fetch 'Young Pyromancer' young_pyromancer
ls test/support/fixtures/scryfall/ | wc -l
```

Expected: 14 files (the 5 from Plan 1 plus these 9).

- [ ] **Step 2: Write the failing test**

Create `test/deckex/cards/roles/mana_test.exs`:

```elixir
defmodule Deckex.Cards.Roles.ManaTest do
  use ExUnit.Case, async: true

  alias Deckex.Cards.Card
  alias Deckex.Cards.Roles.Mana
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.ScryfallFixture

  defp card(fixture) do
    struct!(Card, fixture |> ScryfallFixture.load!() |> ScryfallMapper.to_attrs())
  end

  defp kinds(fixture), do: fixture |> card() |> Mana.classify() |> Enum.map(& &1.kind)

  describe "ramp" do
    test "a mana rock is ramp" do
      assert :ramp in kinds("sol_ring")
    end

    test "a mana dork is ramp" do
      assert :ramp in kinds("llanowar_elves")
    end

    test "a land-fetching sorcery is ramp and fixing" do
      roles = kinds("natures_lore")

      assert :ramp in roles
      assert :fixing in roles
    end

    test "a land-fetching sorcery is ramp even though produced_mana is empty" do
      # Cultivate is the reason oracle text must be read: produced_mana is [],
      # so a rule that only inspects that field misses one of the most-played
      # ramp spells in the format.
      assert card("cultivate").produced_mana == []
      assert :ramp in kinds("cultivate")
    end

    test "a treasure-maker is ramp, but only at medium confidence" do
      match = "storm_kiln_artist" |> card() |> Mana.classify() |> Enum.find(&(&1.kind == :ramp))

      assert match.confidence == :medium
    end

    test "a fetchland is NOT ramp — it sacrifices itself, it does not accelerate" do
      refute :ramp in kinds("arid_mesa")
    end

    test "a land is never ramp" do
      refute :ramp in kinds("command_tower")
      refute :ramp in kinds("steam_vents")
    end
  end

  describe "ritual" do
    test "an instant that adds mana is a ritual, not ramp" do
      roles = kinds("desperate_ritual")

      assert :ritual in roles
      refute :ramp in roles
    end

    test "a permanent that adds mana is ramp, not a ritual" do
      roles = kinds("sol_ring")

      assert :ramp in roles
      refute :ritual in roles
    end
  end

  describe "cost_reduction" do
    test "a creature that discounts your spells is cost reduction" do
      assert :cost_reduction in kinds("goblin_electromancer")
    end

    test "a spell that discounts ITSELF is not cost reduction" do
      # Blasphemous Act says "This spell costs {1} less to cast for each
      # creature on the battlefield" — that discounts nothing but itself.
      refute :cost_reduction in kinds("blasphemous_act")
    end
  end

  describe "fixing" do
    test "a land producing more than one colour is fixing" do
      assert :fixing in kinds("command_tower")
      assert :fixing in kinds("steam_vents")
    end

    test "a fetchland is fixing" do
      assert :fixing in kinds("arid_mesa")
    end

    test "a mono-coloured mana rock is not fixing" do
      refute :fixing in kinds("sol_ring")
    end
  end

  describe "no match" do
    test "a card with no mana role returns no matches" do
      assert Mana.classify(card("counterspell")) == []
      assert Mana.classify(card("young_pyromancer")) == []
    end
  end

  describe "evidence" do
    test "every match names the signal that produced it" do
      for match <- Mana.classify(card("cultivate")) do
        assert is_binary(match.evidence)
        assert match.evidence != ""
      end
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `mix test test/deckex/cards/roles/mana_test.exs`
Expected: FAIL — `module Deckex.Cards.RoleMatch is not available`.

- [ ] **Step 4: Write the `RoleMatch` struct**

Create `lib/deckex/cards/role_match.ex`:

```elixir
defmodule Deckex.Cards.RoleMatch do
  @moduledoc """
  One role a rule (or the AI) assigned to a card, with the confidence behind it
  and the evidence that produced it.

  Evidence is not decoration. Every number the app shows is a count of these,
  and the user must be able to click a number and see why each card is in it —
  otherwise a wrong rule is indistinguishable from a wrong deck.
  """

  @kinds ~w(ramp ritual cost_reduction fixing counter spot_removal board_wipe
            protection draw tutor recursion wincon graveyard_hate stax)a

  @type kind :: atom()
  @type confidence :: :high | :medium | :low
  @type t :: %__MODULE__{kind: kind(), confidence: confidence(), evidence: String.t()}

  @enforce_keys [:kind, :confidence, :evidence]
  defstruct [:kind, :confidence, :evidence]

  @doc "Every role a card can hold."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "Builds a match, rejecting a kind outside the vocabulary."
  @spec new(kind(), confidence(), String.t()) :: t()
  def new(kind, confidence, evidence)
      when kind in @kinds and confidence in [:high, :medium, :low] and is_binary(evidence) do
    %__MODULE__{kind: kind, confidence: confidence, evidence: evidence}
  end
end
```

- [ ] **Step 5: Write the mana rules**

Create `lib/deckex/cards/roles/mana.ex`:

```elixir
defmodule Deckex.Cards.Roles.Mana do
  @moduledoc """
  Rules for the roles that touch mana: `:ramp`, `:ritual`, `:cost_reduction` and
  `:fixing`.

  Four distinctions here were learned from real decklists and are easy to get
  wrong:

  1. **A fetchland is not ramp.** Its text matches "search your library for a
     ... land ... onto the battlefield", exactly like Cultivate, but it
     sacrifices itself — net zero mana. Lands are excluded from `:ramp` and
     land-fetching lands are `:fixing`.
  2. **A ritual is not ramp.** `Desperate Ritual` adds three mana once. It does
     not let you cast a six-drop a turn earlier from an empty board, and
     counting it as ramp overstates a deck's acceleration.
  3. **Self-discount is not cost reduction.** `Blasphemous Act` says "This spell
     costs {1} less"; that helps no other card. The rule matches discounts on
     *your spells*, not on the card itself.
  4. **`produced_mana` alone is insufficient.** `Cultivate` produces no mana by
     that field and is still one of the format's most-played ramp spells; only
     the oracle text reveals it.
  """

  alias Deckex.Cards.RoleMatch

  # "Search your library for ... land ... onto the battlefield" — the Cultivate
  # shape. `[^.]*` keeps the match inside one sentence so an unrelated later
  # clause cannot satisfy it.
  @fetches_land ~r/search your library for[^.]*\bland\b[^.]*onto the battlefield/i

  # A land type named directly, as fetchlands and Nature's Lore do.
  @fetches_land_type ~r/search your library for[^.]*\b(plains|island|swamp|mountain|forest)\b/i

  # "... spells you cast cost {1} less" — a discount on OTHER cards. Deliberately
  # does not match "This spell costs {1} less".
  @discounts_your_spells ~r/spells?\s+you\s+cast\s+cost\s+\{[^}]+\}\s+less/i

  @treasure ~r/create[sd]?\s+.*\btreasure\b/i

  @spec classify(Deckex.Cards.Card.t()) :: [RoleMatch.t()]
  def classify(card) do
    [&ramp/1, &ritual/1, &cost_reduction/1, &fixing/1]
    |> Enum.flat_map(& &1.(card))
  end

  # --- ramp -----------------------------------------------------------------

  # Order matters. The treasure check comes BEFORE `produces_mana?` because
  # Scryfall populates `produced_mana` for treasure makers (Storm-Kiln Artist
  # lists all five colours), and a creature that makes a token that taps for
  # mana is a weaker signal than one that taps for mana itself.
  defp ramp(card) do
    cond do
      land?(card) -> []
      instant_or_sorcery?(card) and produces_mana?(card) -> []
      treasure_maker?(card) -> [RoleMatch.new(:ramp, :medium, "cria Treasure")]
      produces_mana?(card) -> [tap_for_mana(card)]
      fetches_land?(card) -> [RoleMatch.new(:ramp, :high, "busca terreno para o campo")]
      true -> []
    end
  end

  defp tap_for_mana(card) do
    RoleMatch.new(:ramp, :high, "permanente que produz #{Enum.join(card.produced_mana, "")}")
  end

  # --- ritual ---------------------------------------------------------------

  defp ritual(card) do
    if instant_or_sorcery?(card) and produces_mana?(card) do
      [RoleMatch.new(:ritual, :high, "mágica que adiciona mana de uma vez")]
    else
      []
    end
  end

  # --- cost reduction -------------------------------------------------------

  defp cost_reduction(card) do
    if text(card) =~ @discounts_your_spells do
      [RoleMatch.new(:cost_reduction, :high, "reduz o custo das suas mágicas")]
    else
      []
    end
  end

  # --- fixing ---------------------------------------------------------------

  defp fixing(card) do
    cond do
      length(card.produced_mana) >= 2 ->
        [RoleMatch.new(:fixing, :high, "produz #{length(card.produced_mana)} cores")]

      land?(card) and fetches_land?(card) ->
        [RoleMatch.new(:fixing, :high, "terreno que busca terreno")]

      fetches_land?(card) ->
        [RoleMatch.new(:fixing, :medium, "busca terreno específico")]

      true ->
        []
    end
  end

  # --- predicates -----------------------------------------------------------

  defp text(card), do: card.oracle_text || ""

  defp front_type(card), do: card.type_line |> String.split("//") |> hd()

  defp land?(card), do: String.contains?(front_type(card), "Land")

  defp instant_or_sorcery?(card) do
    type = front_type(card)
    String.contains?(type, "Instant") or String.contains?(type, "Sorcery")
  end

  defp produces_mana?(card), do: card.produced_mana != []

  defp treasure_maker?(card), do: text(card) =~ @treasure

  defp fetches_land?(card) do
    body = text(card)
    body =~ @fetches_land or body =~ @fetches_land_type
  end
end
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `mix test test/deckex/cards/roles/mana_test.exs`
Expected: PASS — 15 tests.

- [ ] **Step 7: Run the gate and commit**

```bash
mix lint && git add -A && git commit -m "feat: classify mana roles from card rules

Separates ramp from rituals and cost reduction, and keeps fetchlands out of
ramp — all three distinctions came from a real decklist."
```

---

### Task 2: Interaction rules

**Files:**
- Create: `lib/deckex/cards/roles/interaction.ex`
- Test: `test/deckex/cards/roles/interaction_test.exs`
- Create: 3 fixtures

**Interfaces:**
- Consumes: `Deckex.Cards.RoleMatch.new/3` (Task 1).
- Produces: `Deckex.Cards.Roles.Interaction.classify(%Card{}) :: [%RoleMatch{}]`

- [ ] **Step 1: Download the fixtures**

```bash
cd /Users/tavano/projects/deckex
UA='deckex/0.1 (personal deck analysis tool)'
fetch() {
  curl -sS -H "User-Agent: $UA" -H 'Accept: application/json' \
    --get --data-urlencode "exact=$1" \
    'https://api.scryfall.com/cards/named' -o "test/support/fixtures/scryfall/$2.json"
  sleep 0.5
}
fetch 'Resculpt' resculpt
fetch 'Overwhelming Victory' overwhelming_victory
fetch 'Swiftfoot Boots' swiftfoot_boots
```

- [ ] **Step 2: Write the failing test**

Create `test/deckex/cards/roles/interaction_test.exs`:

```elixir
defmodule Deckex.Cards.Roles.InteractionTest do
  use ExUnit.Case, async: true

  alias Deckex.Cards.Card
  alias Deckex.Cards.Roles.Interaction
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.ScryfallFixture

  defp card(fixture) do
    struct!(Card, fixture |> ScryfallFixture.load!() |> ScryfallMapper.to_attrs())
  end

  defp kinds(fixture), do: fixture |> card() |> Interaction.classify() |> Enum.map(& &1.kind)

  describe "counter" do
    test "a counterspell is a counter" do
      assert :counter in kinds("counterspell")
    end

    test "a counterspell is not spot removal — it cannot answer a resolved threat" do
      refute :spot_removal in kinds("counterspell")
    end
  end

  describe "spot_removal" do
    test "exiling a single permanent is spot removal" do
      assert :spot_removal in kinds("resculpt")
    end

    test "damage aimed at one creature is spot removal, not a wipe" do
      # Overwhelming Victory reads "deals 5 damage to target creature. Each
      # creature you control gains trample..." — a naive "each creature" match
      # calls this a board wipe. It is not.
      roles = kinds("overwhelming_victory")

      assert :spot_removal in roles
      refute :board_wipe in roles
    end
  end

  describe "board_wipe" do
    test "damage to every creature is a board wipe" do
      assert :board_wipe in kinds("blasphemous_act")
    end

    test "a board wipe is not also counted as spot removal" do
      refute :spot_removal in kinds("blasphemous_act")
    end
  end

  describe "protection" do
    test "granting hexproof is protection" do
      assert :protection in kinds("swiftfoot_boots")
    end
  end

  describe "no match" do
    test "a ramp spell has no interaction role" do
      assert Interaction.classify(card("cultivate")) == []
      assert Interaction.classify(card("sol_ring")) == []
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `mix test test/deckex/cards/roles/interaction_test.exs`
Expected: FAIL — `module Deckex.Cards.Roles.Interaction is not available`.

- [ ] **Step 4: Write the interaction rules**

Create `lib/deckex/cards/roles/interaction.ex`:

```elixir
defmodule Deckex.Cards.Roles.Interaction do
  @moduledoc """
  Rules for the roles that answer an opponent: `:counter`, `:spot_removal`,
  `:board_wipe` and `:protection`.

  `:counter` and `:spot_removal` are deliberately separate and must never be
  summed into one "interaction" number. A counterspell is a dead card once the
  threat has resolved; against an aggressive deck only the answers that address
  a permanent already on the battlefield count.

  The wipe rules exclude "each creature **you control**" — a pump clause on a
  removal spell (`Overwhelming Victory`) otherwise reads as a board wipe.
  """

  alias Deckex.Cards.RoleMatch

  @counter ~r/counter target/i

  @destroys_all ~r/(destroy|exile) all\b/i

  # Mass damage, but not the "each creature you control" pump clause.
  @damages_all ~r/damage to each creature(?! you control)/i

  @sacrifice_all ~r/each (player|opponent) sacrifices/i

  @spot ~r/(destroy|exile) target|damage to target (creature|permanent|planeswalker)|damage to any target/i

  @protection ~r/\b(hexproof|indestructible|shroud|protection from|ward)\b/i

  @spec classify(Deckex.Cards.Card.t()) :: [RoleMatch.t()]
  def classify(card) do
    body = text(card)

    counter(body) ++ mass_or_spot(body) ++ protection(body)
  end

  defp counter(body) do
    if body =~ @counter,
      do: [RoleMatch.new(:counter, :high, "contra-magia (\"counter target\")")],
      else: []
  end

  # A card is a wipe or spot removal, never both: the wipe clause on a sweeper
  # ("destroy all creatures") would otherwise also trip the spot pattern via a
  # secondary mode.
  defp mass_or_spot(body) do
    cond do
      wipe?(body) -> [RoleMatch.new(:board_wipe, :high, "atinge todas as criaturas")]
      body =~ @spot -> [RoleMatch.new(:spot_removal, :high, "remove um alvo único")]
      true -> []
    end
  end

  defp wipe?(body) do
    body =~ @destroys_all or body =~ @damages_all or body =~ @sacrifice_all
  end

  defp protection(body) do
    if body =~ @protection,
      do: [RoleMatch.new(:protection, :medium, "concede proteção (hexproof/indestructible/ward)")],
      else: []
  end

  defp text(card), do: card.oracle_text || ""
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/deckex/cards/roles/interaction_test.exs`
Expected: PASS — 8 tests.

- [ ] **Step 6: Run the gate and commit**

```bash
mix lint && git add -A && git commit -m "feat: classify interaction roles from card rules

Counters and spot removal stay separate — a counterspell cannot answer a
resolved threat, and summing them hides that."
```

---

### Task 3: Value rules

**Files:**
- Create: `lib/deckex/cards/roles/value.ex`
- Test: `test/deckex/cards/roles/value_test.exs`
- Create: 2 fixtures

**Interfaces:**
- Consumes: `Deckex.Cards.RoleMatch.new/3` (Task 1).
- Produces: `Deckex.Cards.Roles.Value.classify(%Card{}) :: [%RoleMatch{}]`

- [ ] **Step 1: Download the fixtures**

```bash
cd /Users/tavano/projects/deckex
UA='deckex/0.1 (personal deck analysis tool)'
fetch() {
  curl -sS -H "User-Agent: $UA" -H 'Accept: application/json' \
    --get --data-urlencode "exact=$1" \
    'https://api.scryfall.com/cards/named' -o "test/support/fixtures/scryfall/$2.json"
  sleep 0.5
}
fetch 'Rhystic Study' rhystic_study
fetch 'Mystical Tutor' mystical_tutor
```

- [ ] **Step 2: Write the failing test**

Create `test/deckex/cards/roles/value_test.exs`:

```elixir
defmodule Deckex.Cards.Roles.ValueTest do
  use ExUnit.Case, async: true

  alias Deckex.Cards.Card
  alias Deckex.Cards.Roles.Value
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.ScryfallFixture

  defp card(fixture) do
    struct!(Card, fixture |> ScryfallFixture.load!() |> ScryfallMapper.to_attrs())
  end

  defp kinds(fixture), do: fixture |> card() |> Value.classify() |> Enum.map(& &1.kind)

  describe "draw" do
    test "drawing cards is draw" do
      assert :draw in kinds("rhystic_study")
    end

    test "a looting effect is draw" do
      assert :draw in kinds("faithless_looting")
    end
  end

  describe "tutor" do
    test "searching for a non-land card is a tutor" do
      assert :tutor in kinds("mystical_tutor")
    end

    test "searching for a LAND is ramp, not a tutor" do
      # Cultivate and the fetchlands search the library too. They are handled by
      # the mana rules; counting them as tutors would inflate a deck's apparent
      # consistency.
      refute :tutor in kinds("cultivate")
      refute :tutor in kinds("arid_mesa")
      refute :tutor in kinds("natures_lore")
    end
  end

  describe "stax" do
    test "taxing an opponent's spells is stax" do
      assert :stax in kinds("rhystic_study")
    end
  end

  describe "no match" do
    test "a vanilla mana rock has no value role" do
      assert Value.classify(card("sol_ring")) == []
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `mix test test/deckex/cards/roles/value_test.exs`
Expected: FAIL — `module Deckex.Cards.Roles.Value is not available`.

- [ ] **Step 4: Write the value rules**

Create `lib/deckex/cards/roles/value.ex`:

```elixir
defmodule Deckex.Cards.Roles.Value do
  @moduledoc """
  Rules for the roles that generate advantage rather than answer a threat:
  `:draw`, `:tutor`, `:recursion`, `:graveyard_hate` and `:stax`.

  The tutor rule excludes library searches that name a land — those are ramp or
  fixing and belong to `Deckex.Cards.Roles.Mana`. Counting Cultivate and eight
  fetchlands as tutors would make almost any deck look far more consistent than
  it is.
  """

  alias Deckex.Cards.RoleMatch

  # "you draw" / "you may draw" / an imperative "Draw two cards". Deliberately
  # NOT a bare "draws a card": Smothering Tithe reads "Whenever an opponent
  # draws a card", which gives you a Treasure, not a card.
  @draw ~r/(?:you may draw|you draw|^draw)\s+(?:a|\w+)\s+cards?/im

  @search ~r/search your library for([^.]*)/i
  @land_search ~r/\b(land|plains|island|swamp|mountain|forest)\b/i

  @recursion ~r/return .* from your graveyard|\bflashback\b|cast .* from your graveyard/i

  @graveyard_hate ~r/exile .*(target player's|each opponent's|all) graveyard|exile .* from a graveyard/i

  @stax ~r/unless that player pays|unless its controller pays|can't (be cast|attack|untap)|costs? \{[^}]+\} more/i

  @spec classify(Deckex.Cards.Card.t()) :: [RoleMatch.t()]
  def classify(card) do
    body = text(card)

    draw(body) ++ tutor(body) ++ recursion(body) ++ graveyard_hate(body) ++ stax(body)
  end

  defp draw(body) do
    if body =~ @draw, do: [RoleMatch.new(:draw, :high, "compra carta")], else: []
  end

  # A search only counts as a tutor when what it looks for is not a land.
  defp tutor(body) do
    case Regex.run(@search, body, capture: :all_but_first) do
      [target] ->
        if target =~ @land_search,
          do: [],
          else: [RoleMatch.new(:tutor, :high, "busca carta na biblioteca")]

      _no_search ->
        []
    end
  end

  defp recursion(body) do
    if body =~ @recursion,
      do: [RoleMatch.new(:recursion, :medium, "reusa carta do cemitério")],
      else: []
  end

  defp graveyard_hate(body) do
    if body =~ @graveyard_hate,
      do: [RoleMatch.new(:graveyard_hate, :high, "exila cemitério")],
      else: []
  end

  defp stax(body) do
    if body =~ @stax, do: [RoleMatch.new(:stax, :medium, "taxa ou restringe o oponente")], else: []
  end

  defp text(card), do: card.oracle_text || ""
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/deckex/cards/roles/value_test.exs`
Expected: PASS — 6 tests.

- [ ] **Step 6: Run the gate and commit**

```bash
mix lint && git add -A && git commit -m "feat: classify value roles from card rules

Library searches that name a land are ramp, not tutors."
```

---

### Task 4: Compose the rule engine

**Files:**
- Create: `lib/deckex/cards/roles.ex`
- Test: `test/deckex/cards/roles_test.exs`

**Interfaces:**
- Consumes: `Roles.Mana.classify/1`, `Roles.Interaction.classify/1`,
  `Roles.Value.classify/1` (Tasks 1–3).
- Produces:
  - `Deckex.Cards.Roles.classify(%Card{}) :: [%RoleMatch{}]` — deduplicated,
    highest confidence per kind wins
  - `Deckex.Cards.Roles.residue?(%Card{}) :: boolean()` — true when no rule
    placed the card confidently, meaning it must go to the AI

- [ ] **Step 1: Write the failing test**

Create `test/deckex/cards/roles_test.exs`:

```elixir
defmodule Deckex.Cards.RolesTest do
  use ExUnit.Case, async: true

  alias Deckex.Cards.Card
  alias Deckex.Cards.Roles
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.ScryfallFixture

  defp card(fixture) do
    struct!(Card, fixture |> ScryfallFixture.load!() |> ScryfallMapper.to_attrs())
  end

  defp kinds(fixture), do: fixture |> card() |> Roles.classify() |> Enum.map(& &1.kind)

  describe "classify/1" do
    test "combines roles from every rule group" do
      roles = kinds("cultivate")

      assert :ramp in roles
      assert :fixing in roles
    end

    test "returns at most one match per kind" do
      matches = Roles.classify(card("cultivate"))
      kinds = Enum.map(matches, & &1.kind)

      assert kinds == Enum.uniq(kinds)
    end

    test "keeps the highest confidence when a kind matches twice" do
      # Command Tower is fixing by producing five colours (high). Whatever else
      # fires, the surviving match must not be downgraded.
      match = "command_tower" |> card() |> Roles.classify() |> Enum.find(&(&1.kind == :fixing))

      assert match.confidence == :high
    end

    test "a card the rules cannot place returns no matches" do
      assert Roles.classify(card("young_pyromancer")) == []
    end
  end

  describe "residue?/1" do
    test "a confidently classified card is not residue" do
      refute Roles.residue?(card("sol_ring"))
      refute Roles.residue?(card("counterspell"))
    end

    test "an unmatched card is residue and goes to the AI" do
      # Young Pyromancer makes creature tokens off spells. No rule touches it:
      # it produces no mana, answers nothing, and draws nothing. This is exactly
      # the shape the AI pass exists for.
      assert Roles.residue?(card("young_pyromancer"))
    end

    test "Smothering Tithe is caught by the treasure rule, not sent to the AI" do
      # It is one of the format's most-played ramp cards, and a conditional tax
      # engine no removal or draw regex would find — but "create a Treasure
      # token" is a real signal, so the rules get it for free at medium
      # confidence. Every card the rules catch is a card never paid for.
      refute Roles.residue?(card("smothering_tithe"))

      match =
        "smothering_tithe" |> card() |> Roles.classify() |> Enum.find(&(&1.kind == :ramp))

      assert match.confidence == :medium
    end

    test "an opponent drawing a card is not you drawing a card" do
      # Smothering Tithe reads "Whenever an opponent draws a card" — that gives
      # you a Treasure, not a card, and must not count towards card advantage.
      refute :draw in (card("smothering_tithe") |> Roles.classify() |> Enum.map(& &1.kind))
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/deckex/cards/roles_test.exs`
Expected: FAIL — `module Deckex.Cards.Roles is not available`.

- [ ] **Step 3: Write the composition module**

Create `lib/deckex/cards/roles.ex`:

```elixir
defmodule Deckex.Cards.Roles do
  @moduledoc """
  The rule engine: a pure function from a card to the roles it plays.

  Rules resolve the obvious majority for free and instantly. What they cannot
  place is *residue*, handed to the AI by `Deckex.Cards.RoleAI` and cached on
  the card forever — so the same card is never paid for twice, across any deck.

  `Smothering Tithe` is the canonical residue: one of the format's most-played
  ramp cards, and no reasonable regex finds it. `Sol Ring` is the canonical
  rule hit: one field, zero cost. The split between them is the whole design.
  """

  alias Deckex.Cards.Card
  alias Deckex.Cards.RoleMatch
  alias Deckex.Cards.Roles.Interaction
  alias Deckex.Cards.Roles.Mana
  alias Deckex.Cards.Roles.Value

  @confidence_rank %{high: 3, medium: 2, low: 1}

  @doc """
  Every role the rules can assign to `card`, at most one match per kind.
  """
  @spec classify(Card.t()) :: [RoleMatch.t()]
  def classify(%Card{} = card) do
    [Mana, Interaction, Value]
    |> Enum.flat_map(& &1.classify(card))
    |> best_per_kind()
  end

  @doc """
  Whether the rules failed to place this card, meaning it must go to the AI.

  A card with only low-confidence matches counts as residue: a guess is not an
  answer, and the AI pass is cheap because the result is cached globally.
  """
  @spec residue?(Card.t()) :: boolean()
  def residue?(%Card{} = card) do
    case classify(card) do
      [] -> true
      matches -> Enum.all?(matches, &(&1.confidence == :low))
    end
  end

  defp best_per_kind(matches) do
    matches
    |> Enum.group_by(& &1.kind)
    |> Enum.map(fn {_kind, group} -> Enum.max_by(group, &@confidence_rank[&1.confidence]) end)
    |> Enum.sort_by(& &1.kind)
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/deckex/cards/roles_test.exs`
Expected: PASS — 9 tests.

- [ ] **Step 5: Run the gate and commit**

```bash
mix lint && git add -A && git commit -m "feat: compose the card role rule engine"
```

---

### Task 5: Persist roles

**Files:**
- Create: `priv/repo/migrations/<timestamp>_create_card_roles.exs`
- Create: `lib/deckex/cards/card_role.ex`
- Modify: `lib/deckex/cards/card_query.ex` (add `list_with_roles/1`)
- Modify: `lib/deckex/cards.ex` (add `classify_card/1`, `roles_for/1`, `set_role_manually/3`)
- Modify: `test/support/factory.ex` (add `card_role_factory/0`)
- Test: `test/deckex/cards/roles_persistence_test.exs`

**Interfaces:**
- Consumes: `Roles.classify/1` (Task 4), `Deckex.Cards.Card` (Plan 1).
- Produces:
  - `%Deckex.Cards.CardRole{card_id, kind, confidence, source, evidence}`
  - `Deckex.Cards.classify_card(%Card{}) :: {:ok, [%CardRole{}]}`
  - `Deckex.Cards.roles_for(%Card{}) :: [%CardRole{}]`
  - `Deckex.Cards.set_role_manually(%Card{}, kind :: atom(), evidence :: String.t()) :: {:ok, %CardRole{}}`

- [ ] **Step 1: Generate and write the migration**

```bash
mix ecto.gen.migration create_card_roles
```

Write its contents (use the generated timestamp in the filename):

```elixir
defmodule Deckex.Repo.Migrations.CreateCardRoles do
  use Ecto.Migration

  def change do
    create table(:card_roles, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :card_id, references(:cards, type: :uuid, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :confidence, :string, null: false
      add :source, :string, null: false
      add :evidence, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:card_roles, [:card_id, :kind])
    create index(:card_roles, [:kind])
  end
end
```

- [ ] **Step 2: Write the failing test**

Create `test/deckex/cards/roles_persistence_test.exs`:

```elixir
defmodule Deckex.Cards.RolesPersistenceTest do
  use Deckex.DataCase, async: true

  alias Deckex.Cards
  alias Deckex.Cards.Card
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.ScryfallFixture

  defp insert_fixture(name) do
    attrs = name |> ScryfallFixture.load!() |> ScryfallMapper.to_attrs()

    %Card{} |> Card.changeset(attrs) |> Repo.insert!()
  end

  describe "classify_card/1" do
    test "persists the roles the rules found, stamped as :rule" do
      card = insert_fixture("sol_ring")

      assert {:ok, roles} = Cards.classify_card(card)
      assert [%{kind: :ramp, source: :rule, confidence: :high}] = roles
      assert hd(roles).evidence =~ "produz"
    end

    test "persists several roles for one card" do
      card = insert_fixture("cultivate")

      assert {:ok, roles} = Cards.classify_card(card)
      assert Enum.sort(Enum.map(roles, & &1.kind)) == [:fixing, :ramp]
    end

    test "is idempotent — re-classifying does not duplicate rows" do
      card = insert_fixture("cultivate")

      assert {:ok, _first} = Cards.classify_card(card)
      assert {:ok, _second} = Cards.classify_card(card)

      assert length(Cards.roles_for(card)) == 2
    end

    test "stores nothing for a card the rules cannot place" do
      card = insert_fixture("young_pyromancer")

      assert {:ok, []} = Cards.classify_card(card)
      assert Cards.roles_for(card) == []
    end
  end

  describe "set_role_manually/3" do
    test "records a manual role" do
      card = insert_fixture("young_pyromancer")

      assert {:ok, role} = Cards.set_role_manually(card, :wincon, "eu decidi")
      assert %{kind: :wincon, source: :manual, confidence: :high} = role
    end

    test "a manual role is never overwritten by a later rule pass" do
      card = insert_fixture("sol_ring")

      # The rules say Sol Ring is :ramp at high confidence. A human says it is
      # also the deck's wincon, and separately overrides the ramp verdict.
      assert {:ok, _manual} = Cards.set_role_manually(card, :ramp, "não conta como ramp aqui")
      assert {:ok, _rules} = Cards.classify_card(card)

      assert [%{kind: :ramp, source: :manual, evidence: "não conta como ramp aqui"}] =
               Cards.roles_for(card)
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `mix test test/deckex/cards/roles_persistence_test.exs`
Expected: FAIL — `module Deckex.Cards.CardRole is not available`.

- [ ] **Step 4: Write the schema**

Create `lib/deckex/cards/card_role.ex`:

```elixir
defmodule Deckex.Cards.CardRole do
  @moduledoc """
  One role a card plays, with where the verdict came from.

  `source` is what makes the numbers auditable: `:rule` came from a regex,
  `:ai` from a model, `:manual` from the user. A `:manual` role is permanent —
  the user's correction outranks every later pass.
  """
  use Deckex.Schema

  import Ecto.Changeset

  alias Deckex.Cards.Card
  alias Deckex.Cards.RoleMatch

  @type t :: %__MODULE__{}

  schema "card_roles" do
    field :kind, Ecto.Enum, values: RoleMatch.kinds()
    field :confidence, Ecto.Enum, values: [:high, :medium, :low]
    field :source, Ecto.Enum, values: [:rule, :ai, :manual]
    field :evidence, :string

    belongs_to :card, Card

    timestamps()
  end

  @doc "Builds a changeset for a classified role."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(role, attrs) do
    role
    |> cast(attrs, [:card_id, :kind, :confidence, :source, :evidence])
    |> validate_required([:card_id, :kind, :confidence, :source])
    |> foreign_key_constraint(:card_id)
    |> unique_constraint([:card_id, :kind])
  end
end
```

- [ ] **Step 5: Add the query function**

In `lib/deckex/cards/card_query.ex`, add this function and the alias it needs
(`alias Deckex.Cards.CardRole`):

```elixir
  @doc "Lists the persisted roles for a card, ordered by kind."
  @spec list_roles(Card.t()) :: [CardRole.t()]
  def list_roles(%Card{id: card_id}) do
    Repo.all(from r in CardRole, where: r.card_id == ^card_id, order_by: r.kind)
  end
```

- [ ] **Step 6: Add the context functions**

In `lib/deckex/cards.ex`, add `alias Deckex.Cards.CardRole` and
`alias Deckex.Cards.Roles`, plus:

```elixir
  defdelegate roles_for(card), to: CardQuery, as: :list_roles

  @doc """
  Runs the rule engine over `card` and persists what it finds.

  Idempotent: re-running replaces a rule verdict with the fresh one. A
  `:manual` role is left untouched — the user's correction is permanent.
  """
  @spec classify_card(Card.t()) :: {:ok, [CardRole.t()]}
  def classify_card(%Card{} = card) do
    manual = card |> CardQuery.list_roles() |> Enum.filter(&(&1.source == :manual))
    protected = MapSet.new(manual, & &1.kind)

    roles =
      card
      |> Roles.classify()
      |> Enum.reject(&MapSet.member?(protected, &1.kind))
      |> Enum.map(&upsert_role!(card, &1, :rule))

    {:ok, roles}
  end

  @doc """
  Records a role chosen by the user. Manual roles are never overwritten by a
  later rule or AI pass, and they are the signal for improving the rules.
  """
  @spec set_role_manually(Card.t(), atom(), String.t()) :: {:ok, CardRole.t()}
  def set_role_manually(%Card{} = card, kind, evidence) do
    match = RoleMatch.new(kind, :high, evidence)

    {:ok, upsert_role!(card, match, :manual)}
  end

  defp upsert_role!(card, %RoleMatch{} = match, source) do
    %CardRole{}
    |> CardRole.changeset(%{
      card_id: card.id,
      kind: match.kind,
      confidence: match.confidence,
      source: source,
      evidence: match.evidence
    })
    |> Repo.insert!(
      on_conflict: {:replace, [:confidence, :source, :evidence, :updated_at]},
      conflict_target: [:card_id, :kind],
      returning: true
    )
  end
```

Also add `alias Deckex.Cards.RoleMatch`.

- [ ] **Step 7: Migrate and run the test**

```bash
mix ecto.migrate && mix test test/deckex/cards/roles_persistence_test.exs
```

Expected: PASS — 6 tests.

- [ ] **Step 8: Run the gate and commit**

```bash
mix lint && git add -A && git commit -m "feat: persist card roles with provenance

Every role records whether it came from a rule, the AI, or the user. A manual
verdict is permanent."
```

---

### Task 6: The AI port

**Files:**
- Create: `lib/deckex/cli.ex`
- Create: `lib/deckex/ai/client.ex`
- Create: `lib/deckex/ai.ex`
- Create: `lib/deckex/ai/claude_cli.ex`
- Modify: `test/support/mocks.ex`, `config/config.exs`, `config/test.exs`
- Test: `test/deckex/ai/claude_cli_test.exs`

**Interfaces:**
- Consumes: `Deckex.Error.new/3` (Plan 1).
- Produces:
  - `Deckex.Cli.run((-> {binary(), non_neg_integer()}), pos_integer()) :: {:ok, {binary(), non_neg_integer()}} | {:error, :timeout} | {:error, {:exit, term()}}`
  - `@callback complete(prompt :: String.t(), schema :: map(), opts :: keyword()) :: {:ok, map()} | {:error, Deckex.Error.t()}`
  - `Deckex.AI.complete/3` — the facade, applying the configured model
  - `Deckex.AI.ClaudeCli.parse_output(String.t()) :: {:ok, map()} | {:error, Deckex.Error.t()}`
  - `Deckex.AI.Mock` — the Mox mock

- [ ] **Step 1: Write the bounded CLI runner**

Create `lib/deckex/cli.ex`:

```elixir
defmodule Deckex.Cli do
  @moduledoc """
  Bounded execution for CLI adapters: runs the command function in a task and
  brutally kills it after `timeout_ms`, so an external binary can never hang its
  caller (an Oban queue slot, or a LiveView async). Every adapter that shells
  out wraps its `System.cmd` call in `run/2`.
  """

  @type cmd_result :: {binary(), non_neg_integer()}

  @spec run((-> cmd_result()), pos_integer()) ::
          {:ok, cmd_result()} | {:error, :timeout} | {:error, {:exit, term()}}
  def run(fun, timeout_ms) do
    task = Task.async(fun)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      {:exit, reason} -> {:error, {:exit, reason}}
      nil -> {:error, :timeout}
    end
  end
end
```

- [ ] **Step 2: Write the failing test**

Create `test/deckex/ai/claude_cli_test.exs`:

```elixir
defmodule Deckex.AI.ClaudeCliTest do
  use ExUnit.Case, async: true

  alias Deckex.AI.ClaudeCli
  alias Deckex.Error

  describe "build_args/3" do
    test "asks for JSON output constrained by the schema" do
      args = ClaudeCli.build_args("classifique", %{type: "object"}, [])

      assert "-p" in args
      assert "classifique" in args
      assert "--output-format" in args
      assert "json" in args
      assert "--json-schema" in args
    end

    test "passes the model when given" do
      args = ClaudeCli.build_args("oi", %{}, model: "sonnet")

      assert "--model" in args
      assert "sonnet" in args
    end

    test "grants no tools by default" do
      refute "--allowedTools" in ClaudeCli.build_args("oi", %{}, [])
    end

    test "grants only the tools explicitly allowed" do
      args = ClaudeCli.build_args("oi", %{}, allowed_tools: ["WebSearch"])

      assert "--allowedTools" in args
      assert "WebSearch" in args
    end
  end

  describe "parse_output/1" do
    test "returns the structured output object" do
      envelope = Jason.encode!(%{"structured_output" => %{"cards" => []}})

      assert {:ok, %{"cards" => []}} = ClaudeCli.parse_output(envelope)
    end

    test "surfaces an error envelope as a domain error" do
      envelope = Jason.encode!(%{"is_error" => true, "result" => "estourou o limite"})

      assert {:error, %Error{code: :ai_unavailable}} = ClaudeCli.parse_output(envelope)
    end

    test "surfaces a missing structured_output as a domain error" do
      envelope = Jason.encode!(%{"subtype" => "success", "result" => "texto solto"})

      assert {:error, %Error{code: :ai_unavailable}} = ClaudeCli.parse_output(envelope)
    end

    test "surfaces unparseable output as a domain error" do
      assert {:error, %Error{code: :ai_unavailable}} = ClaudeCli.parse_output("not json")
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `mix test test/deckex/ai/claude_cli_test.exs`
Expected: FAIL — `module Deckex.AI.ClaudeCli is not available`.

- [ ] **Step 4: Write the behaviour and facade**

Create `lib/deckex/ai/client.ex`:

```elixir
defmodule Deckex.AI.Client do
  @moduledoc """
  Port for an LLM that returns structured, JSON-schema-constrained output. The
  real adapter is `Deckex.AI.ClaudeCli`; tests use `Deckex.AI.Mock`.
  """

  @callback complete(prompt :: String.t(), schema :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, Deckex.Error.t()}
end
```

Create `lib/deckex/ai.ex`:

```elixir
defmodule Deckex.AI do
  @moduledoc """
  The single AI entry point. Resolves the configured adapter and applies the
  configured model so callers never name either.
  """

  @adapter Application.compile_env(:deckex, [Deckex.AI.Client, :adapter], Deckex.AI.ClaudeCli)

  @doc "Calls the AI client with the model default applied."
  @spec complete(String.t(), map(), keyword()) :: {:ok, map()} | {:error, Deckex.Error.t()}
  def complete(prompt, schema, opts \\ []) do
    @adapter.complete(prompt, schema, Keyword.put_new(opts, :model, model()))
  end

  @doc "Configured model (default \"sonnet\")."
  @spec model() :: String.t()
  def model, do: config(:model, "sonnet")

  @doc "How many cards go to the model in one classification call (default 15)."
  @spec batch_size() :: pos_integer()
  def batch_size, do: config(:batch_size, 15)

  defp config(key, default),
    do: :deckex |> Application.get_env(Deckex.AI, []) |> Keyword.get(key, default)
end
```

- [ ] **Step 5: Write the adapter**

Create `lib/deckex/ai/claude_cli.ex`:

```elixir
defmodule Deckex.AI.ClaudeCli do
  @moduledoc """
  AI adapter backed by the `claude` CLI in headless mode. Runs
  `claude -p <prompt> --output-format json --json-schema <schema>` and returns
  the `structured_output` object from the result envelope.

  Two hardening details, both learned the hard way in a sibling project, keep a
  CLI call from hanging its caller:

  - **stdin is redirected from `/dev/null`.** Spawned non-interactively from
    `phx.server` or an Oban worker, the CLI otherwise blocks forever waiting for
    piped input.
  - **The whole call is bounded by a timeout**, surfacing an error instead of an
    endless spinner.

  Headless runs get **no tools** unless the caller allows them explicitly.
  """
  @behaviour Deckex.AI.Client

  alias Deckex.Cli
  alias Deckex.Error

  @default_timeout_ms 120_000

  # No default for `opts`: a default would generate a complete/2 that the
  # behaviour does not declare, and @impl would warn about it.
  @impl Deckex.AI.Client
  def complete(prompt, schema, opts) do
    cli_args = build_args(prompt, schema, opts)

    # Run through `sh` with stdin from /dev/null. `exec "$@"` forwards argv
    # verbatim, so the prompt and schema need no shell quoting and the CLI gets
    # an immediate EOF.
    argv = ["-c", ~s|exec "$@" < /dev/null|, "sh", executable() | cli_args]

    run(fn -> System.cmd("/bin/sh", argv, stderr_to_stdout: false) end, opts)
  end

  @doc "Builds the CLI argv for a structured completion."
  @spec build_args(String.t(), map(), keyword()) :: [String.t()]
  def build_args(prompt, schema, opts) do
    ["-p", prompt, "--output-format", "json", "--json-schema", Jason.encode!(schema)] ++
      model_args(opts) ++ tool_args(opts)
  end

  @doc "Parses the `claude --output-format json` envelope."
  @spec parse_output(String.t()) :: {:ok, map()} | {:error, Error.t()}
  def parse_output(output) do
    case Jason.decode(output) do
      {:ok, %{"is_error" => true} = envelope} ->
        {:error, ai_error("A IA retornou erro.", %{result: envelope["result"]})}

      {:ok, %{"structured_output" => structured}} when is_map(structured) ->
        {:ok, structured}

      {:ok, envelope} ->
        {:error,
         ai_error("A IA respondeu sem saída estruturada.", %{
           envelope: Map.take(envelope, ["subtype", "result"])
         })}

      {:error, _decode_error} ->
        {:error, ai_error("Não consegui ler a resposta da IA.", %{output: String.slice(output, 0, 200)})}
    end
  end

  defp run(fun, opts) do
    case Cli.run(fun, timeout(opts)) do
      {:ok, {output, 0}} ->
        parse_output(output)

      {:ok, {output, code}} ->
        {:error,
         ai_error("O `claude` saiu com código #{code}.", %{output: String.slice(output, 0, 500)})}

      {:error, {:exit, reason}} ->
        {:error, ai_error("O `claude` morreu.", %{reason: inspect(reason)})}

      {:error, :timeout} ->
        {:error,
         Error.new(:ai_timeout, "A IA não respondeu a tempo.", %{timeout_ms: timeout(opts)})}
    end
  end

  defp ai_error(message, details), do: Error.new(:ai_unavailable, message, details)

  defp tool_args(opts) do
    case opts[:allowed_tools] do
      [_first | _rest] = tools -> ["--allowedTools", Enum.join(tools, ",")]
      _none -> []
    end
  end

  defp model_args(opts) do
    case opts[:model] do
      model when is_binary(model) -> ["--model", model]
      _none -> []
    end
  end

  defp executable, do: config()[:executable] || "claude"

  defp timeout(opts), do: opts[:timeout_ms] || config()[:timeout_ms] || @default_timeout_ms

  defp config, do: Application.get_env(:deckex, __MODULE__, [])
end
```

- [ ] **Step 6: Wire the adapter and the mock**

In `config/config.exs`, next to the Scryfall port line, add:

```elixir
config :deckex, Deckex.AI.Client, adapter: Deckex.AI.ClaudeCli

# Model for bulk role classification, and how many cards go in one call.
config :deckex, Deckex.AI, model: "sonnet", batch_size: 15
```

In `config/test.exs`, next to the Scryfall mock line, add:

```elixir
config :deckex, Deckex.AI.Client, adapter: Deckex.AI.Mock
```

In `test/support/mocks.ex`, add:

```elixir
Mox.defmock(Deckex.AI.Mock, for: Deckex.AI.Client)
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `mix test test/deckex/ai/claude_cli_test.exs`
Expected: PASS — 8 tests.

- [ ] **Step 8: Run the gate and commit**

```bash
mix lint && git add -A && git commit -m "feat: add the AI port backed by the claude CLI

stdin from /dev/null and a hard timeout, so a CLI call can never hang an Oban
slot. No tools unless the caller allows them explicitly."
```

---

### Task 7: Classify the residue with the AI

**Files:**
- Create: `lib/deckex/cards/role_ai.ex`
- Create: `lib/deckex/workers/classify_cards_worker.ex`
- Modify: `lib/deckex/cards.ex` (add `classify_all/1`)
- Test: `test/deckex/cards/role_ai_test.exs`

**Interfaces:**
- Consumes: `Deckex.AI.complete/3` (Task 6), `Roles.residue?/1` (Task 4),
  `Cards.roles_for/1` (Task 5), `RoleMatch.kinds/0` (Task 1).
- Produces:
  - `Deckex.Cards.RoleAI.classify([%Card{}]) :: {:ok, %{card_id :: String.t() => [%RoleMatch{}]}} | {:error, %Deckex.Error{}}` — keyed by card **id**, not by struct
  - `Deckex.Cards.RoleAI.schema() :: map()` — the JSON schema sent to the model
  - `Deckex.Cards.classify_all([%Card{}]) :: {:ok, %{rules: non_neg_integer(), ai: non_neg_integer()}}`
  - `Deckex.Workers.ClassifyCardsWorker.enqueue([card_id :: String.t()]) :: {:ok, Oban.Job.t()} | {:error, term()}`

- [ ] **Step 1: Write the failing test**

Create `test/deckex/cards/role_ai_test.exs`:

```elixir
defmodule Deckex.Cards.RoleAITest do
  use Deckex.DataCase, async: true

  import Mox

  alias Deckex.Cards
  alias Deckex.Cards.Card
  alias Deckex.Cards.RoleAI
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.Error
  alias Deckex.ScryfallFixture

  setup :verify_on_exit!

  defp insert_fixture(name) do
    attrs = name |> ScryfallFixture.load!() |> ScryfallMapper.to_attrs()

    %Card{} |> Card.changeset(attrs) |> Repo.insert!()
  end

  describe "schema/0" do
    test "constrains roles to the known vocabulary" do
      schema = RoleAI.schema()
      enum = get_in(schema, ["properties", "cards", "items", "properties", "roles", "items", "enum"])

      assert "ramp" in enum
      assert "cost_reduction" in enum
      refute "banana" in enum
    end
  end

  describe "classify/1" do
    test "asks the model only about the cards it is given" do
      card = insert_fixture("young_pyromancer")

      expect(Deckex.AI.Mock, :complete, fn prompt, _schema, _opts ->
        assert prompt =~ "Young Pyromancer"

        {:ok,
         %{
           "cards" => [
             %{"name" => "Young Pyromancer", "roles" => ["wincon"], "reasoning" => "faz fichas"}
           ]
         }}
      end)

      assert {:ok, matches} = RoleAI.classify([card])
      assert [%{kind: :wincon, confidence: :medium, evidence: "faz fichas"}] = matches[card.id]
    end

    test "ignores a role the model invented" do
      card = insert_fixture("young_pyromancer")

      expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts ->
        {:ok,
         %{
           "cards" => [
             %{"name" => "Young Pyromancer", "roles" => ["wincon", "banana"], "reasoning" => "x"}
           ]
         }}
      end)

      assert {:ok, matches} = RoleAI.classify([card])
      assert Enum.map(matches[card.id], & &1.kind) == [:wincon]
    end

    test "ignores a card name the model hallucinated" do
      card = insert_fixture("young_pyromancer")

      expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts ->
        {:ok,
         %{"cards" => [%{"name" => "Carta Que Não Existe", "roles" => ["ramp"], "reasoning" => "x"}]}}
      end)

      assert {:ok, matches} = RoleAI.classify([card])
      assert matches == %{}
    end

    test "returns an empty map without calling the model for an empty list" do
      assert {:ok, matches} = RoleAI.classify([])
      # `%{}` on the left of a match would succeed against ANY map, so compare.
      assert matches == %{}
    end

    test "propagates an AI failure as a domain error" do
      card = insert_fixture("young_pyromancer")

      expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts ->
        {:error, Error.new(:ai_timeout, "estourou")}
      end)

      assert {:error, %Error{code: :ai_timeout}} = RoleAI.classify([card])
    end
  end

  describe "Cards.classify_all/1" do
    test "uses rules for what it can and the AI only for the residue" do
      sol_ring = insert_fixture("sol_ring")
      pyromancer = insert_fixture("young_pyromancer")

      # Sol Ring never reaches the model: the rules place it for free.
      expect(Deckex.AI.Mock, :complete, fn prompt, _schema, _opts ->
        assert prompt =~ "Young Pyromancer"
        refute prompt =~ "Sol Ring"

        {:ok,
         %{
           "cards" => [
             %{"name" => "Young Pyromancer", "roles" => ["wincon"], "reasoning" => "fichas"}
           ]
         }}
      end)

      assert {:ok, %{rules: 1, ai: 1}} = Cards.classify_all([sol_ring, pyromancer])

      assert [%{kind: :ramp, source: :rule}] = Cards.roles_for(sol_ring)
      assert [%{kind: :wincon, source: :ai}] = Cards.roles_for(pyromancer)
    end

    test "does not call the model at all when the rules cover everything" do
      # verify_on_exit! fails the test if the mock is called.
      sol_ring = insert_fixture("sol_ring")
      cultivate = insert_fixture("cultivate")

      assert {:ok, %{rules: 2, ai: 0}} = Cards.classify_all([sol_ring, cultivate])
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/deckex/cards/role_ai_test.exs`
Expected: FAIL — `module Deckex.Cards.RoleAI is not available`.

- [ ] **Step 3: Write the AI classifier**

Create `lib/deckex/cards/role_ai.ex`:

```elixir
defmodule Deckex.Cards.RoleAI do
  @moduledoc """
  Classifies the cards the rule engine could not place.

  Only residue reaches this module, and every verdict is cached on the card
  forever, so the cost of a card is paid once across every deck the user will
  ever import. The model's answer is filtered against `RoleMatch.kinds/0` and
  against the cards actually asked about — a model that invents a role or a card
  name must not be able to write either into the database.

  AI verdicts are stored at `:medium` confidence. They are good, but they are
  not a regex over a field that says exactly what the card does.
  """

  alias Deckex.AI
  alias Deckex.Cards.Card
  alias Deckex.Cards.RoleMatch

  @spec schema() :: map()
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "cards" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "name" => %{"type" => "string"},
              "roles" => %{
                "type" => "array",
                "items" => %{"type" => "string", "enum" => Enum.map(RoleMatch.kinds(), &to_string/1)}
              },
              "reasoning" => %{"type" => "string"}
            },
            "required" => ["name", "roles", "reasoning"]
          }
        }
      },
      "required" => ["cards"]
    }
  end

  @doc """
  Classifies `cards`, returning a map of card id to the roles the model
  assigned.
  """
  @spec classify([Card.t()]) :: {:ok, %{String.t() => [RoleMatch.t()]}} | {:error, Deckex.Error.t()}
  def classify([]), do: {:ok, %{}}

  def classify(cards) do
    by_name = Map.new(cards, &{&1.name, &1})

    case AI.complete(prompt(cards), schema()) do
      {:ok, %{"cards" => results}} -> {:ok, collect(results, by_name)}
      {:ok, _unexpected} -> {:ok, %{}}
      {:error, _reason} = error -> error
    end
  end

  defp collect(results, by_name) do
    results
    |> Enum.reduce(%{}, fn result, acc ->
      case Map.fetch(by_name, result["name"]) do
        {:ok, card} -> put_matches(acc, card, result)
        :error -> acc
      end
    end)
  end

  defp put_matches(acc, card, result) do
    case matches(result) do
      [] -> acc
      matches -> Map.put(acc, card.id, matches)
    end
  end

  defp matches(result) do
    known = MapSet.new(RoleMatch.kinds(), &to_string/1)
    reasoning = result["reasoning"] || "classificado pela IA"

    result
    |> Map.get("roles", [])
    |> Enum.filter(&MapSet.member?(known, &1))
    |> Enum.map(&RoleMatch.new(String.to_existing_atom(&1), :medium, reasoning))
  end

  defp prompt(cards) do
    kinds = RoleMatch.kinds() |> Enum.map_join(", ", &to_string/1)

    cards_block =
      Enum.map_join(cards, "\n\n", fn card ->
        """
        Name: #{card.name}
        Mana cost: #{card.mana_cost || "none"}
        Type: #{card.type_line}
        Text: #{card.oracle_text || "(none)"}
        """
      end)

    """
    You are classifying Magic: The Gathering cards by the role they play in a
    Commander (EDH) deck. For each card below, return every role that applies.

    Valid roles: #{kinds}

    Guidance on the distinctions that matter:
    - `ramp` is repeatable or permanent mana acceleration. `ritual` is a one-shot
      burst of mana from an instant or sorcery. They are not the same.
    - `cost_reduction` discounts OTHER spells you cast, not the card itself.
    - `fixing` corrects colours; it is separate from producing extra mana.
    - `counter` only counters spells. `spot_removal` answers a permanent that has
      already resolved. Never label a counterspell as removal.
    - Only assign a role you are confident about. An empty list is a valid and
      useful answer.

    Cards:

    #{cards_block}
    """
  end
end
```

- [ ] **Step 4: Add `classify_all/1` to the context**

In `lib/deckex/cards.ex`, add `alias Deckex.Cards.RoleAI` and:

```elixir
  @doc """
  Classifies every card in `cards`: rules first for free, then one AI call for
  whatever the rules could not place. Returns how many cards each path handled.
  """
  @spec classify_all([Card.t()]) ::
          {:ok, %{rules: non_neg_integer(), ai: non_neg_integer()}} | {:error, Error.t()}
  def classify_all(cards) do
    {residue, handled} = Enum.split_with(cards, &Roles.residue?/1)

    Enum.each(handled, &classify_card/1)

    with {:ok, ai_matches} <- RoleAI.classify(residue) do
      Enum.each(residue, fn card ->
        ai_matches
        |> Map.get(card.id, [])
        |> Enum.each(&upsert_role!(card, &1, :ai))
      end)

      {:ok, %{rules: length(handled), ai: map_size(ai_matches)}}
    end
  end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/deckex/cards/role_ai_test.exs`
Expected: PASS — 8 tests.

- [ ] **Step 6: Write the worker**

Create `lib/deckex/workers/classify_cards_worker.ex`:

```elixir
defmodule Deckex.Workers.ClassifyCardsWorker do
  @moduledoc """
  Classifies a batch of cards off the request path. Args are ids, never structs.

  A card that has vanished is a permanent failure (`:cancel`), not something to
  retry; an AI timeout is transient and retries with backoff.
  """
  use Oban.Worker, queue: :ai, max_attempts: 3

  alias Deckex.Cards

  @doc "Enqueues classification for the given card ids."
  @spec enqueue([String.t()]) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(card_ids) when is_list(card_ids) do
    %{card_ids: card_ids} |> new() |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"card_ids" => card_ids}}) do
    case Cards.list_by_ids(card_ids) do
      [] -> {:cancel, "nenhuma carta encontrada"}
      cards -> classify(cards)
    end
  end

  defp classify(cards) do
    case Cards.classify_all(cards) do
      {:ok, _counts} -> :ok
      {:error, %{code: :ai_timeout} = error} -> {:error, error}
      {:error, error} -> {:cancel, error.message}
    end
  end
end
```

- [ ] **Step 7: Add the id lookup the worker needs**

In `lib/deckex/cards/card_query.ex`, add:

```elixir
  @doc "Lists cards by id, in no particular order."
  @spec list_by_ids([String.t()]) :: [Card.t()]
  def list_by_ids([]), do: []

  def list_by_ids(ids) when is_list(ids) do
    Repo.all(from c in Card, where: c.id in ^ids)
  end
```

In `lib/deckex/cards.ex`, add `defdelegate list_by_ids(ids), to: CardQuery`.

- [ ] **Step 8: Write the worker test**

Create `test/deckex/workers/classify_cards_worker_test.exs`:

```elixir
defmodule Deckex.Workers.ClassifyCardsWorkerTest do
  use Deckex.DataCase, async: true

  import Mox

  alias Deckex.Cards
  alias Deckex.Cards.Card
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.ScryfallFixture
  alias Deckex.Workers.ClassifyCardsWorker

  setup :verify_on_exit!

  defp insert_fixture(name) do
    attrs = name |> ScryfallFixture.load!() |> ScryfallMapper.to_attrs()

    %Card{} |> Card.changeset(attrs) |> Repo.insert!()
  end

  test "classifies the cards it is given" do
    card = insert_fixture("sol_ring")

    assert :ok = perform_job(ClassifyCardsWorker, %{card_ids: [card.id]})
    assert [%{kind: :ramp}] = Cards.roles_for(card)
  end

  test "cancels rather than retrying when no card exists" do
    assert {:cancel, _reason} = perform_job(ClassifyCardsWorker, %{card_ids: [Ecto.UUID.generate()]})
  end
end
```

Add `use Oban.Testing, repo: Deckex.Repo` to `test/support/data_case.ex`'s
`quote` block so `perform_job/2` is available.

- [ ] **Step 9: Run the tests to verify they pass**

Run: `mix test test/deckex/workers/classify_cards_worker_test.exs`
Expected: PASS — 2 tests.

- [ ] **Step 10: Run the gate and commit**

```bash
mix lint && git add -A && git commit -m "feat: classify residue cards with the AI, cached forever

Only cards the rules cannot place reach the model, and its answer is filtered
against the known vocabulary and the cards actually asked about."
```

---

### Task 8: Regression over the real deck

The point of the whole plan: the numbers that made the manual diagnosis land
must now come out of the engine, and must stay correct.

**Files:**
- Test: `test/deckex/cards/roles_regression_test.exs`

**Interfaces:**
- Consumes: everything above.
- Produces: no code.

- [ ] **Step 1: Write the regression test**

Create `test/deckex/cards/roles_regression_test.exs`:

```elixir
defmodule Deckex.Cards.RolesRegressionTest do
  @moduledoc """
  Locks in the rule verdicts that a manual pass over a real Commander deck
  produced. These are the numbers the mana and interaction lenses will be built
  on; if a rule change breaks one, this test says so loudly.
  """
  use ExUnit.Case, async: true

  alias Deckex.Cards.Card
  alias Deckex.Cards.Roles
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.ScryfallFixture

  defp kinds(fixture) do
    fixture
    |> ScryfallFixture.load!()
    |> ScryfallMapper.to_attrs()
    |> then(&struct!(Card, &1))
    |> Roles.classify()
    |> Enum.map(& &1.kind)
    |> Enum.sort()
  end

  test "Sol Ring is ramp and nothing else" do
    assert kinds("sol_ring") == [:ramp]
  end

  test "Cultivate is ramp and fixing" do
    assert kinds("cultivate") == [:fixing, :ramp]
  end

  test "Desperate Ritual is a ritual, never ramp" do
    roles = kinds("desperate_ritual")

    assert :ritual in roles
    refute :ramp in roles
  end

  test "Goblin Electromancer is cost reduction, never ramp" do
    roles = kinds("goblin_electromancer")

    assert :cost_reduction in roles
    refute :ramp in roles
  end

  test "Arid Mesa is fixing, never ramp" do
    assert kinds("arid_mesa") == [:fixing]
  end

  test "Counterspell is a counter, never spot removal" do
    assert kinds("counterspell") == [:counter]
  end

  test "Overwhelming Victory is spot removal, never a board wipe" do
    roles = kinds("overwhelming_victory")

    assert :spot_removal in roles
    refute :board_wipe in roles
  end

  test "Blasphemous Act is a board wipe and not cost reduction" do
    roles = kinds("blasphemous_act")

    assert :board_wipe in roles
    refute :cost_reduction in roles
  end

  test "Mystical Tutor is a tutor; Nature's Lore is not" do
    assert :tutor in kinds("mystical_tutor")
    refute :tutor in kinds("natures_lore")
  end
end
```

- [ ] **Step 2: Run it**

Run: `mix test test/deckex/cards/roles_regression_test.exs`
Expected: PASS — 9 tests.

- [ ] **Step 3: Run the full suite and the gate, then commit**

```bash
mix test && mix lint && git add -A && git commit -m "test: lock in the role verdicts from a real deck"
```

---

## What this plan delivers

```elixir
{:ok, %{cards: cards}} = Deckex.Cards.resolve_names(decklist)
{:ok, %{rules: 94, ai: 6}} = Deckex.Cards.classify_all(cards)
```

Every card carries its roles, each stamped with where the verdict came from and
the evidence behind it. Rules handle the overwhelming majority for free; the AI
sees only what they could not place, once, ever.

This is the input the four diagnostic lenses need. Plan 4 turns these counts
into findings.

## Next plans

| Plan | Spec milestone | Delivers |
|---|---|---|
| 3 | 4 | `Deckex.Decks`, the decklist parser, the Moxfield port, the import pipeline |
| 4 | 5 | `Deckex.Analysis` — the four lenses and the findings catalogue |
| 5 | 6 | `Deckex.Consults` — briefings, per-lens schemas, AI diagnosis |
| 6 | 7 | The UI: design tokens, then Mesa → Deck → Lente → Consultas → Ajustes |
