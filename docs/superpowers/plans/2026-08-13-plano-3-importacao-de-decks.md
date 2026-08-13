# Plano 3 — Importação de Decks

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn a pasted decklist (or, when Moxfield allows it, a URL) into a
stored deck with every card resolved, classified and attributed to a board —
the input the analysis lenses need.

**Architecture:** A pure parser turns decklist text into entries. `Deckex.Decks`
orchestrates: resolve names through the card catalogue, persist deck and cards
in one transaction, then classify asynchronously. Moxfield is a port whose HTTP
failures degrade to the paste path rather than failing the import.

**Tech Stack:** Elixir 1.19.5 / OTP 27, Ecto 3.13, Oban, Req, Phoenix.PubSub, Mox.

**Spec:** `docs/superpowers/specs/2026-08-13-deckex-design.md` §3.2, §4.2, §6 —
this plan implements milestone 4 of §13.

## Global Constraints

- **Code is English; user-facing strings are pt-BR; card names are never
  translated.**
- **Every aggregate is a triad:** context (public API + mutations), Ecto schema,
  `*Query` module (all reads). Edges never build Ecto queries.
- **Errors are data:** `{:ok, _}` / `{:error, %Deckex.Error{}}`.
- **No external call inside an open transaction** (playbook rule 4). Scryfall
  and the AI are reached *before* opening or *after* committing.
- **Every external service is a port:** behaviour + facade + adapter +
  `Application.compile_env` selector + Mox mock. **No test performs network or
  subprocess I/O.**
- **UUID v7 primary keys** via `use Deckex.Schema`; `:utc_datetime` timestamps.
- **Moxfield is blocked and we do not evade it.** An honest User-Agent gets a
  Cloudflare 403 (verified 2026-08-13). Pasting is the primary path; URL sync
  ships wired behind a configurable User-Agent. No browser impersonation, no
  User-Agent rotation, no CAPTCHA handling.
- **`mix lint` must be green BEFORE every commit** — chain it with `&&`.
- **PostgreSQL is on host port 5435.** After editing an applied migration:
  `MIX_ENV=test mix ecto.drop`.

## File structure

| File | Responsibility |
|---|---|
| `lib/deckex/decks/decklist_parser.ex` | Pure: decklist text → entries. No I/O. |
| `lib/deckex/decks/deck.ex` · `deck_card.ex` | Schemas + changesets |
| `lib/deckex/decks/deck_query.ex` | All reads |
| `lib/deckex/decks.ex` | Context: import, commander, mutations |
| `lib/deckex/moxfield/client.ex` · `moxfield.ex` · `moxfield/http.ex` | The port |
| `lib/deckex/moxfield/deck_mapper.ex` | Moxfield JSON → decklist text |
| `lib/deckex/events.ex` | PubSub topics and payloads |
| `lib/deckex/workers/import_deck_worker.ex` | Async URL import |

---

### Task 1: The decklist parser

**Files:**
- Create: `lib/deckex/decks/decklist_parser.ex`
- Modify: `lib/deckex/error.ex` (add `:empty_decklist` to the code type)
- Test: `test/deckex/decks/decklist_parser_test.exs`

**Interfaces:**
- Consumes: `Deckex.Error.new/3`.
- Produces:
  - `%Deckex.Decks.DecklistParser.Entry{quantity: pos_integer(), name: String.t(), board: :commander | :main | :maybe}`
  - `Deckex.Decks.DecklistParser.parse(String.t()) :: {:ok, [Entry.t()]} | {:error, Deckex.Error.t()}`

- [ ] **Step 1: Write the failing test**

Create `test/deckex/decks/decklist_parser_test.exs`:

```elixir
defmodule Deckex.Decks.DecklistParserTest do
  use ExUnit.Case, async: true

  alias Deckex.Decks.DecklistParser
  alias Deckex.Decks.DecklistParser.Entry
  alias Deckex.Error

  defp parse!(text) do
    {:ok, entries} = DecklistParser.parse(text)
    entries
  end

  describe "parse/1 card lines" do
    test "reads quantity and name" do
      assert [%Entry{quantity: 1, name: "Sol Ring", board: :main}] = parse!("1 Sol Ring")
    end

    test "reads a quantity above one" do
      assert [%Entry{quantity: 4, name: "Forest"}] = parse!("4 Forest")
    end

    test "accepts the 4x spelling" do
      assert [%Entry{quantity: 4, name: "Forest"}] = parse!("4x Forest")
    end

    test "keeps the set code and collector number on the name" do
      # Deckex.Cards.Name strips them later; the parser must not lose
      # information the catalogue might want.
      assert [%Entry{name: "Cultivate (M21) 177"}] = parse!("1 Cultivate (M21) 177")
    end

    test "drops the foil and etched markers" do
      assert [%Entry{name: "Sol Ring (M3C) 305"}] = parse!("1 Sol Ring (M3C) 305 *F*")
      assert [%Entry{name: "Scalding Tarn (MH2) 439"}] = parse!("1 Scalding Tarn (MH2) 439 *E*")
    end

    test "keeps a double-faced name intact, slash and all" do
      assert [%Entry{name: "Birgi, God of Storytelling / Harnfel, Horn of Bounty (KHM) 123"}] =
               parse!("1 Birgi, God of Storytelling / Harnfel, Horn of Bounty (KHM) 123")
    end
  end

  describe "parse/1 boards" do
    test "everything is main by default" do
      assert [%Entry{board: :main}, %Entry{board: :main}] = parse!("1 Sol Ring\n1 Cultivate")
    end

    test "a Commander header puts the next cards on the commander board" do
      text = """
      Commander
      1 Iroh, Grand Lotus
      """

      assert [%Entry{name: "Iroh, Grand Lotus", board: :commander}] = parse!(text)
    end

    test "a Commander header with a colon works too" do
      assert [%Entry{board: :commander}] = parse!("Commander:\n1 Iroh, Grand Lotus")
    end

    test "a dashed separator ends the commander section" do
      # This is the shape a real export took: a Commander header, one card, a
      # rule of dashes, then the rest of the deck.
      text = """
      Commander:
      1 Iroh, Grand Lotus (TLA) 227 *F*

       ----
      1 Sol Ring (M3C) 305
      """

      assert [
               %Entry{name: "Iroh, Grand Lotus (TLA) 227", board: :commander},
               %Entry{name: "Sol Ring (M3C) 305", board: :main}
             ] = parse!(text)
    end

    test "a Deck header returns to the main board" do
      text = """
      Commander
      1 Iroh, Grand Lotus
      Deck
      1 Sol Ring
      """

      assert [%Entry{board: :commander}, %Entry{board: :main}] = parse!(text)
    end

    test "sideboard and maybeboard land on the maybe board" do
      text = """
      1 Sol Ring
      Maybeboard
      1 Cultivate
      """

      assert [%Entry{board: :main}, %Entry{name: "Cultivate", board: :maybe}] = parse!(text)
    end

    test "the SB: prefix marks a single line as maybe" do
      assert [%Entry{name: "Cultivate", board: :maybe}] = parse!("SB: 1 Cultivate")
    end
  end

  describe "parse/1 noise" do
    test "ignores blank lines and prose" do
      text = """
      Nome do deck: Iroh das Lontra

      Tema: rampar no começo e segurar o game

      1 Sol Ring
      """

      assert [%Entry{name: "Sol Ring"}] = parse!(text)
    end

    test "ignores a line that merely starts with a word" do
      assert parse!("Commander\n1 Iroh, Grand Lotus\nobrigado!") |> length() == 1
    end
  end

  describe "parse/1 failure" do
    test "a decklist with no card lines is an error, not an empty deck" do
      assert {:error, %Error{code: :empty_decklist}} = DecklistParser.parse("só conversa fiada")
    end

    test "empty input is an error" do
      assert {:error, %Error{code: :empty_decklist}} = DecklistParser.parse("")
    end
  end

  describe "parse/1 on the real deck" do
    test "reads every line of a real 100-card export" do
      text = File.read!("test/support/fixtures/decklists/iroh_das_lontra.txt")

      assert {:ok, entries} = DecklistParser.parse(text)

      assert length(entries) == 92
      assert Enum.sum(Enum.map(entries, & &1.quantity)) == 101
      assert Enum.count(entries, &(&1.board == :commander)) == 1
      assert %Entry{name: "Iroh, Grand Lotus (TLA) 227"} = hd(entries)
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/deckex/decks/decklist_parser_test.exs`
Expected: FAIL — `module Deckex.Decks.DecklistParser is not available`.

