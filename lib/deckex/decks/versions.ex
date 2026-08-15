defmodule Deckex.Decks.Versions do
  @moduledoc """
  A deck's line of versions: marking one, going back to one, comparing two.

  Three operations, and each one is smaller than it sounds because a version is
  a photograph rather than a branch.

  **Marking** copies the working state into a numbered row. **Restoring**
  writes that row back over `deck_cards` — no Scryfall, because a version only
  exists for cards the catalogue already resolved once. **Comparing** is a diff
  of two lists, which is the question "what do I have to buy to get from here
  to there" with the prices attached.

  Restoring never deletes: going back to v2 from v5 leaves v3, v4 and v5 where
  they are. History is a record of what happened, not a tree to prune — and the
  next version marked after that is v6, because that is also what happened.
  """

  import Ecto.Query

  alias Deckex.Cards
  alias Deckex.Cards.Name
  alias Deckex.Decks.Deck
  alias Deckex.Decks.DeckCard
  alias Deckex.Decks.DeckQuery
  alias Deckex.Decks.DeckVersion
  alias Deckex.Error
  alias Deckex.Events
  alias Deckex.Money
  alias Deckex.Repo

  @doc "Every version of a deck, newest first."
  @spec list(Deck.t()) :: [DeckVersion.t()]
  def list(%Deck{id: deck_id}) do
    Repo.all(from v in DeckVersion, where: v.deck_id == ^deck_id, order_by: [desc: v.number])
  end

  @doc "One version by number, or an error the UI can print."
  @spec fetch(Deck.t(), integer()) :: {:ok, DeckVersion.t()} | {:error, Error.t()}
  def fetch(%Deck{id: deck_id}, number) do
    case Repo.get_by(DeckVersion, deck_id: deck_id, number: number) do
      nil -> {:error, Error.new(:version_not_found, "Não achei a versão v#{number} desse deck.")}
      version -> {:ok, version}
    end
  end

  @doc "The most recent version, or nil for a deck that has never marked one."
  @spec latest(Deck.t()) :: DeckVersion.t() | nil
  def latest(%Deck{id: deck_id}) do
    Repo.one(
      from v in DeckVersion, where: v.deck_id == ^deck_id, order_by: [desc: v.number], limit: 1
    )
  end

  @doc """
  Photographs the deck's working state as the next version.

  `opts` carries `:origin` (defaults to `:manual`), `:label`, `:optimization_id`
  and `:changes` — the changelog of what this version did, which the optimizer
  passes straight from its run and a manual mark computes against the previous
  version.
  """
  @spec mark(Deck.t(), keyword()) :: {:ok, DeckVersion.t()}
  def mark(%Deck{} = deck, opts \\ []) do
    {commanders, rows} = working_state(deck)
    previous = latest(deck)

    changes =
      Keyword.get_lazy(opts, :changes, fn -> %{"applied" => drift(previous, rows)} end)

    version =
      %DeckVersion{}
      |> DeckVersion.changeset(%{
        deck_id: deck.id,
        number: next_number(previous),
        origin: Keyword.get(opts, :origin, :manual),
        label: Keyword.get(opts, :label),
        optimization_id: Keyword.get(opts, :optimization_id),
        list: %{"rows" => rows},
        commanders: commanders,
        changes: changes
      })
      |> Repo.insert!()

    Events.broadcast_deck_updated(deck)

    {:ok, version}
  end

  defp next_number(nil), do: 1
  defp next_number(%DeckVersion{number: number}), do: number + 1

  @doc """
  Whether the working state has moved since the last version was marked.

  So that "I never saved this" is something the screen says rather than
  something the owner discovers.
  """
  @spec drifted?(Deck.t()) :: boolean()
  def drifted?(%Deck{} = deck) do
    case latest(deck) do
      nil ->
        false

      version ->
        {commanders, rows} = working_state(deck)

        commanders != version.commanders or
          normalize(rows) != normalize(DeckVersion.rows(version))
    end
  end

  @doc """
  Writes a version back over the deck's cards.

  No Scryfall: every card in a version was resolved the day it was first
  imported, so this is a read of the catalogue and a rewrite of `deck_cards`,
  in one transaction. A name the catalogue somehow no longer holds is reported
  rather than silently dropped — a restore that quietly loses a card is worse
  than one that refuses.
  """
  @spec restore(Deck.t(), DeckVersion.t()) :: {:ok, Deck.t()} | {:error, Error.t()}
  def restore(%Deck{} = deck, %DeckVersion{} = version) do
    rows = DeckVersion.rows(version)
    names = Enum.map(rows, & &1["name"]) ++ version.commanders

    by_key =
      names
      |> Enum.map(&Name.normalize/1)
      |> Cards.list_by_normalized_names()
      |> Map.new(&{&1.name_normalized, &1})

    case Enum.reject(names, &Map.has_key?(by_key, Name.normalize(&1))) do
      [] -> write_back(deck, rows, version.commanders, by_key)
      missing -> {:error, missing_error(missing)}
    end
  end

  defp write_back(deck, rows, commanders, by_key) do
    {:ok, _result} =
      Repo.transact(fn ->
        Repo.delete_all(from dc in DeckCard, where: dc.deck_id == ^deck.id)

        Enum.each(
          commanders,
          &insert_card!(deck, Map.fetch!(by_key, Name.normalize(&1)), 1, :commander)
        )

        Enum.each(rows, fn row ->
          insert_card!(
            deck,
            Map.fetch!(by_key, Name.normalize(row["name"])),
            row["quantity"],
            :main
          )
        end)

        {:ok, :written}
      end)

    {:ok, restored} = DeckQuery.fetch_deck(deck.id)

    Events.broadcast_deck_updated(restored)

    {:ok, restored}
  end

  defp insert_card!(deck, card, quantity, board) do
    %DeckCard{}
    |> DeckCard.changeset(%{
      deck_id: deck.id,
      card_id: card.id,
      quantity: quantity || 1,
      board: board
    })
    |> Repo.insert!()
  end

  defp missing_error(missing) do
    Error.new(
      :cards_not_found,
      "Não consegui restaurar: #{Enum.join(missing, ", ")} não está mais no catálogo.",
      %{missing: missing}
    )
  end

  @doc """
  What separates two versions, and what closing the gap costs.

  `from` is where you are and `to` is where you want to be, so `buy` is the
  list to take to a shop. Cards leaving cost nothing and are counted
  separately; a card with no known price is listed and left out of the total,
  as everywhere else in this app.
  """
  @spec diff(DeckVersion.t(), DeckVersion.t()) :: %{
          buy: [map()],
          drop: [map()],
          total_usd: Decimal.t(),
          unpriced: non_neg_integer()
        }
  def diff(%DeckVersion{} = from, %DeckVersion{} = to) do
    here = counts(from)
    there = counts(to)

    buy = difference(there, here)
    drop = difference(here, there)

    %{
      buy: buy,
      drop: drop,
      total_usd:
        Enum.reduce(buy, Decimal.new(0), &Decimal.add(&2, &1.price_usd || Decimal.new(0))),
      unpriced: Enum.count(buy, &is_nil(&1.price_usd))
    }
  end

  @doc "The diff as plain text, one line per card, for a shop's bulk box."
  @spec buy_text(map()) :: String.t()
  def buy_text(%{buy: []}), do: ""

  def buy_text(%{buy: buy}) do
    Enum.map_join(buy, "\n", &"#{&1.quantity} #{&1.name}") <> "\n"
  end

  # Commanders count: a version that swapped the commander has to say so, and
  # the new one is a card the owner may well have to buy.
  defp counts(%DeckVersion{} = version) do
    from_rows = Map.new(DeckVersion.rows(version), &{&1["name"], &1["quantity"] || 1})

    Enum.reduce(version.commanders, from_rows, &Map.update(&2, &1, 1, fn n -> n + 1 end))
  end

  defp difference(target, source) do
    target
    |> Enum.flat_map(fn {name, quantity} ->
      case quantity - Map.get(source, name, 0) do
        missing when missing > 0 -> [priced(name, missing)]
        _have_enough -> []
      end
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp priced(name, quantity) do
    card = Cards.get_by_name(name)

    %{
      name: name,
      quantity: quantity,
      card: card,
      price_usd: card && card.price_usd,
      price_brl: card && Money.to_brl(card.price_usd)
    }
  end

  defp working_state(%Deck{} = deck) do
    {commanders, main} =
      deck |> DeckQuery.list_deck_cards() |> Enum.split_with(&(&1.board == :commander))

    rows = Enum.map(main, &%{"name" => &1.card.name, "quantity" => &1.quantity})

    {Enum.map(commanders, & &1.card.name), rows}
  end

  # Order is not a change: two lists holding the same cards in different orders
  # are the same list, and a version marked for a reordering would be noise.
  defp normalize(rows), do: rows |> Enum.map(&{&1["name"], &1["quantity"]}) |> Enum.sort()

  # What the working state did to the last version, as the same shape the
  # optimizer records: one entry per card that entered or left.
  defp drift(nil, _rows), do: []

  defp drift(%DeckVersion{} = previous, rows) do
    here = Map.new(rows, &{&1["name"], &1["quantity"] || 1})
    there = Map.new(DeckVersion.rows(previous), &{&1["name"], &1["quantity"] || 1})

    added =
      for {name, quantity} <- here,
          quantity > Map.get(there, name, 0),
          do: %{"action" => "add", "card" => name, "reason" => "editado à mão"}

    removed =
      for {name, quantity} <- there,
          quantity > Map.get(here, name, 0),
          do: %{"action" => "cut", "card" => name, "reason" => "editado à mão"}

    Enum.sort_by(added ++ removed, & &1["card"])
  end
end
