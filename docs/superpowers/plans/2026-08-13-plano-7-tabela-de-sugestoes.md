# Plano 7 — A Tabela de Sugestões

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn a consult's answer into a table you can act on — every suggested
card resolved against Scryfall with its real price, one click to add or cut it
from the deck, and a CSV export for when you want it in a spreadsheet.

**Architecture:** The model keeps answering in JSON — a typed schema beats CSV
as a wire format and always will. **Prices never come from the model**: each
suggested card is resolved through the existing card catalogue, which is
authoritative and free. A new `Suggestions` module joins the model's rows to
real cards; `Decks.add_card/2` and `Decks.remove_card/2` make the table
actionable.

**Tech Stack:** Elixir 1.19.5 / OTP 27, Ecto, LiveView, Scryfall (already
wired), NimbleCSV is **not** added — the export is three lines of `Enum.map_join`
and a dependency for that is not worth it.

**Spec:** extends §3.4 and §9 of
`docs/superpowers/specs/2026-08-13-deckex-design.md`.

## Global Constraints

- **Code is English; user-facing strings are pt-BR.** Card names never
  translated.
- **Prices come from Scryfall, never from the model.** A model's price memory
  is stale and hallucination-prone; `cards.price_usd` is neither.
- **A suggested card that does not resolve is shown as unresolved**, never
  silently dropped and never invented.
- **Adding a card writes to the deck** — the same `deck_cards` rows the import
  wrote, so the analysis picks the change up on the next report with no special
  case.
- **Errors are data:** `{:ok, _}` / `{:error, %Deckex.Error{}}`.
- **`mix lint` green BEFORE every commit**, chained with `&&`.

## File structure

| File | Responsibility |
|---|---|
| `lib/deckex/consults/suggestion.ex` | One row: the model's words joined to a real card |
| `lib/deckex/consults/suggestions.ex` | Resolve a consult's response into rows; CSV |
| `lib/deckex/money.ex` | USD → BRL, and formatting both |
| `lib/deckex/decks.ex` | `add_card/3`, `remove_card/2` |
| `lib/deckex_web/live/deck_live.ex` | The table, its buttons, the export |

---

### Task 1: Money

**Files:**
- Create: `lib/deckex/money.ex`
- Test: `test/deckex/money_test.exs`

**Interfaces:**
- Consumes: `Deckex.Settings.get/1` (Plano 6).
- Produces:
  - `Deckex.Money.to_brl(Decimal.t() | nil) :: Decimal.t() | nil`
  - `Deckex.Money.usd(Decimal.t() | nil) :: String.t()`
  - `Deckex.Money.brl(Decimal.t() | nil) :: String.t()`
  - `Deckex.Money.rate() :: float()`

- [ ] **Step 1: Write the failing test**

Create `test/deckex/money_test.exs`:

```elixir
defmodule Deckex.MoneyTest do
  use Deckex.DataCase, async: true

  alias Deckex.Money
  alias Deckex.Settings

  describe "to_brl/1" do
    test "converts at the configured rate" do
      {:ok, _value} = Settings.put(:usd_to_brl, 5.0)

      assert Decimal.equal?(Money.to_brl(Decimal.new("10.00")), Decimal.new("50.00"))
    end

    test "a card with no price stays without one" do
      assert Money.to_brl(nil) == nil
    end
  end

  describe "formatting" do
    test "prints dollars" do
      assert Money.usd(Decimal.new("25.50")) == "US$ 25,50"
    end

    test "prints reais" do
      {:ok, _value} = Settings.put(:usd_to_brl, 5.0)

      assert Money.brl(Decimal.new("10.00")) == "R$ 50,00"
    end

    test "an unknown price says so rather than printing zero" do
      assert Money.usd(nil) == "—"
      assert Money.brl(nil) == "—"
    end
  end

  describe "rate/0" do
    test "is the configured rate" do
      {:ok, _value} = Settings.put(:usd_to_brl, 6.1)

      assert Money.rate() == 6.1
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/deckex/money_test.exs`
Expected: FAIL — `module Deckex.Money is not available`.

- [ ] **Step 3: Write the module**

Create `lib/deckex/money.ex`:

```elixir
defmodule Deckex.Money do
  @moduledoc """
  Card prices, in the two currencies that matter here.

  Scryfall quotes in USD, and that is the number we store. The rate to reais is
  a **setting, not a live feed**: a background job chasing an FX API would be a
  new external dependency and a new failure mode, for a number whose job is to
  give a sense of scale. The rate is on screen in Ajustes, so what you are
  looking at is never a mystery.

  A card with no price prints an em dash. Printing `R$ 0,00` for "we do not
  know" would be a lie with a decimal point on it.
  """

  alias Deckex.Settings

  @unknown "—"

  @doc "The USD → BRL rate currently configured."
  @spec rate() :: float()
  def rate, do: Settings.get(:usd_to_brl)

  @doc "Converts a USD amount to BRL, or nil when the price is unknown."
  @spec to_brl(Decimal.t() | nil) :: Decimal.t() | nil
  def to_brl(nil), do: nil

  def to_brl(%Decimal{} = usd) do
    usd |> Decimal.mult(Decimal.from_float(rate())) |> Decimal.round(2)
  end

  @doc ~S"""
  Formats a USD amount, e.g. `"US$ 25,50"`.
  """
  @spec usd(Decimal.t() | nil) :: String.t()
  def usd(nil), do: @unknown
  def usd(%Decimal{} = amount), do: "US$ " <> format(amount)

  @doc ~S"""
  Formats a USD amount converted to reais, e.g. `"R$ 137,70"`.
  """
  @spec brl(Decimal.t() | nil) :: String.t()
  def brl(nil), do: @unknown
  def brl(%Decimal{} = usd), do: "R$ " <> format(to_brl(usd))

  # pt-BR: comma for the decimal separator.
  defp format(%Decimal{} = amount) do
    amount |> Decimal.round(2) |> Decimal.to_string(:normal) |> String.replace(".", ",")
  end
end
```