- [ ] **Step 3: Add the new error code**

In `lib/deckex/error.ex`, add `| :empty_decklist` to the `@type code` union,
after `:cards_not_found`.

- [ ] **Step 4: Write the parser**

Create `lib/deckex/decks/decklist_parser.ex`:

```elixir
defmodule Deckex.Decks.DecklistParser do
  @moduledoc """
  Turns decklist text into entries. Pure: no database, no network.

  Real exports carry more than card lines — a title, a description, section
  headers, rules of dashes, and foil markers. Anything that is not a card line
  or a recognized header is ignored rather than guessed at, so a user pasting
  their own notes above the list still gets a clean import.

  Set codes and collector numbers are **kept on the name**. `Deckex.Cards.Name`
  strips them when resolving; throwing them away here would lose information the
  catalogue might later want.
  """

  alias Deckex.Error

  defmodule Entry do
    @moduledoc "One parsed decklist line."

    @type board :: :commander | :main | :maybe
    @type t :: %__MODULE__{quantity: pos_integer(), name: String.t(), board: board()}

    @enforce_keys [:quantity, :name, :board]
    defstruct [:quantity, :name, :board]
  end

  # "1 Sol Ring", "4x Forest", "SB: 1 Cultivate"
  @card_line ~r/^\s*(?:(SB):\s*)?(\d+)x?\s+(.+?)\s*$/i

  # A trailing foil/etched marker printed by Moxfield.
  @finish_marker ~r/\s*\*[A-Z]\*\s*$/

  # A rule of dashes closes a section and returns to the main deck.
  @separator ~r/^\s*-{3,}\s*$/

  @headers %{
    "commander" => :commander,
    "commanders" => :commander,
    "deck" => :main,
    "main" => :main,
    "mainboard" => :main,
    "sideboard" => :maybe,
    "maybeboard" => :maybe,
    "maybe" => :maybe,
    "considering" => :maybe
  }

  @doc """
  Parses decklist text into entries, in the order they appear.

  Returns `{:error, %Deckex.Error{code: :empty_decklist}}` when no line looks
  like a card — an empty result is far more likely to be a paste mistake than a
  deck with no cards.
  """
  @spec parse(String.t()) :: {:ok, [Entry.t()]} | {:error, Error.t()}
  def parse(text) when is_binary(text) do
    entries =
      text
      |> String.split("\n")
      |> Enum.reduce({:main, []}, &consume_line/2)
      |> elem(1)
      |> Enum.reverse()

    case entries do
      [] -> {:error, empty_error()}
      entries -> {:ok, entries}
    end
  end

  defp consume_line(line, {board, acc}) do
    cond do
      Regex.match?(@separator, line) -> {:main, acc}
      new_board = header(line) -> {new_board, acc}
      entry = card(line, board) -> {board, [entry | acc]}
      true -> {board, acc}
    end
  end

  defp header(line) do
    Map.get(@headers, line |> String.trim() |> String.trim_trailing(":") |> String.downcase())
  end

  defp card(line, board) do
    case Regex.run(@card_line, line) do
      [_all, sideboard, quantity, name] ->
        %Entry{
          quantity: String.to_integer(quantity),
          name: name |> String.replace(@finish_marker, "") |> String.trim(),
          board: if(sideboard == "", do: board, else: :maybe)
        }

      _no_match ->
        nil
    end
  end

  defp empty_error do
    Error.new(
      :empty_decklist,
      "Não achei nenhuma carta nessa lista. Confere se colou a exportação do deck.",
      %{}
    )
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/deckex/decks/decklist_parser_test.exs`
Expected: PASS — 18 tests.

- [ ] **Step 6: Run the gate and commit**

```bash
mix lint && git add -A && git commit -m "feat: parse decklist text into entries

Handles section headers, dashed separators, foil markers and the SB: prefix,
and ignores prose. Verified against a real 100-card export."
```

---

### Task 2: The `decks` and `deck_cards` tables

**Files:**
- Create: `priv/repo/migrations/<timestamp>_create_decks.exs`
- Create: `lib/deckex/decks/deck.ex`
- Create: `lib/deckex/decks/deck_card.ex`
- Create: `lib/deckex/decks/deck_query.ex`
- Modify: `test/support/factory.ex`
- Test: `test/deckex/decks/deck_test.exs`

**Interfaces:**
- Consumes: `use Deckex.Schema`, `Deckex.Cards.Card`.
- Produces:
  - `%Deckex.Decks.Deck{name, moxfield_url, moxfield_public_id, source, color_identity, status, raw_decklist, last_synced_at, last_error, notes, archived_at}`
  - `%Deckex.Decks.DeckCard{deck_id, card_id, quantity, board}`
  - `Deckex.Decks.Deck.changeset/2`, `Deckex.Decks.DeckCard.changeset/2`
  - `Deckex.Decks.DeckQuery.list_decks/0`, `get_deck/1`, `fetch_deck/1`, `list_deck_cards/1`, `get_by_public_id/1`
  - `Deckex.Factory.deck_factory/0`, `deck_card_factory/0`

- [ ] **Step 1: Generate and write the migration**

```bash
mix ecto.gen.migration create_decks
```

Write its contents (keep the generated timestamp in the filename):

```elixir
defmodule Deckex.Repo.Migrations.CreateDecks do
  use Ecto.Migration

  def change do
    create table(:decks, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :string, null: false
      add :moxfield_url, :string
      add :moxfield_public_id, :string
      add :source, :string, null: false
      add :color_identity, {:array, :string}, null: false, default: []
      add :status, :string, null: false

      # The text the deck was built from. Kept so a parser improvement can
      # re-import without asking the user to paste again.
      add :raw_decklist, :text

      add :last_synced_at, :utc_datetime
      add :last_error, :text
      add :notes, :text
      add :archived_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:decks, [:moxfield_public_id],
             where: "moxfield_public_id IS NOT NULL",
             name: :decks_moxfield_public_id_index
           )

    create table(:deck_cards, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :deck_id, references(:decks, type: :uuid, on_delete: :delete_all), null: false
      add :card_id, references(:cards, type: :uuid, on_delete: :restrict), null: false
      add :quantity, :integer, null: false, default: 1
      add :board, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:deck_cards, [:deck_id, :card_id, :board])
    create index(:deck_cards, [:deck_id])
  end
end
```

- [ ] **Step 2: Write the failing test**

Create `test/deckex/decks/deck_test.exs`:

