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
  alias Deckex.Cards.Card
  alias Deckex.Cards.Name
  alias Deckex.Decks.Deck
  alias Deckex.Decks.DeckCard
  alias Deckex.Decks.DecklistParser
  alias Deckex.Decks.DeckQuery
  alias Deckex.Error
  alias Deckex.Events
  alias Deckex.Moxfield
  alias Deckex.Optimizations
  alias Deckex.Repo
  alias Deckex.Workers.ClassifyCardsWorker

  defdelegate list_decks(), to: DeckQuery
  defdelegate get_deck(id), to: DeckQuery
  defdelegate fetch_deck(id), to: DeckQuery
  defdelegate list_deck_cards(deck), to: DeckQuery

  @doc """
  Deletes a deck and everything that belongs only to it.

  The foreign keys cascade, so the cards in the list, every consult asked about
  this deck and every optimization run over it go with it. That is the right
  behaviour and also the reason `Deckex.Decks.deletion_cost/1` exists: those
  consults were paid for, and an owner deleting a deck should be told what else
  is about to go rather than discovering it afterwards.

  A deck with a run still in flight is refused. The run's jobs would keep
  executing against rows that no longer exist, and "it crashed in the
  background" is a worse answer than "cancel it first".

  The catalogue is untouched: cards are global and permanent, and `deck_cards`
  restricts deletion of a card rather than cascading to it.
  """
  @spec delete_deck(Deck.t()) :: {:ok, Deck.t()} | {:error, Error.t()}
  def delete_deck(%Deck{} = deck) do
    if Optimizations.running_for_deck(deck.id) do
      {:error,
       Error.new(
         :optimization_running,
         "Esse deck tem uma otimização em andamento. Cancele ela antes de apagar o deck.",
         %{deck_id: deck.id}
       )}
    else
      {:ok, deleted} = Repo.delete(deck)

      Events.broadcast_deck_updated(deleted)

      {:ok, deleted}
    end
  end

  @doc """
  What else disappears with this deck: how many consults and runs hang off it.

  The number the confirmation dialog says out loud. A consult cost money and a
  finished run is a record of a decision — deleting them silently as a side
  effect of tidying up the deck list is the kind of thing an app only gets to
  do to someone once.
  """
  @spec deletion_cost(Deck.t()) :: %{
          consults: non_neg_integer(),
          optimizations: non_neg_integer()
        }
  def deletion_cost(%Deck{} = deck) do
    %{
      consults: DeckQuery.count_consults(deck.id),
      optimizations: DeckQuery.count_optimizations(deck.id)
    }
  end

  @doc """
  Renames a deck.

  A name is the one thing about a deck that is purely the owner's, and until
  now it was whatever the import happened to produce — "Frodo and sam food
  chaos 1.0" is a Moxfield title, not a decision.

  Blank is refused rather than stored: a deck with no name is unfindable on a
  screen whose whole job is telling decks apart.
  """
  @spec rename(Deck.t(), String.t()) :: {:ok, Deck.t()} | {:error, Error.t()}
  def rename(%Deck{} = deck, name) do
    case String.trim(to_string(name)) do
      "" ->
        {:error, Error.new(:invalid_deck_name, "O deck precisa de um nome.", %{deck_id: deck.id})}

      trimmed ->
        renamed = deck |> Deck.changeset(%{name: trimmed}) |> Repo.update!()

        Events.broadcast_deck_updated(renamed)

        {:ok, renamed}
    end
  end

  @doc """
  Copies a deck into a new one, list and all.

  Built from the deck's **current** cards, never from `raw_decklist`: that
  field is the text the import arrived with, and every cut and add made since
  would be silently undone by copying it. A duplicate that quietly differs from
  what is on screen is worse than no duplicate at all.

  Goes through `import_from_text/2` like everything else, so the copy resolves,
  classifies and analyses by exactly the same path — no second way for a deck
  to come into existence.
  """
  @spec duplicate(Deck.t()) :: {:ok, Deck.t()} | {:error, Error.t()}
  def duplicate(%Deck{} = deck) do
    with {:ok, copy} <-
           import_from_text(to_decklist_text(deck), %{
             name: "#{deck.name} — cópia",
             source: :paste
           }) do
      {:ok, carry_over(copy, deck)}
    end
  end

  # The dossier is the one thing on a deck that cost money: a scout consult
  # wrote it. A copy of a list is a copy of the deck the dossier describes, so
  # throwing it away would charge the owner again for a reading he already
  # bought — and silently, at that.
  #
  # `dossier_stale` rides along rather than resetting: the copy holds the same
  # cards, so the reading is exactly as current as it was a moment ago. Marking
  # a fresh copy stale would be a lie in the safe direction, which is still a
  # lie the owner pays a consult to clear.
  defp carry_over(copy, original) do
    copy
    |> Deck.changeset(%{
      dossier: original.dossier,
      dossier_source: original.dossier_source,
      dossier_stale: original.dossier_stale,
      dossier_updated_at: original.dossier_updated_at,
      notes: original.notes
    })
    |> Repo.update!()
  end

  @doc """
  A deck's current cards as decklist text, commanders in their own block.

  The format `import_from_text/2` reads, so a deck can always round-trip
  through the only door the app has.
  """
  @spec to_decklist_text(Deck.t()) :: String.t()
  def to_decklist_text(%Deck{} = deck) do
    {commanders, main} =
      deck |> DeckQuery.list_deck_cards() |> Enum.split_with(&(&1.board == :commander))

    decklist_text(
      Enum.map(commanders, & &1.card.name),
      Enum.map(main, &{&1.quantity, &1.card.name})
    )
  end

  @doc """
  A decklist as text, in the format `import_from_text/2` reads back.

  **The `Deck:` header is not decoration.** `Deckex.Decks.DecklistParser` walks
  the lines carrying the board it is currently in, and a `Commander:` header
  switches it — nothing switches it back but another header or a rule of
  dashes. A list written with a commander block and no `Deck:` header imports
  as a hundred commanders, which is exactly what "Salvar como novo deck" did
  until this function existed in one place instead of two.

  One formatter, so a fix to the format cannot land in one caller and miss the
  other.
  """
  @spec decklist_text([String.t()], [{pos_integer(), String.t()}]) :: String.t()
  def decklist_text(commander_names, rows) do
    commander_block =
      case commander_names do
        [] -> ""
        names -> "Commander:\n" <> Enum.map_join(names, "\n", &"1 #{&1}") <> "\n\n"
      end

    commander_block <>
      "Deck:\n" <>
      Enum.map_join(rows, "\n", fn {quantity, name} -> "#{quantity} #{name}" end) <>
      "\n"
  end

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

  @doc """
  Adds a card to the deck by name, resolving it through the catalogue first.

  Writes the same `deck_cards` row the import writes, so the next report picks
  the change up with no special case.

  Refuses a second copy of a singleton card. A model asked for two Forests will
  get two — that is legal — but a model asking twice for the same spell would
  otherwise build an illegal decklist one click at a time.
  """
  @spec add_card(Deck.t(), String.t(), keyword()) :: {:ok, DeckCard.t()} | {:error, Error.t()}
  def add_card(%Deck{} = deck, name, opts \\ []) do
    board = Keyword.get(opts, :board, :main)
    quantity = Keyword.get(opts, :quantity, 1)

    with {:ok, card} <- resolve_one(name),
         :ok <- check_singleton(deck, card, board) do
      # Classify on the way in. A card added without roles is invisible to every
      # lens — the interaction count would not move when you add a counterspell,
      # which is precisely the feedback the button exists to give.
      {:ok, _roles} = Cards.classify_card(card)
      :ok = mark_dossier_stale(deck)

      {:ok, upsert_deck_card!(deck, card, board, quantity)}
    end
  end

  # Commander is singleton apart from basic lands and the handful of cards whose
  # own text lifts the rule. Both exceptions are *in the card data*, so this asks
  # the card rather than carrying a list of card names — the same reason the rest
  # of the engine reads oracle text instead of hardcoding what is good.
  defp check_singleton(deck, card, board) do
    cond do
      Card.basic_land?(card) or Card.any_number_allowed?(card) -> :ok
      is_nil(DeckQuery.get_deck_card(deck, card.id, board)) -> :ok
      true -> {:error, already_singleton(card)}
    end
  end

  defp already_singleton(card) do
    Error.new(
      :not_commander_legal,
      "#{card.name} já está no deck, e Commander só aceita uma cópia.",
      %{card: card.name}
    )
  end

  @doc "Removes one copy of a card, deleting the row when the last copy goes."
  @spec remove_card(Deck.t(), String.t()) :: {:ok, :removed} | {:error, Error.t()}
  def remove_card(%Deck{} = deck, name) do
    with {:ok, card} <- resolve_one(name),
         %DeckCard{} = deck_card <- find_any_board(deck, card) do
      drop_one!(deck_card)
      :ok = mark_dossier_stale(deck)

      {:ok, :removed}
    else
      nil -> {:error, not_in_deck(name)}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Stores the scout's reading of the deck.

  Cannot fail for an expected reason — the map comes from a schema-validated
  model answer — so the tagged shape is uniformity, not an error channel.
  """
  @spec put_dossier(Deck.t(), map()) :: {:ok, Deck.t()}
  def put_dossier(%Deck{} = deck, %{} = dossier) do
    {:ok, write_dossier!(deck, dossier, :scout)}
  end

  @doc """
  The owner's edit of the dossier.

  Also clears staleness: an edit asserts current truth, which is exactly what
  the stale flag says is missing.
  """
  @spec edit_dossier(Deck.t(), map()) :: {:ok, Deck.t()}
  def edit_dossier(%Deck{} = deck, %{} = dossier) do
    {:ok, write_dossier!(deck, Map.take(dossier, dossier_fields()), :manual)}
  end

  @doc "The four prose fields a dossier carries, in display order."
  @spec dossier_fields() :: [String.t()]
  def dossier_fields, do: ["plano", "sinergias", "linhas_de_vitoria", "fraquezas"]

  defp write_dossier!(deck, dossier, source) do
    deck
    |> Deck.changeset(%{
      dossier: dossier,
      dossier_source: source,
      dossier_stale: false,
      dossier_updated_at: DateTime.utc_now(:second)
    })
    |> Repo.update!()
  end

  # An edit changes what the dossier describes. Flag it; never re-run anything
  # automatically — a consult costs money and minutes, so spending is always
  # the owner's click.
  defp mark_dossier_stale(%Deck{dossier: nil}), do: :ok

  defp mark_dossier_stale(%Deck{} = deck) do
    deck |> Deck.changeset(%{dossier_stale: true}) |> Repo.update!()

    :ok
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