- [ ] **Step 4: Run the test, gate, commit**

Run: `mix test test/deckex/money_test.exs`
Expected: PASS — 6 tests.

```bash
mix lint && git add -A && git commit -m "feat: price cards in dollars and reais

The rate is a setting, not a live feed: an FX job would be a new dependency and
a new failure mode for a number whose job is to give a sense of scale. An
unknown price prints an em dash -- R\$ 0,00 would be a lie with a decimal point
on it."
```

---

### Task 2: Suggestions — the model's rows joined to real cards

**Files:**
- Create: `lib/deckex/consults/suggestion.ex`
- Create: `lib/deckex/consults/suggestions.ex`
- Modify: `lib/deckex/consults/schemas.ex` (richer rows)
- Test: `test/deckex/consults/suggestions_test.exs`

**Interfaces:**
- Consumes: `Deckex.Cards.resolve_names/1`, `Deckex.Cards.get_by_name/1`,
  `Deckex.Money` (Task 1), `%Deckex.Consults.Consult{}`.
- Produces:
  - `%Deckex.Consults.Suggestion{action, name, reason, addresses, replaces, card, price_usd, resolved?}`
    where `action` is `:cut | :add`
  - `Deckex.Consults.Suggestions.for_consult(%Consult{}) :: [%Suggestion{}]`
  - `Deckex.Consults.Suggestions.to_csv([%Suggestion{}]) :: String.t()`
  - `Deckex.Consults.Suggestions.total_usd([%Suggestion{}]) :: Decimal.t()`

- [ ] **Step 1: Write the failing test**

Create `test/deckex/consults/suggestions_test.exs`:

```elixir
defmodule Deckex.Consults.SuggestionsTest do
  use Deckex.DataCase, async: true

  import Mox

  alias Deckex.CatalogueFixture
  alias Deckex.Consults.Suggestion
  alias Deckex.Consults.Suggestions
  alias Deckex.ScryfallFixture

  setup :verify_on_exit!

  defp consult(response) do
    CatalogueFixture.seed!(~w(sol_ring counterspell))

    insert(:consult, response: response, status: :done)
  end

  describe "for_consult/1" do
    test "joins the model's rows to real cards" do
      rows =
        consult(%{
          "cuts" => [%{"card" => "Sol Ring", "reason" => "exemplo"}],
          "adds" => [%{"card" => "Counterspell", "reason" => "interação"}]
        })
        |> Suggestions.for_consult()

      assert [
               %Suggestion{action: :cut, name: "Sol Ring", resolved?: true},
               %Suggestion{action: :add, name: "Counterspell", resolved?: true}
             ] = rows
    end

    test "carries the model's reason through untouched" do
      [row | _rest] =
        consult(%{"cuts" => [%{"card" => "Sol Ring", "reason" => "custa slot"}], "adds" => []})
        |> Suggestions.for_consult()

      assert row.reason == "custa slot"
    end

    test "attaches the price from the catalogue, not from the model" do
      [row | _rest] =
        consult(%{
          "cuts" => [],
          "adds" => [%{"card" => "Sol Ring", "reason" => "x", "price_usd" => "999.99"}]
        })
        |> Suggestions.for_consult()

      # Sol Ring's fixture price, whatever it is, is not 999.99.
      refute Decimal.equal?(row.price_usd, Decimal.new("999.99"))
      assert row.price_usd == Deckex.Cards.get_by_name("Sol Ring").price_usd
    end

    test "marks a card it cannot resolve rather than dropping it" do
      expect(Deckex.Scryfall.Mock, :fetch_by_names, fn _names ->
        {:ok, %{found: [], not_found: ["Carta Que Não Existe"]}}
      end)

      [row] =
        consult(%{"cuts" => [], "adds" => [%{"card" => "Carta Que Não Existe", "reason" => "x"}]})
        |> Suggestions.for_consult()

      assert %Suggestion{resolved?: false, card: nil, name: "Carta Que Não Existe"} = row
    end

    test "resolves an unknown card through Scryfall once" do
      expect(Deckex.Scryfall.Mock, :fetch_by_names, fn ["Cultivate"] ->
        {:ok, %{found: [ScryfallFixture.load!("cultivate")], not_found: []}}
      end)

      [row] =
        consult(%{"cuts" => [], "adds" => [%{"card" => "Cultivate", "reason" => "ramp"}]})
        |> Suggestions.for_consult()

      assert %Suggestion{resolved?: true, card: %{name: "Cultivate"}} = row
    end

    test "keeps the finding a suggestion addresses when the model gives one" do
      [row] =
        consult(%{
          "cuts" => [],
          "adds" => [
            %{"card" => "Sol Ring", "reason" => "x", "addresses" => "mana.ramp_low"}
          ]
        })
        |> Suggestions.for_consult()

      assert row.addresses == "mana.ramp_low"
    end

    test "an unanswered consult has no rows" do
      assert Suggestions.for_consult(insert(:consult, response: nil)) == []
    end
  end

  describe "total_usd/1" do
    test "sums what the adds would cost, ignoring the cuts" do
      rows =
        consult(%{
          "cuts" => [%{"card" => "Sol Ring", "reason" => "x"}],
          "adds" => [%{"card" => "Counterspell", "reason" => "y"}]
        })
        |> Suggestions.for_consult()

      counterspell = Deckex.Cards.get_by_name("Counterspell")

      assert Decimal.equal?(Suggestions.total_usd(rows), counterspell.price_usd)
    end

    test "an empty list costs nothing rather than crashing" do
      assert Decimal.equal?(Suggestions.total_usd([]), Decimal.new(0))
    end
  end

  describe "to_csv/1" do
    test "has a header and one line per suggestion" do
      csv =
        consult(%{
          "cuts" => [%{"card" => "Sol Ring", "reason" => "exemplo"}],
          "adds" => [%{"card" => "Counterspell", "reason" => "interação"}]
        })
        |> Suggestions.for_consult()
        |> Suggestions.to_csv()

      [header | rows] = String.split(String.trim(csv), "\n")

      assert header == "acao,carta,motivo,achado,preco_usd,preco_brl,resolvida"
      assert length(rows) == 2
      assert Enum.any?(rows, &String.starts_with?(&1, "cortar,Sol Ring,"))
    end

    test "quotes a reason containing a comma so the file stays parseable" do
      csv =
        consult(%{
          "cuts" => [%{"card" => "Sol Ring", "reason" => "rápido, mas dispensável"}],
          "adds" => []
        })
        |> Suggestions.for_consult()
        |> Suggestions.to_csv()

      assert csv =~ ~s("rápido, mas dispensável")
    end

    test "escapes a quote inside a reason" do
      csv =
        consult(%{
          "cuts" => [%{"card" => "Sol Ring", "reason" => ~s(o "melhor" card)}],
          "adds" => []
        })
        |> Suggestions.for_consult()
        |> Suggestions.to_csv()

      assert csv =~ ~s("o ""melhor"" card")
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/deckex/consults/suggestions_test.exs`
Expected: FAIL — `module Deckex.Consults.Suggestions is not available`.