```elixir
defmodule Deckex.Decks.DeckTest do
  use Deckex.DataCase, async: true

  alias Deckex.Decks.Deck
  alias Deckex.Decks.DeckCard
  alias Deckex.Decks.DeckQuery

  describe "Deck.changeset/2" do
    test "accepts a minimal deck" do
      changeset = Deck.changeset(%Deck{}, %{name: "Iroh", source: :paste, status: :ready})

      assert %Ecto.Changeset{valid?: true} = changeset
    end

    test "requires a name, a source and a status" do
      errors = %Deck{} |> Deck.changeset(%{}) |> errors_on()

      for field <- [:name, :source, :status] do
        assert %{^field => ["can't be blank"]} = errors
      end
    end

    test "rejects a source outside the vocabulary" do
      changeset = Deck.changeset(%Deck{}, %{name: "x", source: :carrier_pigeon, status: :ready})

      assert %{source: ["is invalid"]} = errors_on(changeset)
    end

    test "rejects two decks sharing a Moxfield id" do
      attrs = %{name: "a", source: :moxfield, status: :ready, moxfield_public_id: "abc123"}
      assert {:ok, _deck} = %Deck{} |> Deck.changeset(attrs) |> Repo.insert()

      assert {:error, changeset} =
               %Deck{} |> Deck.changeset(%{attrs | name: "b"}) |> Repo.insert()

      assert %{moxfield_public_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "allows many decks without a Moxfield id" do
      attrs = %{name: "a", source: :paste, status: :ready}

      assert {:ok, _first} = %Deck{} |> Deck.changeset(attrs) |> Repo.insert()
      assert {:ok, _second} = %Deck{} |> Deck.changeset(%{attrs | name: "b"}) |> Repo.insert()
    end
  end

  describe "DeckCard.changeset/2" do
    test "accepts a card on a board" do
      deck = insert(:deck)
      card = insert(:card)

      attrs = %{deck_id: deck.id, card_id: card.id, quantity: 1, board: :main}

      assert {:ok, _deck_card} = %DeckCard{} |> DeckCard.changeset(attrs) |> Repo.insert()
    end

    test "rejects the same card twice on the same board" do
      deck = insert(:deck)
      card = insert(:card)
      attrs = %{deck_id: deck.id, card_id: card.id, quantity: 1, board: :main}

      assert {:ok, _first} = %DeckCard{} |> DeckCard.changeset(attrs) |> Repo.insert()
      assert {:error, changeset} = %DeckCard{} |> DeckCard.changeset(attrs) |> Repo.insert()

      assert errors_on(changeset) != %{}
    end

    test "allows the same card on two different boards" do
      deck = insert(:deck)
      card = insert(:card)

      assert {:ok, _main} =
               %DeckCard{}
               |> DeckCard.changeset(%{deck_id: deck.id, card_id: card.id, quantity: 1, board: :main})
               |> Repo.insert()

      assert {:ok, _maybe} =
               %DeckCard{}
               |> DeckCard.changeset(%{deck_id: deck.id, card_id: card.id, quantity: 1, board: :maybe})
               |> Repo.insert()
    end

    test "rejects a quantity below one" do
      deck = insert(:deck)
      card = insert(:card)

      changeset =
        DeckCard.changeset(%DeckCard{}, %{
          deck_id: deck.id,
          card_id: card.id,
          quantity: 0,
          board: :main
        })

      assert %{quantity: ["must be greater than 0"]} = errors_on(changeset)
    end
  end

  describe "DeckQuery" do
    test "lists decks newest first, excluding archived ones" do
      _archived = insert(:deck, name: "velho", archived_at: DateTime.utc_now(:second))
      live = insert(:deck, name: "novo")

      assert [%{id: id}] = DeckQuery.list_decks()
      assert id == live.id
    end

    test "fetch_deck/1 returns a tagged tuple" do
      deck = insert(:deck)

      assert {:ok, %{id: id}} = DeckQuery.fetch_deck(deck.id)
      assert id == deck.id
      assert {:error, %Deckex.Error{code: :deck_not_found}} = DeckQuery.fetch_deck(Ecto.UUID.generate())
    end

    test "lists a deck's cards with the card preloaded" do
      deck = insert(:deck)
      card = insert(:card, name: "Sol Ring")
      insert(:deck_card, deck: deck, card: card, quantity: 1, board: :main)

      assert [%{quantity: 1, card: %{name: "Sol Ring"}}] = DeckQuery.list_deck_cards(deck)
    end

    test "finds a deck by its Moxfield id" do
      deck = insert(:deck, moxfield_public_id: "kq9g4t81")

      assert %{id: id} = DeckQuery.get_by_public_id("kq9g4t81")
      assert id == deck.id
      assert DeckQuery.get_by_public_id("nao-existe") == nil
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `mix test test/deckex/decks/deck_test.exs`
Expected: FAIL — `module Deckex.Decks.Deck is not available`.

- [ ] **Step 4: Add the `:deck_not_found` error code**

In `lib/deckex/error.ex`, add `| :deck_not_found` to the `@type code` union.

- [ ] **Step 5: Write the schemas**

Create `lib/deckex/decks/deck.ex`:

```elixir
defmodule Deckex.Decks.Deck do
  @moduledoc """
  A Commander deck the user tracks.

  `raw_decklist` keeps the text the deck was built from. It costs a column and
  buys re-import without bothering the user: when the parser or the rules
  improve, the deck can be rebuilt from what was originally pasted.
  """
  use Deckex.Schema

  import Ecto.Changeset

  @fields ~w(name moxfield_url moxfield_public_id source color_identity status
             raw_decklist last_synced_at last_error notes archived_at)a
  @required ~w(name source status)a

  @type t :: %__MODULE__{}

  schema "decks" do
    field :name, :string
    field :moxfield_url, :string
    field :moxfield_public_id, :string
    field :source, Ecto.Enum, values: [:moxfield, :paste]
    field :color_identity, {:array, :string}, default: []

    field :status, Ecto.Enum,
      values: [:importing, :enriching, :classifying, :ready, :failed]

    field :raw_decklist, :string
    field :last_synced_at, :utc_datetime
    field :last_error, :string
    field :notes, :string
    field :archived_at, :utc_datetime

    timestamps()
  end

  @doc "Builds a changeset for a deck."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(deck, attrs) do
    deck
    |> cast(attrs, @fields)
    |> validate_required(@required)
    |> unique_constraint(:moxfield_public_id, name: :decks_moxfield_public_id_index)
  end
end
```

Create `lib/deckex/decks/deck_card.ex`:

```elixir
defmodule Deckex.Decks.DeckCard do
  @moduledoc """
  One card in a deck, on one board. The commander lives on the `:commander`
  board rather than in a column on `decks`, so partner commanders need no schema
  change.
  """
  use Deckex.Schema

  import Ecto.Changeset

  alias Deckex.Cards.Card
  alias Deckex.Decks.Deck

  @type t :: %__MODULE__{}

  schema "deck_cards" do
    field :quantity, :integer, default: 1
    field :board, Ecto.Enum, values: [:main, :commander, :maybe]

    belongs_to :deck, Deck
    belongs_to :card, Card

    timestamps()
  end

  @doc "Builds a changeset for a card on a board."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(deck_card, attrs) do
    deck_card
    |> cast(attrs, [:deck_id, :card_id, :quantity, :board])
    |> validate_required([:deck_id, :card_id, :quantity, :board])
    |> validate_number(:quantity, greater_than: 0)
    |> foreign_key_constraint(:deck_id)
    |> foreign_key_constraint(:card_id)
    |> unique_constraint([:deck_id, :card_id, :board])
  end
end
```

- [ ] **Step 6: Write the query module**

Create `lib/deckex/decks/deck_query.ex`:

```elixir
defmodule Deckex.Decks.DeckQuery do
  @moduledoc """
  All reads of decks. Every function ends in a `Repo` call and returns data,
  never an `Ecto.Query`.
  """

  import Ecto.Query

  alias Deckex.Decks.Deck
  alias Deckex.Decks.DeckCard
  alias Deckex.Error
  alias Deckex.Repo

  @doc "Lists live decks, newest first."
  @spec list_decks() :: [Deck.t()]
  def list_decks do
    Repo.all(from d in Deck, where: is_nil(d.archived_at), order_by: [desc: d.inserted_at])
  end

  @doc "Fetches a deck by id, or nil."
  @spec get_deck(String.t()) :: Deck.t() | nil
  def get_deck(id), do: Repo.get(Deck, id)

  @doc "Fetches a deck by id as a tagged tuple."
  @spec fetch_deck(String.t()) :: {:ok, Deck.t()} | {:error, Error.t()}
  def fetch_deck(id) do
    case get_deck(id) do
      nil -> {:error, Error.new(:deck_not_found, "Não achei esse deck.", %{id: id})}
      deck -> {:ok, deck}
    end
  end

  @doc "Fetches a deck by its Moxfield public id, or nil."
  @spec get_by_public_id(String.t()) :: Deck.t() | nil
  def get_by_public_id(public_id), do: Repo.get_by(Deck, moxfield_public_id: public_id)

  @doc "Lists a deck's cards with the card preloaded."
  @spec list_deck_cards(Deck.t()) :: [DeckCard.t()]
  def list_deck_cards(%Deck{id: deck_id}) do
    Repo.all(from dc in DeckCard, where: dc.deck_id == ^deck_id, preload: [:card])
  end
