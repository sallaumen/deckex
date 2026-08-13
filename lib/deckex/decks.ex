defmodule Deckex.Decks do
  @moduledoc """
  The user's decks: importing them, reading them, retiring them.

  The import order is dictated by playbook rule 4 — **no external call inside an
  open transaction**. Scryfall is reached while resolving names, *before* the
  transaction opens; classification runs after it commits. The transaction
  itself only writes rows.
  """

  alias Deckex.Analysis.CardEntry
  alias Deckex.Analysis.DeckSnapshot
  alias Deckex.Cards
  alias Deckex.Cards.Name
  alias Deckex.Decks.Deck
  alias Deckex.Decks.DeckCard
  alias Deckex.Decks.DecklistParser
  alias Deckex.Decks.DeckQuery
  alias Deckex.Error
  alias Deckex.Events
  alias Deckex.Moxfield
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
      {:ok, classify(deck, cards)}
    end
  end

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
      CardEntry.new(deck_card.card, deck_card.quantity, Map.get(roles, deck_card.card_id, []))
    end)
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
      with {:ok, deck} <- insert_deck(text, attrs, not_found) do
        insert_deck_cards(deck, rows)

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

  # Classification happens outside the transaction. The rule pass is free and
  # instant so it runs inline; only the residue costs an AI call, and that goes
  # to a worker so the import returns immediately.
  defp classify(deck, cards) do
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
    updated = deck |> Deck.changeset(%{status: status}) |> Repo.update!()

    Events.broadcast_deck_updated(updated)

    updated
  end
end