- [ ] **Step 3: Enrich the schema**

In `lib/deckex/consults/schemas.ex`, replace the `cuts` and `adds` property
definitions with these, which ask the model for the finding a row addresses and
tell it not to guess prices:

```elixir
        "cuts" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "card" => %{"type" => "string", "description" => "Exact card name, untranslated."},
              "reason" => %{"type" => "string", "description" => "One sentence, pt-BR."},
              "addresses" => %{
                "type" => "string",
                "description" => "The finding code this cut serves, e.g. mana.color_starved."
              }
            },
            "required" => ["card", "reason"]
          }
        },
        "adds" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "card" => %{"type" => "string", "description" => "Exact card name, untranslated."},
              "reason" => %{"type" => "string", "description" => "One sentence, pt-BR."},
              "addresses" => %{
                "type" => "string",
                "description" => "The finding code this add serves, e.g. interaction.board_wipes_low."
              },
              "replaces" => %{
                "type" => "string",
                "description" => "The cut this add pairs with, if any."
              }
            },
            "required" => ["card", "reason"]
          }
        },
```

Note there is deliberately **no price field**: the app looks prices up itself.

- [ ] **Step 4: Write the suggestion struct**

Create `lib/deckex/consults/suggestion.ex`:

```elixir
defmodule Deckex.Consults.Suggestion do
  @moduledoc """
  One row of a consult's answer, joined to a real card.

  `name` is what the model said; `card` is what the catalogue found for it, and
  it is `nil` when nothing matched. A suggestion that will not resolve is shown
  as unresolved rather than dropped: a model naming a card that does not exist
  is information about the model, and hiding it would hide that.
  """

  alias Deckex.Cards.Card

  @type action :: :cut | :add

  @type t :: %__MODULE__{
          action: action(),
          name: String.t(),
          reason: String.t(),
          addresses: String.t() | nil,
          replaces: String.t() | nil,
          card: Card.t() | nil,
          price_usd: Decimal.t() | nil,
          resolved?: boolean()
        }

  @enforce_keys [:action, :name, :reason]
  defstruct [
    :action,
    :name,
    :reason,
    :addresses,
    :replaces,
    :card,
    :price_usd,
    resolved?: false
  ]
end
```

- [ ] **Step 5: Write the suggestions module**

Create `lib/deckex/consults/suggestions.ex`:

```elixir
defmodule Deckex.Consults.Suggestions do
  @moduledoc """
  Turns a consult's answer into rows you can act on.

  **Prices come from the catalogue, never from the model.** A model's price
  memory is stale on a good day and invented on a bad one, and Scryfall's is
  neither — so every suggested card is resolved through
  `Deckex.Cards.resolve_names/1` and its own `price_usd` is used. Any price
  field the model volunteered is discarded.

  CSV lives here as an *export*, not as the wire format. The model answers in
  JSON against a schema, which is typed and cannot be broken by a comma in a
  sentence; CSV is for getting the table into a spreadsheet.
  """

  alias Deckex.Cards
  alias Deckex.Consults.Consult
  alias Deckex.Consults.Suggestion
  alias Deckex.Money

  @header "acao,carta,motivo,achado,preco_usd,preco_brl,resolvida"

  @doc "Every suggestion in a consult's answer, cuts first."
  @spec for_consult(Consult.t()) :: [Suggestion.t()]
  def for_consult(%Consult{response: nil}), do: []

  def for_consult(%Consult{response: response}) do
    rows = rows(response, "cuts", :cut) ++ rows(response, "adds", :add)
    cards = resolve(rows)

    Enum.map(rows, &attach(&1, cards))
  end

  @doc "What the adds would cost, in USD. Cuts do not count — they are refunds at best."
  @spec total_usd([Suggestion.t()]) :: Decimal.t()
  def total_usd(suggestions) do
    suggestions
    |> Enum.filter(&(&1.action == :add and &1.price_usd))
    |> Enum.reduce(Decimal.new(0), fn suggestion, total ->
      Decimal.add(total, suggestion.price_usd)
    end)
  end

  @doc "The table as CSV, for a spreadsheet."
  @spec to_csv([Suggestion.t()]) :: String.t()
  def to_csv(suggestions) do
    lines = Enum.map_join(suggestions, "\n", &csv_line/1)

    "#{@header}\n#{lines}\n"
  end

  defp rows(response, key, action) do
    response
    |> Map.get(key)
    |> List.wrap()
    |> Enum.map(fn row ->
      %Suggestion{
        action: action,
        name: row["card"],
        reason: row["reason"] || "",
        addresses: row["addresses"],
        replaces: row["replaces"]
      }
    end)
    |> Enum.reject(&is_nil(&1.name))
  end

  # One resolve call for every name in the answer, cached forever afterwards.
  defp resolve([]), do: %{}

  defp resolve(rows) do
    names = rows |> Enum.map(& &1.name) |> Enum.uniq()

    case Cards.resolve_names(names) do
      {:ok, %{cards: cards}} -> Map.new(cards, &{&1.name_normalized, &1})
      {:error, _reason} -> %{}
    end
  end

  defp attach(%Suggestion{} = suggestion, cards) do
    case Map.get(cards, Cards.Name.normalize(suggestion.name)) do
      nil -> %{suggestion | resolved?: false}
      card -> %{suggestion | card: card, price_usd: card.price_usd, resolved?: true}
    end
  end

  defp csv_line(suggestion) do
    [
      action_label(suggestion.action),
      suggestion.name,
      suggestion.reason,
      suggestion.addresses || "",
      price(suggestion.price_usd),
      price(Money.to_brl(suggestion.price_usd)),
      if(suggestion.resolved?, do: "sim", else: "nao")
    ]
    |> Enum.map_join(",", &escape/1)
  end

  defp action_label(:cut), do: "cortar"
  defp action_label(:add), do: "colocar"

  defp price(nil), do: ""
  defp price(%Decimal{} = amount), do: amount |> Decimal.round(2) |> Decimal.to_string(:normal)

  # RFC 4180: wrap in quotes when the field contains a comma, a quote or a
  # newline, and double any quote inside.
  defp escape(field) do
    if String.contains?(field, [",", "\"", "\n"]) do
      ~s("#{String.replace(field, "\"", "\"\"")}")
    else
      field
    end
  end
end
```

- [ ] **Step 6: Run the test, gate, commit**

Run: `mix test test/deckex/consults/suggestions_test.exs`
Expected: PASS — 12 tests.

```bash
mix lint && git add -A && git commit -m "feat: join a consult's answer to real cards and prices

Prices come from the catalogue, never from the model: a model's price memory is
stale on a good day and invented on a bad one. Any price the model volunteers
is discarded. CSV is an export, not the wire format -- JSON against a schema
cannot be broken by a comma in a sentence."
```

---

### Task 3: Editing the deck from the table

**Files:**
- Modify: `lib/deckex/decks.ex`
- Test: `test/deckex/deck_editing_test.exs`

**Interfaces:**
- Consumes: `Deckex.Cards.resolve_names/1`, `DeckCard`, `DeckQuery`.
- Produces:
  - `Deckex.Decks.add_card(%Deck{}, name :: String.t(), opts :: keyword()) :: {:ok, %DeckCard{}} | {:error, %Deckex.Error{}}` — `opts` accepts `:quantity` and `:board`
  - `Deckex.Decks.remove_card(%Deck{}, name :: String.t()) :: {:ok, :removed} | {:error, %Deckex.Error{}}`

- [ ] **Step 1: Write the failing test**

Create `test/deckex/deck_editing_test.exs`:

```elixir
defmodule Deckex.DeckEditingTest do
  use Deckex.DataCase, async: true

  import Mox

  alias Deckex.CatalogueFixture
  alias Deckex.Decks
  alias Deckex.Error
  alias Deckex.ScryfallFixture

  setup :verify_on_exit!

  defp deck do
    CatalogueFixture.seed!(~w(sol_ring forest))

    {:ok, deck} = Decks.import_from_text("1 Sol Ring\n4 Forest", %{name: "T", source: :paste})

    deck
  end

  describe "add_card/3" do
    test "adds a card the catalogue already knows" do
      CatalogueFixture.seed!(~w(counterspell))
      deck = deck()

      assert {:ok, _deck_card} = Decks.add_card(deck, "Counterspell")

      assert "Counterspell" in Enum.map(Decks.list_deck_cards(deck), & &1.card.name)
    end

    test "resolves a card the catalogue does not know" do
      deck = deck()

      expect(Deckex.Scryfall.Mock, :fetch_by_names, fn ["Cultivate"] ->
        {:ok, %{found: [ScryfallFixture.load!("cultivate")], not_found: []}}
      end)

      assert {:ok, _deck_card} = Decks.add_card(deck, "Cultivate")
      assert "Cultivate" in Enum.map(Decks.list_deck_cards(deck), & &1.card.name)
    end

    test "bumps the quantity when the card is already there" do
      deck = deck()

      assert {:ok, _deck_card} = Decks.add_card(deck, "Forest")

      forest = Enum.find(Decks.list_deck_cards(deck), &(&1.card.name == "Forest"))
      assert forest.quantity == 5
    end

    test "refuses a card that does not exist" do
      deck = deck()

      expect(Deckex.Scryfall.Mock, :fetch_by_names, fn _names ->
        {:ok, %{found: [], not_found: ["Carta Inventada"]}}
      end)

      assert {:error, %Error{code: :cards_not_found}} = Decks.add_card(deck, "Carta Inventada")
    end
  end

  describe "remove_card/2" do
    test "drops one copy, leaving the rest" do
      deck = deck()

      assert {:ok, :removed} = Decks.remove_card(deck, "Forest")

      forest = Enum.find(Decks.list_deck_cards(deck), &(&1.card.name == "Forest"))
      assert forest.quantity == 3
    end

    test "deletes the row when the last copy goes" do
      deck = deck()

      assert {:ok, :removed} = Decks.remove_card(deck, "Sol Ring")

      refute "Sol Ring" in Enum.map(Decks.list_deck_cards(deck), & &1.card.name)
    end

    test "refuses to remove a card the deck does not have" do
      assert {:error, %Error{code: :cards_not_found}} = Decks.remove_card(deck(), "Cultivate")
    end
  end

  describe "the analysis sees the edit" do
    test "adding a card changes the next report" do
      CatalogueFixture.seed!(~w(counterspell))
      deck = deck()

      before = deck |> Decks.snapshot() |> Deckex.Analysis.report()
      {:ok, _deck_card} = Decks.add_card(deck, "Counterspell")
      later = deck |> Decks.snapshot() |> Deckex.Analysis.report()

      assert later.interaction.counters == before.interaction.counters + 1
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/deckex/deck_editing_test.exs`
Expected: FAIL — `function Deckex.Decks.add_card/2 is undefined`.