end
```

- [ ] **Step 7: Add the factories**

In `test/support/factory.ex`, add the aliases `Deckex.Decks.Deck` and
`Deckex.Decks.DeckCard`, plus:

```elixir
  def deck_factory do
    %Deck{
      name: sequence(:deck_name, &"Deck #{&1}"),
      source: :paste,
      status: :ready,
      color_identity: [],
      raw_decklist: "1 Sol Ring"
    }
  end

  def deck_card_factory do
    %DeckCard{
      deck: build(:deck),
      card: build(:card),
      quantity: 1,
      board: :main
    }
  end
```

- [ ] **Step 8: Migrate, run the test, gate and commit**

```bash
mix ecto.migrate && mix test test/deckex/decks/deck_test.exs
```

Expected: PASS — 13 tests.

```bash
mix lint && git add -A && git commit -m "feat: add decks and deck_cards tables

The commander lives on a :commander board rather than a column, so partner
commanders need no schema change."
```

---

### Task 3: Import from pasted text

The core of the plan. Parse, resolve every name through the catalogue, persist
in one transaction, and hand classification to a worker.

**Files:**
- Create: `lib/deckex/decks.ex`
- Test: `test/deckex/decks_test.exs`

**Interfaces:**
- Consumes: `DecklistParser.parse/1` (Task 1), `DeckQuery` and the schemas
  (Task 2), `Deckex.Cards.resolve_names/1`, `Deckex.Cards.Name.normalize/1`,
  `Deckex.Workers.ClassifyCardsWorker.enqueue/1`, `Deckex.Repo.transact/1`.
- Produces:
  - `Deckex.Decks.import_from_text(text :: String.t(), attrs :: map()) :: {:ok, %Deck{}} | {:error, %Deckex.Error{}}`
  - `Deckex.Decks.list_decks/0`, `fetch_deck/1`, `list_deck_cards/1`
  - `Deckex.Decks.archive_deck(%Deck{}) :: {:ok, %Deck{}}`

- [ ] **Step 1: Write the failing test**

Create `test/deckex/decks_test.exs`:

```elixir
defmodule Deckex.DecksTest do
  use Deckex.DataCase, async: true

  import Mox

  alias Deckex.Cards.Card
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.Decks
  alias Deckex.Error
  alias Deckex.ScryfallFixture

  setup :verify_on_exit!

  # Seed the catalogue so imports need no Scryfall call at all.
  defp seed_catalogue(names) do
    for name <- names do
      attrs = name |> ScryfallFixture.load!() |> ScryfallMapper.to_attrs()

      %Card{} |> Card.changeset(attrs) |> Repo.insert!()
    end
  end

  describe "import_from_text/2" do
    test "creates a deck with its cards" do
      seed_catalogue(["sol_ring", "cultivate"])

      text = "1 Sol Ring\n1 Cultivate"

      assert {:ok, deck} = Decks.import_from_text(text, %{name: "Teste", source: :paste})
      assert deck.name == "Teste"
      assert deck.source == :paste

      cards = Decks.list_deck_cards(deck)
      assert Enum.map(cards, & &1.card.name) |> Enum.sort() == ["Cultivate", "Sol Ring"]
    end

    test "keeps the quantity of each line" do
      seed_catalogue(["forest"])

      assert {:ok, deck} = Decks.import_from_text("4 Forest", %{name: "T", source: :paste})
      assert [%{quantity: 4}] = Decks.list_deck_cards(deck)
    end

    test "stores the raw decklist so the deck can be rebuilt later" do
      seed_catalogue(["sol_ring"])
      text = "1 Sol Ring"

      assert {:ok, deck} = Decks.import_from_text(text, %{name: "T", source: :paste})
      assert deck.raw_decklist == text
    end

    test "puts the commander on the commander board" do
      seed_catalogue(["sol_ring", "cultivate"])

      text = """
      Commander
      1 Cultivate
       ----
      1 Sol Ring
      """

      assert {:ok, deck} = Decks.import_from_text(text, %{name: "T", source: :paste})

      boards = Map.new(Decks.list_deck_cards(deck), &{&1.card.name, &1.board})
      assert boards == %{"Cultivate" => :commander, "Sol Ring" => :main}
    end

    test "derives colour identity from the commander" do
      seed_catalogue(["cultivate"])

      text = "Commander\n1 Cultivate"

      assert {:ok, deck} = Decks.import_from_text(text, %{name: "T", source: :paste})
      assert deck.color_identity == ["G"]
    end

    test "leaves colour identity empty when no commander was declared" do
      seed_catalogue(["sol_ring"])

      assert {:ok, deck} = Decks.import_from_text("1 Sol Ring", %{name: "T", source: :paste})
      assert deck.color_identity == []
    end

    test "resolves cards missing from the catalogue through Scryfall" do
      expect(Deckex.Scryfall.Mock, :fetch_by_names, fn ["Sol Ring"] ->
        {:ok, %{found: [ScryfallFixture.load!("sol_ring")], not_found: []}}
      end)

      assert {:ok, deck} = Decks.import_from_text("1 Sol Ring", %{name: "T", source: :paste})
      assert [%{card: %{name: "Sol Ring"}}] = Decks.list_deck_cards(deck)
    end

    test "records unresolved names on the deck instead of failing the import" do
      seed_catalogue(["sol_ring"])

      expect(Deckex.Scryfall.Mock, :fetch_by_names, fn _names ->
        {:ok, %{found: [], not_found: ["Carta Inventada"]}}
      end)

      text = "1 Sol Ring\n1 Carta Inventada"

      assert {:ok, deck} = Decks.import_from_text(text, %{name: "T", source: :paste})
      assert deck.last_error =~ "Carta Inventada"
      assert length(Decks.list_deck_cards(deck)) == 1
    end

    test "rejects a decklist with no cards" do
      assert {:error, %Error{code: :empty_decklist}} =
               Decks.import_from_text("conversa fiada", %{name: "T", source: :paste})
    end

    test "propagates a Scryfall failure" do
      expect(Deckex.Scryfall.Mock, :fetch_by_names, fn _names ->
        {:error, Error.new(:scryfall_unavailable, "fora do ar")}
      end)

      assert {:error, %Error{code: :scryfall_unavailable}} =
               Decks.import_from_text("1 Sol Ring", %{name: "T", source: :paste})
    end

    test "leaves the deck ready when every card is already classified" do
      seed_catalogue(["sol_ring"])

      assert {:ok, deck} = Decks.import_from_text("1 Sol Ring", %{name: "T", source: :paste})
      assert deck.status == :ready
    end

    test "marks the deck classifying and enqueues the residue" do
      seed_catalogue(["young_pyromancer"])

      assert {:ok, deck} = Decks.import_from_text("1 Young Pyromancer", %{name: "T", source: :paste})
      assert deck.status == :classifying

      assert_enqueued(worker: Deckex.Workers.ClassifyCardsWorker)
    end
  end

  describe "archive_deck/1" do
    test "hides a deck from the list without deleting it" do
      seed_catalogue(["sol_ring"])
      {:ok, deck} = Decks.import_from_text("1 Sol Ring", %{name: "T", source: :paste})

      assert {:ok, archived} = Decks.archive_deck(deck)
      assert archived.archived_at != nil
      assert Decks.list_decks() == []
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/deckex/decks_test.exs`
Expected: FAIL — `module Deckex.Decks is not available`.

- [ ] **Step 3: Add `Repo.transact/1`**

In `lib/deckex/repo.ex`, add:

```elixir
  @doc """
  Runs `fun` in a transaction, rolling back on `{:error, reason}`.

  Composes with `with` and tagged tuples, unlike `transaction/1`, which wraps
  everything in an extra `{:ok, _}`.
  """
  @spec transact((-> {:ok, any()} | {:error, any()})) :: {:ok, any()} | {:error, any()}
  def transact(fun) do
    transaction(fn ->
      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> rollback(reason)
      end
    end)
  end
```

- [ ] **Step 4: Split the rule pass out of `classify_all/1`**

The context written in the next step needs the rule pass to run synchronously —
it is free and instant — while the AI pass goes to a worker. In
`lib/deckex/cards.ex`, add these two functions next to `classify_all/1`:

```elixir
  @doc """
  Runs only the rule pass over `cards`. Free and instant, so it happens inline
  during import; the AI pass is what goes to a worker.
  """
  @spec classify_all_by_rules([Card.t()]) :: {:ok, %{rules: non_neg_integer()}}
  def classify_all_by_rules(cards) do
    handled = Enum.reject(cards, &Roles.residue?/1)

    Enum.each(handled, &classify_card/1)

    {:ok, %{rules: length(handled)}}
  end

  @doc "Whether the rules failed to place this card, meaning the AI must see it."
  @spec residue?(Card.t()) :: boolean()
  defdelegate residue?(card), to: Roles
```

- [ ] **Step 5: Write the context**

Create `lib/deckex/decks.ex`:

```elixir
defmodule Deckex.Decks do
  @moduledoc """
  The user's decks: importing them, reading them, retiring them.

  The import order is dictated by playbook rule 4 — **no external call inside an
  open transaction**. Scryfall is reached while resolving names, *before* the
  transaction opens; classification runs in a worker, *after* it commits. The
  transaction itself only writes rows.
  """

  alias Deckex.Cards
  alias Deckex.Cards.Name
  alias Deckex.Decks.Deck
  alias Deckex.Decks.DeckCard
  alias Deckex.Decks.DecklistParser
  alias Deckex.Decks.DeckQuery
  alias Deckex.Error
  alias Deckex.Repo
  alias Deckex.Workers.ClassifyCardsWorker

  defdelegate list_decks(), to: DeckQuery
  defdelegate get_deck(id), to: DeckQuery
  defdelegate fetch_deck(id), to: DeckQuery
  defdelegate list_deck_cards(deck), to: DeckQuery

  @doc """
  Imports a deck from decklist text.

  `attrs` carries `:name` and `:source`, plus optionally `:moxfield_url` and
  `:moxfield_public_id`. Names Scryfall could not resolve are recorded on the
  deck rather than failing the import — a deck with 99 of 100 cards is far more
  useful than no deck.
  """
  @spec import_from_text(String.t(), map()) :: {:ok, Deck.t()} | {:error, Error.t()}
  def import_from_text(text, attrs) do
    with {:ok, entries} <- DecklistParser.parse(text),
         {:ok, %{cards: cards, not_found: not_found}} <- resolve(entries),
         {:ok, deck} <- persist(text, attrs, entries, cards, not_found) do
      {:ok, classify_async(deck, cards)}
    end
  end

  @doc "Hides a deck from the list without deleting anything."
  @spec archive_deck(Deck.t()) :: {:ok, Deck.t()} | {:error, Ecto.Changeset.t()}
  def archive_deck(%Deck{} = deck) do
    deck
    |> Deck.changeset(%{archived_at: DateTime.utc_now(:second)})
    |> Repo.update()
  end

  # --- import steps ---------------------------------------------------------

  defp resolve(entries), do: entries |> Enum.map(& &1.name) |> Cards.resolve_names()

  defp persist(text, attrs, entries, cards, not_found) do
    by_key = Map.new(cards, &{&1.name_normalized, &1})
    rows = Enum.flat_map(entries, &deck_card_row(&1, by_key))

    Repo.transact(fn ->
      with {:ok, deck} <- insert_deck(text, attrs, not_found),
           :ok <- insert_deck_cards(deck, rows) do
        {:ok, set_color_identity(deck, rows)}
      end
    end)
  end

  defp deck_card_row(entry, by_key) do
    case Map.fetch(by_key, Name.normalize(entry.name)) do
      {:ok, card} -> [%{card: card, quantity: entry.quantity, board: entry.board}]
      :error -> []
    end
  end

  defp insert_deck(text, attrs, not_found) do
    %Deck{}
    |> Deck.changeset(
      attrs
      |> Map.put(:raw_decklist, text)
      |> Map.put(:status, :importing)
      |> Map.put(:last_error, unresolved_message(not_found))
    )
    |> Repo.insert()
  end

  defp insert_deck_cards(deck, rows) do
    Enum.each(rows, fn row ->
      %DeckCard{}
      |> DeckCard.changeset(%{
        deck_id: deck.id,
        card_id: row.card.id,
        quantity: row.quantity,
        board: row.board
      })
      |> Repo.insert!()
    end)
  end

  defp set_color_identity(deck, rows) do
    identity =
      rows
      |> Enum.filter(&(&1.board == :commander))
      |> Enum.flat_map(& &1.card.color_identity)
      |> Enum.uniq()
      |> Enum.sort()

    deck
    |> Deck.changeset(%{color_identity: identity})
    |> Repo.update!()
  end

  defp unresolved_message([]), do: nil

  defp unresolved_message(names) do
    "Não achei estas cartas na Scryfall: #{Enum.join(names, ", ")}."
  end

  # Classification happens outside the transaction, and asynchronously when
  # there is real work: a deck whose cards the rules already cover is ready the
  # moment it is written.
  defp classify_async(deck, cards) do
    # classify_all_by_rules/1 returns only a :rules count — the AI pass is the
    # worker's job, not this function's.
    {:ok, %{rules: _count}} = Cards.classify_all_by_rules(cards)

    case Enum.filter(cards, &Cards.residue?/1) do
      [] ->
        update_status!(deck, :ready)

      residue ->
        {:ok, _job} = ClassifyCardsWorker.enqueue(Enum.map(residue, & &1.id))
        update_status!(deck, :classifying)
    end
  end

  defp update_status!(deck, status) do
    deck |> Deck.changeset(%{status: status}) |> Repo.update!()
  end
end
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `mix test test/deckex/decks_test.exs`
Expected: PASS — 13 tests.

- [ ] **Step 7: Run the gate and commit**

```bash
mix lint && git add -A && git commit -m "feat: import a deck from pasted decklist text

Scryfall runs before the transaction and classification after it, per the
playbook rule against external calls inside an open transaction. Unresolved
names are recorded on the deck rather than failing the import."
```

---

### Task 4: The Moxfield port

**Files:**
- Create: `lib/deckex/moxfield/client.ex`
- Create: `lib/deckex/moxfield.ex`
- Create: `lib/deckex/moxfield/deck_mapper.ex`
- Create: `lib/deckex/moxfield/http.ex`
- Create: `test/support/fixtures/moxfield/deck.json`
- Modify: `test/support/mocks.ex`, `config/config.exs`, `config/test.exs`
- Test: `test/deckex/moxfield/http_test.exs`, `test/deckex/moxfield/deck_mapper_test.exs`

**Interfaces:**
- Consumes: `Deckex.Error.new/3`.
- Produces:
  - `@callback fetch_deck(public_id :: String.t()) :: {:ok, %{name: String.t(), decklist: String.t()}} | {:error, Deckex.Error.t()}`
  - `Deckex.Moxfield.fetch_deck/1` — the facade
  - `Deckex.Moxfield.DeckMapper.to_decklist(map()) :: {:ok, %{name: String.t(), decklist: String.t()}} | {:error, Deckex.Error.t()}`
  - `Deckex.Moxfield.public_id_from_url(String.t()) :: {:ok, String.t()} | {:error, Deckex.Error.t()}`
  - `Deckex.Moxfield.Mock`

- [ ] **Step 1: Write the URL and error tests**

Create `test/deckex/moxfield/http_test.exs`:

```elixir
defmodule Deckex.Moxfield.HttpTest do
  # async: false — Req.Test stubs are process-owned.
  use ExUnit.Case, async: false

  alias Deckex.Error
  alias Deckex.Moxfield
  alias Deckex.Moxfield.Http

  describe "public_id_from_url/1" do
    test "extracts the id from a deck URL" do
      assert {:ok, "kq9g4t81QUSl-5Vk7dTu2A"} =
               Moxfield.public_id_from_url("https://moxfield.com/decks/kq9g4t81QUSl-5Vk7dTu2A")
    end

    test "tolerates a trailing slash and query string" do
      assert {:ok, "abc123"} =
               Moxfield.public_id_from_url("https://www.moxfield.com/decks/abc123/?utm=x")
    end

    test "accepts a bare id" do
      assert {:ok, "abc123"} = Moxfield.public_id_from_url("abc123")
    end

    test "rejects a URL that is not a Moxfield deck" do
      assert {:error, %Error{code: :moxfield_not_found}} =
               Moxfield.public_id_from_url("https://example.com/oi")
    end
  end

  describe "fetch_deck/1 error mapping" do
    test "a Cloudflare 403 becomes a blocked error that points at pasting" do
      # This is the response an honest User-Agent actually gets, verified
      # against the live endpoint on 2026-08-13.
      Req.Test.stub(Http, fn conn -> Plug.Conn.send_resp(conn, 403, "<html>Cloudflare</html>") end)

      assert {:error, %Error{code: :moxfield_blocked} = error} = Http.fetch_deck("abc123")
      assert error.message =~ "colar"
    end

    test "a 404 becomes a not-found error" do
      Req.Test.stub(Http, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

      assert {:error, %Error{code: :moxfield_not_found}} = Http.fetch_deck("abc123")
    end

    test "a 401 becomes a private-deck error that points at pasting" do
      Req.Test.stub(Http, fn conn -> Plug.Conn.send_resp(conn, 401, "") end)

      assert {:error, %Error{code: :moxfield_private} = error} = Http.fetch_deck("abc123")
      assert error.message =~ "colar"
    end

    test "any other status becomes a blocked error rather than a crash" do
      Req.Test.stub(Http, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)

      assert {:error, %Error{code: :moxfield_blocked}} = Http.fetch_deck("abc123")
    end

    test "a transport failure becomes a blocked error" do
      Req.Test.stub(Http, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %Error{code: :moxfield_blocked}} = Http.fetch_deck("abc123")
    end

    test "sends the configured User-Agent" do
      Req.Test.stub(Http, fn conn ->
        assert ["deckex-test-agent"] = Plug.Conn.get_req_header(conn, "user-agent")

        Plug.Conn.send_resp(conn, 404, "")
      end)

      assert {:error, _error} = Http.fetch_deck("abc123")
    end
  end
end
```

- [ ] **Step 2: Write the mapper test with a clearly-labelled fixture**

Create `test/support/fixtures/moxfield/deck.json`. **This fixture is
hand-written from the community-documented response shape — the live endpoint
returns 403 to an unapproved client, so it could not be captured.** It exists to
pin the mapper's behaviour, not to prove the shape is right.

```json
{
  "name": "Iroh das Lontra",
  "boards": {
    "mainboard": {
      "count": 3,
      "cards": {
        "a1": { "quantity": 1, "card": { "name": "Sol Ring" } },
        "a2": { "quantity": 4, "card": { "name": "Forest" } }
      }
    },
    "commanders": {
      "count": 1,
      "cards": {
        "c1": { "quantity": 1, "card": { "name": "Iroh, Grand Lotus" } }
      }
    },
    "maybeboard": {
      "count": 1,
      "cards": {
        "m1": { "quantity": 1, "card": { "name": "Cultivate" } }
      }
    }
  }
}
```

Create `test/deckex/moxfield/deck_mapper_test.exs`:

```elixir
defmodule Deckex.Moxfield.DeckMapperTest do
  use ExUnit.Case, async: true

  alias Deckex.Error
  alias Deckex.Moxfield.DeckMapper

  defp fixture do
    "test/support/fixtures/moxfield/deck.json" |> File.read!() |> Jason.decode!()
  end

  describe "to_decklist/1" do
    test "reads the deck name" do
      assert {:ok, %{name: "Iroh das Lontra"}} = DeckMapper.to_decklist(fixture())
    end

    test "emits a decklist the parser can read back" do
      assert {:ok, %{decklist: decklist}} = DeckMapper.to_decklist(fixture())
      assert {:ok, entries} = Deckex.Decks.DecklistParser.parse(decklist)

      by_name = Map.new(entries, &{&1.name, &1})

      assert %{quantity: 1, board: :commander} = by_name["Iroh, Grand Lotus"]
      assert %{quantity: 4, board: :main} = by_name["Forest"]
      assert %{quantity: 1, board: :maybe} = by_name["Cultivate"]
    end

    test "rejects a payload with no boards" do
      assert {:error, %Error{code: :moxfield_not_found}} = DeckMapper.to_decklist(%{"name" => "x"})
    end
  end
end
```

- [ ] **Step 3: Run both tests to verify they fail**

Run: `mix test test/deckex/moxfield/`
Expected: FAIL — `module Deckex.Moxfield is not available`.

- [ ] **Step 4: Write the behaviour and facade**

Create `lib/deckex/moxfield/client.ex`:

```elixir
defmodule Deckex.Moxfield.Client do
  @moduledoc """
  Port for fetching a deck from Moxfield. The real adapter is
  `Deckex.Moxfield.Http`; tests use `Deckex.Moxfield.Mock`.
  """

  @callback fetch_deck(public_id :: String.t()) ::
              {:ok, %{name: String.t(), decklist: String.t()}} | {:error, Deckex.Error.t()}
end
```

Create `lib/deckex/moxfield.ex`:

```elixir
defmodule Deckex.Moxfield do
  @moduledoc """
  Facade for the Moxfield port, plus URL parsing.

  **Moxfield has no public API and its Terms of Service prohibit scraping.**
  Programmatic access is gated behind a User-Agent approved by e-mailing
  support@moxfield.com; an honest, identifying User-Agent gets a Cloudflare 403
  (verified 2026-08-13). This client therefore:

  - sends one identifiable, configurable User-Agent — which is precisely what
    makes sanctioned access possible;
  - makes one request per explicit, user-initiated sync, never polling;
  - performs **no detection evasion** of any kind, and never will;
  - degrades to the paste path on any failure.

  Pasting a decklist is the primary import path. This one is wired for the day
  Moxfield approves a User-Agent.
  """
  @behaviour Deckex.Moxfield.Client

  alias Deckex.Error

  @adapter Application.compile_env(
             :deckex,
             [Deckex.Moxfield.Client, :adapter],
             Deckex.Moxfield.Http
           )

  @deck_url ~r{moxfield\.com/decks/([A-Za-z0-9_-]+)}
  @bare_id ~r/^[A-Za-z0-9_-]+$/

  @impl Deckex.Moxfield.Client
  defdelegate fetch_deck(public_id), to: @adapter

  @doc "Extracts the public id from a Moxfield deck URL, or accepts a bare id."
  @spec public_id_from_url(String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def public_id_from_url(url) when is_binary(url) do
    trimmed = String.trim(url)

    cond do
      captures = Regex.run(@deck_url, trimmed) -> {:ok, Enum.at(captures, 1)}
      Regex.match?(@bare_id, trimmed) -> {:ok, trimmed}
      true -> {:error, not_a_deck_url(trimmed)}
    end
  end

  defp not_a_deck_url(url) do
    Error.new(
      :moxfield_not_found,
      "Isso não parece um link de deck do Moxfield.",
      %{url: url}
    )
  end
end
```

- [ ] **Step 5: Write the mapper**

Create `lib/deckex/moxfield/deck_mapper.ex`:

```elixir
defmodule Deckex.Moxfield.DeckMapper do
  @moduledoc """
  Translates a Moxfield deck payload into decklist text, which
  `Deckex.Decks.DecklistParser` then reads — one parser for both import paths
  rather than two code paths that can drift apart.

  > **Unverified against a live response.** The endpoint returns 403 to an
  > unapproved client (see `Deckex.Moxfield`), so this mapping is written
  > against the community-documented shape and pinned by a hand-written
  > fixture. The day a User-Agent is approved, capture a real response and
  > check this module against it before trusting a URL import.
  """

  alias Deckex.Error

  @boards %{"commanders" => "Commander", "mainboard" => "Deck", "maybeboard" => "Maybeboard"}

  @spec to_decklist(map()) :: {:ok, %{name: String.t(), decklist: String.t()}} | {:error, Error.t()}
  def to_decklist(%{"boards" => boards} = payload) when is_map(boards) do
    decklist =
      @boards
      |> Enum.map(fn {key, header} -> section(boards[key], header) end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    {:ok, %{name: payload["name"] || "Deck sem nome", decklist: decklist}}
  end

  def to_decklist(_payload) do
    {:error,
     Error.new(
       :moxfield_not_found,
       "A resposta do Moxfield não tinha as cartas do deck.",
       %{}
     )}
  end

  defp section(%{"cards" => cards}, header) when is_map(cards) and map_size(cards) > 0 do
    lines =
      cards
      |> Map.values()
      |> Enum.map(&line/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    if lines == [], do: "", else: Enum.join([header | lines], "\n") <> "\n"
  end

  defp section(_board, _header), do: ""

  defp line(%{"quantity" => quantity, "card" => %{"name" => name}}), do: "#{quantity} #{name}"
  defp line(_card), do: nil
end
```