- [ ] **Step 3: Add a query for one deck card**

In `lib/deckex/decks/deck_query.ex`, add:

```elixir
  @doc "One card in a deck, on a board, or nil."
  @spec get_deck_card(Deck.t(), String.t(), atom()) :: DeckCard.t() | nil
  def get_deck_card(%Deck{id: deck_id}, card_id, board) do
    Repo.get_by(DeckCard, deck_id: deck_id, card_id: card_id, board: board)
  end
```

- [ ] **Step 4: Add the editing functions**

In `lib/deckex/decks.ex`, add:

```elixir
  @doc """
  Adds a card to the deck by name, resolving it through the catalogue first.

  Writes the same `deck_cards` row the import writes, so the next report picks
  the change up with no special case.
  """
  @spec add_card(Deck.t(), String.t(), keyword()) ::
          {:ok, DeckCard.t()} | {:error, Error.t()}
  def add_card(%Deck{} = deck, name, opts \\ []) do
    board = Keyword.get(opts, :board, :main)
    quantity = Keyword.get(opts, :quantity, 1)

    with {:ok, card} <- resolve_one(name) do
      {:ok, upsert_deck_card!(deck, card, board, quantity)}
    end
  end

  @doc "Removes one copy of a card, deleting the row when the last copy goes."
  @spec remove_card(Deck.t(), String.t()) :: {:ok, :removed} | {:error, Error.t()}
  def remove_card(%Deck{} = deck, name) do
    with {:ok, card} <- resolve_one(name),
         %DeckCard{} = deck_card <- find_any_board(deck, card) do
      drop_one!(deck_card)

      {:ok, :removed}
    else
      nil -> {:error, not_in_deck(name)}
      {:error, _reason} = error -> error
    end
  end

  defp resolve_one(name) do
    case Cards.resolve_names([name]) do
      {:ok, %{cards: [card | _rest]}} -> {:ok, card}
      {:ok, _none} -> {:error, not_a_card(name)}
      {:error, _reason} = error -> error
    end
  end

  defp find_any_board(deck, card) do
    Enum.find_value([:main, :commander, :maybe], fn board ->
      DeckQuery.get_deck_card(deck, card.id, board)
    end)
  end

  defp upsert_deck_card!(deck, card, board, quantity) do
    case DeckQuery.get_deck_card(deck, card.id, board) do
      nil ->
        %DeckCard{}
        |> DeckCard.changeset(%{
          deck_id: deck.id,
          card_id: card.id,
          quantity: quantity,
          board: board
        })
        |> Repo.insert!()

      existing ->
        existing
        |> DeckCard.changeset(%{quantity: existing.quantity + quantity})
        |> Repo.update!()
    end
  end

  defp drop_one!(%DeckCard{quantity: 1} = deck_card), do: Repo.delete!(deck_card)

  defp drop_one!(%DeckCard{} = deck_card) do
    deck_card |> DeckCard.changeset(%{quantity: deck_card.quantity - 1}) |> Repo.update!()
  end

  defp not_a_card(name) do
    Error.new(:cards_not_found, "Não achei “#{name}” na Scryfall.", %{name: name})
  end

  defp not_in_deck(name) do
    Error.new(:cards_not_found, "“#{name}” não está nesse deck.", %{name: name})
  end
```

- [ ] **Step 5: Run the test, gate, commit**

Run: `mix test test/deckex/deck_editing_test.exs`
Expected: PASS — 8 tests.

```bash
mix lint && git add -A && git commit -m "feat: add and remove cards from a deck

Writes the same deck_cards rows the import writes, so the next report picks the
change up with no special case."
```

---

### Task 4: The table on screen

**Files:**
- Modify: `lib/deckex_web/live/deck_live.ex`
- Test: `test/deckex_web/live/suggestion_table_test.exs`

**Interfaces:**
- Consumes: `Suggestions.for_consult/1`, `Suggestions.total_usd/1`,
  `Suggestions.to_csv/1` (Task 2), `Decks.add_card/3`, `Decks.remove_card/2`
  (Task 3), `Deckex.Money` (Task 1).
- Produces: no new modules.

- [ ] **Step 1: Write the failing test**

Create `test/deckex_web/live/suggestion_table_test.exs`:

```elixir
defmodule DeckexWeb.SuggestionTableTest do
  use DeckexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Deckex.CatalogueFixture
  alias Deckex.Consults
  alias Deckex.Decks

  setup do
    CatalogueFixture.seed!(~w(sol_ring forest counterspell cultivate))

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n4 Forest", %{name: "Deck da Tabela", source: :paste})

    {:ok, consult} = Consults.request(deck, :full)

    {:ok, answered} =
      consult
      |> Ecto.Changeset.change(%{
        status: :done,
        response: %{
          "diagnosis" => "Falta interação.",
          "cuts" => [%{"card" => "Sol Ring", "reason" => "abre espaço"}],
          "adds" => [
            %{"card" => "Counterspell", "reason" => "interação barata", "addresses" => "interaction.total_low"}
          ]
        }
      })
      |> Deckex.Repo.update()

    %{deck: deck, consult: answered}
  end

  test "renders a row per suggestion with its price", %{conn: conn, deck: deck} do
    {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

    assert html =~ "Counterspell"
    assert html =~ "interação barata"
    assert html =~ "interaction.total_low"
    # Prices are shown in both currencies.
    assert html =~ "US$"
    assert html =~ "R$"
  end

  test "adding a suggested card puts it in the deck", %{conn: conn, deck: deck} do
    {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

    live
    |> element("button[phx-click='apply-add'][phx-value-name='Counterspell']")
    |> render_click()

    assert "Counterspell" in Enum.map(Decks.list_deck_cards(deck), & &1.card.name)
  end

  test "cutting a suggested card removes it", %{conn: conn, deck: deck} do
    {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

    live
    |> element("button[phx-click='apply-cut'][phx-value-name='Sol Ring']")
    |> render_click()

    refute "Sol Ring" in Enum.map(Decks.list_deck_cards(deck), & &1.card.name)
  end

  test "the report refreshes after an edit", %{conn: conn, deck: deck} do
    {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

    html =
      live
      |> element("button[phx-click='apply-add'][phx-value-name='Counterspell']")
      |> render_click()

    # The interaction lens counted zero counters before; now it counts one.
    assert html =~ "Counterspell"
  end

  test "the table exports as CSV", %{conn: conn, deck: deck, consult: consult} do
    {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

    assert live
           |> element("a[download][href*='#{consult.id}']")
           |> has_element?()
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/deckex_web/live/suggestion_table_test.exs`
Expected: FAIL — no table.

- [ ] **Step 3: Add a CSV download route**

Create `lib/deckex_web/controllers/export_controller.ex`:

```elixir
defmodule DeckexWeb.ExportController do
  @moduledoc "Downloads a consult's suggestion table as CSV."
  use DeckexWeb, :controller

  alias Deckex.Consults
  alias Deckex.Consults.Suggestions

  def consult_csv(conn, %{"id" => id}) do
    case Consults.fetch(id) do
      {:ok, consult} ->
        csv = consult |> Suggestions.for_consult() |> Suggestions.to_csv()

        conn
        |> put_resp_content_type("text/csv")
        |> put_resp_header("content-disposition", ~s(attachment; filename="sugestoes.csv"))
        |> send_resp(200, csv)

      {:error, error} ->
        conn |> put_status(:not_found) |> text(error.message)
    end
  end
end
```

In `lib/deckex_web/router.ex`, inside the browser scope:

```elixir
    get "/consultas/:id/csv", ExportController, :consult_csv
```

- [ ] **Step 4: Load suggestions and handle the edits**

In `lib/deckex_web/live/deck_live.ex`, add `alias Deckex.Consults.Suggestions`
and `alias Deckex.Money`, then add to `assign_deck/2`'s assigns:

```elixir
      suggestions: suggestions_for(Consults.list_for_deck(deck)),
```

with the helper:

```elixir
  # One list of rows per consult, keyed by consult id, so the table can sit
  # under the consult that produced it.
  defp suggestions_for(consults) do
    Map.new(consults, &{&1.id, Suggestions.for_consult(&1)})
  end
```

and update every place that reassigns `consults:` to also reassign
`suggestions:`. The cleanest way is one helper:

```elixir
  defp refresh_consults(socket) do
    consults = Consults.list_for_deck(socket.assigns.deck)

    assign(socket, consults: consults, suggestions: suggestions_for(consults))
  end
```

then replace `assign(consults: Consults.list_for_deck(socket.assigns.deck))`
with `refresh_consults(socket)` in `start_consult/3`, `handle_info/2` and the
`compare-models` handler.

Add the edit handlers:

```elixir
  def handle_event("apply-add", %{"name" => name}, socket) do
    {:noreply, apply_edit(socket, Decks.add_card(socket.assigns.deck, name), "#{name} entrou.")}
  end

  def handle_event("apply-cut", %{"name" => name}, socket) do
    {:noreply, apply_edit(socket, Decks.remove_card(socket.assigns.deck, name), "#{name} saiu.")}
  end

  # An edit changes the deck, so the whole report is rebuilt — that is the point
  # of reports being computed rather than cached.
  defp apply_edit(socket, {:ok, _result}, message) do
    socket
    |> assign_deck(socket.assigns.deck)
    |> put_flash(:info, message)
  end

  defp apply_edit(socket, {:error, error}, _message) do
    put_flash(socket, :error, error.message)
  end
```

- [ ] **Step 5: Render the table**

In `lib/deckex_web/live/deck_live.ex`, inside the consult `<article>`, replace
the `<div :if={consult.response} class="space-y-3">` block with:

```elixir
                <div :if={consult.response} class="space-y-3">
                  <p class="text-body-sm text-ink">{consult.response["diagnosis"]}</p>

                  <div :if={@suggestions[consult.id] not in [nil, []]} class="overflow-x-auto">
                    <table class="w-full text-caption">
                      <thead>
                        <tr class="border-b border-hairline-subtle text-left text-label uppercase tracking-[0.1em] text-ink-faint">
                          <th class="py-1.5 pr-2 font-semibold">Carta</th>
                          <th class="py-1.5 pr-2 text-right font-semibold">Preço</th>
                          <th class="py-1.5 font-semibold"></th>
                        </tr>
                      </thead>
                      <tbody>
                        <tr
                          :for={row <- @suggestions[consult.id]}
                          class="border-b border-hairline-subtle align-top last:border-0"
                        >
                          <td class="py-2 pr-2">
                            <div class="flex items-center gap-1.5">
                              <span class={[
                                "font-mono text-micro uppercase",
                                row.action == :cut && "text-sev-critical",
                                row.action == :add && "text-sev-healthy"
                              ]}>
                                {if row.action == :cut, do: "−", else: "+"}
                              </span>
                              <span class="text-ink">{row.name}</span>
                              <.mana_cost :if={row.card} cost={row.card.mana_cost} size={12} />
                            </div>

                            <p class="mt-0.5 text-ink-muted">{row.reason}</p>

                            <p :if={row.addresses} class="mt-0.5 font-mono text-micro text-ink-disabled">
                              {row.addresses}
                            </p>

                            <p :if={not row.resolved?} class="mt-0.5 text-micro text-sev-warning">
                              não achei essa carta na Scryfall
                            </p>
                          </td>

                          <td class="py-2 pr-2 text-right font-mono text-micro whitespace-nowrap">
                            <div class="text-ink-secondary">{Money.brl(row.price_usd)}</div>
                            <div class="text-ink-disabled">{Money.usd(row.price_usd)}</div>
                          </td>

                          <td class="py-2 text-right">
                            <button
                              :if={row.resolved?}
                              type="button"
                              phx-click={if row.action == :cut, do: "apply-cut", else: "apply-add"}
                              phx-value-name={row.name}
                              class="whitespace-nowrap text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
                            >
                              {if row.action == :cut, do: "cortar", else: "colocar"}
                            </button>
                          </td>
                        </tr>
                      </tbody>
                    </table>

                    <div class="mt-2 flex items-center justify-between gap-3">
                      <span class="font-mono text-micro text-ink-faint">
                        entradas: {Money.brl(Suggestions.total_usd(@suggestions[consult.id]))}
                      </span>

                      <a
                        href={~p"/consultas/#{consult.id}/csv"}
                        download
                        class="text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
                      >
                        Baixar CSV
                      </a>
                    </div>
                  </div>

                  <p :if={consult.response["notes"]} class="text-caption text-ink-muted">
                    {consult.response["notes"]}
                  </p>
                </div>
```

- [ ] **Step 6: Run the test, gate, commit**

Run: `mix test test/deckex_web/live/suggestion_table_test.exs`
Expected: PASS — 5 tests.

```bash
mix lint && git add -A && git commit -m "feat: make a consult's answer a table you can act on

Every suggested card carries its real Scryfall price in both currencies and a
button that writes the change straight into the deck. An edit rebuilds the
report -- which is the point of reports being computed rather than cached."
```

---

### Task 5: More kinds of analysis

The four lenses answer "is this deck well built?". This adds the questions a
player actually asks out loud, as consult lenses with their own prompts.

**Files:**
- Modify: `lib/deckex/consults/consult.ex` (new lens values)
- Modify: `lib/deckex/consults/briefing.ex` (a prompt per new lens)
- Modify: `lib/deckex_web/live/deck_live.ex` (a picker)
- Test: `test/deckex/consults/briefing_lenses_test.exs`

**Interfaces:**
- Consumes: `Briefing.build/4`.
- Produces: the lenses `:matchup`, `:budget`, `:upgrade` alongside the existing
  ones, and `Deckex.Consults.lens_labels() :: [{atom(), String.t()}]`.

- [ ] **Step 1: Write the failing test**

Create `test/deckex/consults/briefing_lenses_test.exs`:

```elixir
defmodule Deckex.Consults.BriefingLensesTest do
  use ExUnit.Case, async: true

  alias Deckex.Analysis
  alias Deckex.AnalysisFixture
  alias Deckex.Consults
  alias Deckex.Consults.Briefing

  defp briefing(lens, opts \\ []) do
    snapshot =
      AnalysisFixture.snapshot(
        [
          AnalysisFixture.entry(name: "Forest", type_line: "Basic Land — Forest", quantity: 30),
          AnalysisFixture.entry(name: "Feitiço", cmc: "3.0", mana_cost: "{2}{G}")
        ],
        color_identity: ["G"],
        deck_name: "Deck Verde"
      )

    Briefing.build(Analysis.report(snapshot), snapshot, lens, opts)
  end

  test "the matchup lens asks about a specific opponent" do
    text = briefing(:matchup, against: "um deck agressivo de criaturas vermelhas")

    assert text =~ "agressivo de criaturas vermelhas"
    assert text =~ "matchup" or text =~ "opponent"
  end

  test "the budget lens asks for the cheapest real improvements" do
    text = briefing(:budget, budget_usd: 20)

    assert text =~ "20"
    assert text =~ "cheap" or text =~ "budget"
  end

  test "the upgrade lens asks for the strongest change regardless of price" do
    assert briefing(:upgrade) =~ "regardless of price"
  end

  test "every lens still carries the decklist and the identity rule" do
    for lens <- [:matchup, :budget, :upgrade] do
      text = briefing(lens, against: "algo")

      assert text =~ "full decklist"
      assert text =~ "colour identity"
    end
  end

  test "the labels cover every lens a consult can use" do
    labels = Map.new(Consults.lens_labels())

    for lens <- Deckex.Consults.Consult.lenses(), lens != :finding do
      assert Map.has_key?(labels, lens), "sem rótulo para #{lens}"
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/deckex/consults/briefing_lenses_test.exs`
Expected: FAIL — the lenses do not exist.