- [ ] **Step 6: Write the HTTP adapter**

Create `lib/deckex/moxfield/http.ex`:

```elixir
defmodule Deckex.Moxfield.Http do
  @moduledoc """
  Moxfield adapter over `Req`.

  One request per call, an identifiable and configurable User-Agent, and no
  retry — see `Deckex.Moxfield` for why this client is deliberately naive about
  being blocked. Every failure maps to a domain error whose message points the
  user at the paste path, because that is the path that always works.
  """
  @behaviour Deckex.Moxfield.Client

  alias Deckex.Error
  alias Deckex.Moxfield.DeckMapper

  @endpoint "https://api2.moxfield.com/v3/decks/all"
  @default_user_agent "deckex/0.1 (personal deck analysis tool)"
  @paste_hint "Você pode colar a lista exportada aqui do lado."

  @impl Deckex.Moxfield.Client
  def fetch_deck(public_id) when is_binary(public_id) do
    case Req.get(request(public_id)) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        DeckMapper.to_decklist(body)

      {:ok, %Req.Response{status: 200}} ->
        {:error, blocked("O Moxfield respondeu algo que não é um deck.", %{status: 200})}

      {:ok, %Req.Response{status: 401}} ->
        {:error,
         Error.new(:moxfield_private, "Esse deck é privado. #{@paste_hint}", %{status: 401})}

      {:ok, %Req.Response{status: 404}} ->
        {:error, Error.new(:moxfield_not_found, "Não achei esse deck no Moxfield.", %{status: 404})}

      {:ok, %Req.Response{status: status}} ->
        {:error, blocked("O Moxfield bloqueou a busca (#{status}). #{@paste_hint}", %{status: status})}

      {:error, reason} ->
        {:error, blocked("Não consegui falar com o Moxfield. #{@paste_hint}", %{reason: inspect(reason)})}
    end
  end

  defp blocked(message, details), do: Error.new(:moxfield_blocked, message, details)

  defp request(public_id) do
    [
      url: "#{@endpoint}/#{public_id}",
      headers: [{"user-agent", user_agent()}, {"accept", "application/json"}],
      receive_timeout: 15_000,
      retry: false
    ]
    |> Keyword.merge(config(:req_options, []))
    |> Req.new()
  end

  @doc """
  The User-Agent sent to Moxfield. Configurable so an approved one can be
  dropped in without a code change.
  """
  @spec user_agent() :: String.t()
  def user_agent, do: config(:user_agent, @default_user_agent)

  defp config(key, default) do
    :deckex |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
```

- [ ] **Step 7: Wire the adapter, the mock and the test config**

In `config/config.exs`, next to the other port lines:

```elixir
config :deckex, Deckex.Moxfield.Client, adapter: Deckex.Moxfield.Http
```

In `config/test.exs`, next to the other mock lines:

```elixir
config :deckex, Deckex.Moxfield.Client, adapter: Deckex.Moxfield.Mock

config :deckex, Deckex.Moxfield.Http,
  req_options: [plug: {Req.Test, Deckex.Moxfield.Http}],
  user_agent: "deckex-test-agent"
```

In `test/support/mocks.ex`, add:

```elixir
Mox.defmock(Deckex.Moxfield.Mock, for: Deckex.Moxfield.Client)
```

- [ ] **Step 8: Run the tests, gate and commit**

Run: `mix test test/deckex/moxfield/`
Expected: PASS — 13 tests.

```bash
mix lint && git add -A && git commit -m "feat: add the Moxfield port, degrading to paste

The 403 mapping is verified against the live endpoint; the JSON mapping is not
and says so in its moduledoc. No detection evasion."
```

---

### Task 5: Import from a URL, and the worker

**Files:**
- Create: `lib/deckex/events.ex`
- Create: `lib/deckex/workers/import_deck_worker.ex`
- Modify: `lib/deckex/decks.ex`
- Test: `test/deckex/decks/import_from_url_test.exs`

**Interfaces:**
- Consumes: `Moxfield.fetch_deck/1`, `Moxfield.public_id_from_url/1` (Task 4),
  `Decks.import_from_text/2` (Task 3).
- Produces:
  - `Deckex.Decks.import_from_url(url :: String.t()) :: {:ok, %Deck{}} | {:error, %Deckex.Error{}}`
  - `Deckex.Events.subscribe_deck(deck_id :: String.t()) :: :ok`
  - `Deckex.Events.broadcast_deck_updated(%Deck{}) :: :ok`
  - `Deckex.Workers.ImportDeckWorker.enqueue(url :: String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}`

- [ ] **Step 1: Write the failing test**

Create `test/deckex/decks/import_from_url_test.exs`:

```elixir
defmodule Deckex.Decks.ImportFromUrlTest do
  use Deckex.DataCase, async: true

  import Mox

  alias Deckex.Cards.Card
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.Decks
  alias Deckex.Error
  alias Deckex.ScryfallFixture
  alias Deckex.Workers.ImportDeckWorker

  setup :verify_on_exit!

  defp seed_catalogue(names) do
    for name <- names do
      attrs = name |> ScryfallFixture.load!() |> ScryfallMapper.to_attrs()

      %Card{} |> Card.changeset(attrs) |> Repo.insert!()
    end
  end

  describe "import_from_url/1" do
    test "fetches the deck and imports it" do
      seed_catalogue(["sol_ring"])

      expect(Deckex.Moxfield.Mock, :fetch_deck, fn "kq9g4t81" ->
        {:ok, %{name: "Iroh das Lontra", decklist: "1 Sol Ring"}}
      end)

      assert {:ok, deck} = Decks.import_from_url("https://moxfield.com/decks/kq9g4t81")

      assert deck.name == "Iroh das Lontra"
      assert deck.source == :moxfield
      assert deck.moxfield_public_id == "kq9g4t81"
      assert deck.moxfield_url == "https://moxfield.com/decks/kq9g4t81"
      assert deck.last_synced_at != nil
    end

    test "surfaces a Cloudflare block so the UI can offer the paste form" do
      expect(Deckex.Moxfield.Mock, :fetch_deck, fn _id ->
        {:error, Error.new(:moxfield_blocked, "O Moxfield bloqueou a busca. Cola a lista aqui.")}
      end)

      assert {:error, %Error{code: :moxfield_blocked}} =
               Decks.import_from_url("https://moxfield.com/decks/kq9g4t81")
    end

    test "rejects a URL that is not a Moxfield deck without calling out" do
      # verify_on_exit! fails the test if the port is called.
      assert {:error, %Error{code: :moxfield_not_found}} =
               Decks.import_from_url("https://example.com/oi")
    end
  end

  describe "ImportDeckWorker" do
    test "imports the deck at the given URL" do
      seed_catalogue(["sol_ring"])

      expect(Deckex.Moxfield.Mock, :fetch_deck, fn _id ->
        {:ok, %{name: "Do worker", decklist: "1 Sol Ring"}}
      end)

      assert :ok = perform_job(ImportDeckWorker, %{url: "https://moxfield.com/decks/abc123"})
      assert [%{name: "Do worker"}] = Decks.list_decks()
    end

    test "cancels rather than retrying when Moxfield blocks" do
      expect(Deckex.Moxfield.Mock, :fetch_deck, fn _id ->
        {:error, Error.new(:moxfield_blocked, "bloqueado")}
      end)

      assert {:cancel, _reason} =
               perform_job(ImportDeckWorker, %{url: "https://moxfield.com/decks/abc123"})
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/deckex/decks/import_from_url_test.exs`
Expected: FAIL — `function Deckex.Decks.import_from_url/1 is undefined`.

- [ ] **Step 3: Write the events module**

Create `lib/deckex/events.ex`:

```elixir
defmodule Deckex.Events do
  @moduledoc """
  PubSub topics and payloads, in one place.

  Import is a multi-stage pipeline, so the deck screen renders each stage as it
  lands rather than blocking on a spinner. Changing a payload starts here.
  """

  alias Deckex.Decks.Deck

  @pubsub Deckex.PubSub

  @typedoc "Broadcast when any part of a deck changes."
  @type deck_updated :: {:deck_updated, deck_id :: String.t()}

  @doc "Subscribes the calling process to one deck's updates."
  @spec subscribe_deck(String.t()) :: :ok | {:error, term()}
  def subscribe_deck(deck_id), do: Phoenix.PubSub.subscribe(@pubsub, deck_topic(deck_id))

  @doc "Announces that a deck changed."
  @spec broadcast_deck_updated(Deck.t()) :: :ok
  def broadcast_deck_updated(%Deck{id: deck_id}) do
    Phoenix.PubSub.broadcast(@pubsub, deck_topic(deck_id), {:deck_updated, deck_id})
  end

  defp deck_topic(deck_id), do: "deck:#{deck_id}"
end
```

- [ ] **Step 4: Add `import_from_url/1` to the context**

In `lib/deckex/decks.ex`, add `alias Deckex.Moxfield` and:

```elixir
  @doc """
  Imports a deck from a Moxfield URL.

  Every failure here is expected to be common — Moxfield blocks unapproved
  clients — so the error carries a message the UI shows next to the paste form
  rather than a stack trace.
  """
  @spec import_from_url(String.t()) :: {:ok, Deck.t()} | {:error, Error.t()}
  def import_from_url(url) do
    with {:ok, public_id} <- Moxfield.public_id_from_url(url),
         {:ok, %{name: name, decklist: decklist}} <- Moxfield.fetch_deck(public_id) do
      import_from_text(decklist, %{
        name: name,
        source: :moxfield,
        moxfield_url: url,
        moxfield_public_id: public_id,
        last_synced_at: DateTime.utc_now(:second)
      })
    end
  end
```

Also broadcast on status change: in `update_status!/2`, replace the body with

```elixir
  defp update_status!(deck, status) do
    updated = deck |> Deck.changeset(%{status: status}) |> Repo.update!()

    Events.broadcast_deck_updated(updated)

    updated
  end
```

and add `alias Deckex.Events`.

- [ ] **Step 5: Write the worker**

Create `lib/deckex/workers/import_deck_worker.ex`:

```elixir
defmodule Deckex.Workers.ImportDeckWorker do
  @moduledoc """
  Imports a deck from a Moxfield URL off the request path.

  A block, a private deck or a bad URL are permanent conditions — retrying
  cannot fix them, and the user has a working alternative in the paste form — so
  they cancel. Only a transient failure retries.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Deckex.Decks

  @permanent [:moxfield_blocked, :moxfield_private, :moxfield_not_found, :empty_decklist]

  @doc "Enqueues an import for the given Moxfield URL."
  @spec enqueue(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(url) when is_binary(url) do
    %{url: url} |> new() |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"url" => url}}) do
    case Decks.import_from_url(url) do
      {:ok, _deck} -> :ok
      {:error, %{code: code} = error} when code in @permanent -> {:cancel, error.message}
      {:error, error} -> {:error, error}
    end
  end
end
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `mix test test/deckex/decks/import_from_url_test.exs`
Expected: PASS — 5 tests.

- [ ] **Step 7: Run the gate and commit**

```bash
mix lint && git add -A && git commit -m "feat: import a deck from a Moxfield URL

A block, a private deck or a bad URL cancel rather than retry -- retrying
cannot fix them and the user has the paste form."
```

---

### Task 6: End-to-end regression on the real deck

**Files:**
- Test: `test/deckex/decks/import_regression_test.exs`

**Interfaces:**
- Consumes: everything above.
- Produces: no code.

- [ ] **Step 1: Write the regression test**

Create `test/deckex/decks/import_regression_test.exs`:

```elixir
defmodule Deckex.Decks.ImportRegressionTest do
  @moduledoc """
  Imports a real 100-card Commander export end to end, with every card already
  in the catalogue, and locks in the counts. If the parser, the resolver or the
  persistence layer drifts, this test says so.
  """
  use Deckex.DataCase, async: true

  import Mox

  alias Deckex.Cards
  alias Deckex.Cards.Card
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.Decks
  alias Deckex.ScryfallFixture

  setup :verify_on_exit!

  @decklist "test/support/fixtures/decklists/iroh_das_lontra.txt"

  # The catalogue holds only the cards we have fixtures for; the rest come back
  # from the (mocked) port as not_found, which the import records instead of
  # failing on.
  defp seed_catalogue do
    for name <- ~w(sol_ring cultivate command_tower counterspell forest) do
      attrs = name |> ScryfallFixture.load!() |> ScryfallMapper.to_attrs()

      %Card{} |> Card.changeset(attrs) |> Repo.insert!()
    end
  end

  test "imports the deck, keeping quantities, boards and unresolved names" do
    seed_catalogue()

    expect(Deckex.Scryfall.Mock, :fetch_by_names, fn names ->
      # Everything not seeded is reported unresolved rather than invented.
      {:ok, %{found: [], not_found: names}}
    end)

    text = File.read!(@decklist)

    assert {:ok, deck} = Decks.import_from_text(text, %{name: "Iroh das Lontra", source: :paste})

    cards = Decks.list_deck_cards(deck)
    by_name = Map.new(cards, &{&1.card.name, &1})

    # Iroh is not in the seeded catalogue, so the commander line resolves to
    # nothing and no card lands on the commander board. That is the point of
    # the last_error assertion below: the card is reported, not swallowed.
    assert Enum.count(cards, &(&1.board == :commander)) == 0
    assert deck.color_identity == []

    # Quantities survive: the decklist has 4 Forest.
    assert %{quantity: 4, board: :main} = by_name["Forest"]
    assert %{quantity: 1, board: :main} = by_name["Sol Ring"]

    # Unresolved names are recorded, not swallowed.
    assert deck.last_error =~ "Iroh, Grand Lotus"

    # The raw text is kept for a future re-import.
    assert deck.raw_decklist == text
  end

  test "the seeded cards come out classified by the rules" do
    seed_catalogue()

    expect(Deckex.Scryfall.Mock, :fetch_by_names, fn names ->
      {:ok, %{found: [], not_found: names}}
    end)

    {:ok, _deck} =
      Decks.import_from_text(File.read!(@decklist), %{name: "Iroh", source: :paste})

    sol_ring = Cards.get_by_name("Sol Ring")

    assert [%{kind: :ramp, source: :rule}] = Cards.roles_for(sol_ring)
  end
end
```

- [ ] **Step 2: Run it**

Run: `mix test test/deckex/decks/import_regression_test.exs`
Expected: PASS — 2 tests.

- [ ] **Step 3: Run the full suite and the gate, then commit**

```bash
mix test && mix lint && git add -A && git commit -m "test: lock in end-to-end import of a real decklist"
```

---

## What this plan delivers

```elixir
{:ok, deck} = Deckex.Decks.import_from_text(pasted_text, %{name: "Iroh", source: :paste})

Deckex.Decks.list_deck_cards(deck)
# => every card, with quantity, board, and its classified roles
```

A deck the analysis lenses can read. URL import is wired and will start working
the day Moxfield approves a User-Agent; until then it fails with a message that
points at the paste form.

## Next plans

| Plan | Spec milestone | Delivers |
|---|---|---|
| 4 | 5 | `Deckex.Analysis` — the four lenses and the findings catalogue |
| 5 | 6 | `Deckex.Consults` — briefings, per-lens schemas, AI diagnosis |
| 6 | 7 | The UI: design tokens, then Mesa → Deck → Lente → Consultas → Ajustes |