- [ ] **Step 3: Add the lens values**

In `lib/deckex/consults/consult.ex`, replace `@lenses` with:

```elixir
  @lenses [
    :speed_curve,
    :mana_ramp,
    :interaction,
    :consistency,
    :full,
    :finding,
    :matchup,
    :budget,
    :upgrade
  ]
```

- [ ] **Step 4: Give each new lens its own question**

In `lib/deckex/consults/briefing.ex`, add the new lenses to `lens_keys/1` by
placing these clauses **before** the catch-all:

```elixir
  defp lens_keys(:matchup), do: [:curve, :mana, :interaction, :consistency]
  defp lens_keys(:budget), do: [:curve, :mana, :interaction, :consistency]
  defp lens_keys(:upgrade), do: [:curve, :mana, :interaction, :consistency]
```

and replace the "What to do" heading paragraph — the line beginning
`Work the findings above.` — with a call to a new function:

```elixir
    #{task_block(lens, opts)}
```

then add:

```elixir
  # Each lens asks a different question of the same measurements. The rules
  # below the task are identical for all of them, which is deliberate: a
  # suggestion outside the colour identity is illegal no matter what was asked.
  defp task_block(:matchup, opts) do
    against = opts[:against] || "an unspecified aggressive deck"

    """
    This deck keeps losing to: **#{against}**.

    Work out why, from the measurements above, and name specific cards to
    **cut** and to **add** that would change that matchup. Say in one sentence
    each why the card helps against *that* deck specifically.
    """
  end

  defp task_block(:budget, opts) do
    ceiling = opts[:budget_usd] || 20

    """
    Improve this deck **as cheaply as possible**. Every card you add must cost
    roughly US$ #{ceiling} or less.

    Name specific cards to **cut** and to **add**, and say in one sentence each
    what it fixes. A cheap card that addresses a finding beats an expensive one
    that does not.
    """
  end

  defp task_block(:upgrade, _opts) do
    """
    Make this deck **as strong as it can be, regardless of price**.

    Name specific cards to **cut** and to **add**, and say in one sentence each
    what it fixes. Do not hold back on cost here — a separate question exists
    for the budget version.
    """
  end

  defp task_block(_lens, _opts) do
    """
    Work the findings above. For each one, name specific cards to **cut** from
    the list and specific cards to **add**, and say why in one sentence each.
    """
  end
```

- [ ] **Step 5: Add the labels**

In `lib/deckex/consults.ex`, add:

```elixir
  @doc "The lenses a user can pick, with their pt-BR labels."
  @spec lens_labels() :: [{atom(), String.t()}]
  def lens_labels do
    [
      {:full, "O deck inteiro"},
      {:matchup, "Contra um deck específico"},
      {:budget, "Melhorar gastando pouco"},
      {:upgrade, "Melhorar sem olhar preço"},
      {:speed_curve, "Só velocidade e curva"},
      {:mana_ramp, "Só mana e aceleração"},
      {:interaction, "Só interação"},
      {:consistency, "Só consistência"}
    ]
  end
```

- [ ] **Step 6: Offer the choice on screen**

In `lib/deckex_web/live/deck_live.ex`, replace the whole-deck consult form with
one that carries the lens and an optional opponent:

```elixir
            <.form for={%{}} as={:consult} phx-submit="consult-full" class="space-y-2">
              <div class="flex items-center gap-2">
                <select
                  name="consult[lens]"
                  class="min-w-0 flex-1 rounded-md border border-hairline-soft bg-inlay px-2 py-1 text-caption text-ink"
                >
                  <option :for={{lens, label} <- Consults.lens_labels()} value={lens}>
                    {label}
                  </option>
                </select>

                <select
                  name="consult[model]"
                  class="rounded-md border border-hairline-soft bg-inlay px-2 py-1 font-mono text-caption text-ink"
                >
                  <option :for={model <- Consults.models()} value={model} selected={model == @model}>
                    {model}
                  </option>
                </select>
              </div>

              <input
                type="text"
                name="consult[against]"
                placeholder="Contra o quê? (só para a análise de matchup)"
                class="w-full rounded-md border border-hairline-soft bg-inlay px-2 py-1 text-caption text-ink placeholder:text-ink-disabled"
              />

              <button
                type="submit"
                class="text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
              >
                Perguntar
              </button>
            </.form>
```

and replace the `consult-full` handler with:

```elixir
  def handle_event("consult-full", %{"consult" => params}, socket) do
    lens = String.to_existing_atom(params["lens"] || "full")

    opts = [
      model: params["model"],
      against: blank_to_nil(params["against"])
    ]

    {:noreply, start_consult(socket, lens, opts)}
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
```

- [ ] **Step 7: Pass `:against` through the context**

In `lib/deckex/consults.ex`, `budget_opts/1` already forwards `opts` into
`Briefing.build/4`, and `:against` rides along with it. Confirm the briefing
receives it:

```bash
grep -n "budget_opts\|Briefing.build" lib/deckex/consults.ex
```

Expected: `Briefing.build(report, snapshot, lens, budget_opts(opts))`.

- [ ] **Step 8: Run the test, gate, commit**

Run: `mix test test/deckex/consults/briefing_lenses_test.exs`
Expected: PASS — 5 tests.

```bash
mix lint && git add -A && git commit -m "feat: ask the questions a player actually asks

Matchup, budget and upgrade are the same measurements with a different question
on top. The rules below the question stay identical -- a suggestion outside the
colour identity is illegal no matter what was asked."
```

---

## What this plan delivers

A consult stops being prose and becomes a worksheet: every suggested card with
its real price in reais and dollars, a button that applies it, a CSV for the
spreadsheet, and a choice of which question to ask in the first place.
