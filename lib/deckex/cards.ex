defmodule Deckex.Cards do
  @moduledoc """
  The card catalogue: the local, permanent cache of Scryfall card data.

  `resolve_names/1` is the entry point every import uses. Cards already known
  are read from Postgres; only genuinely new ones cost a Scryfall request. Since
  a card is immutable and the catalogue is global, the cost of importing decks
  falls towards zero as the collection grows.
  """

  alias Deckex.Cards.Card
  alias Deckex.Cards.CardQuery
  alias Deckex.Cards.Name
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.Error
  alias Deckex.Repo
  alias Deckex.Scryfall

  defdelegate get_by_name(name), to: CardQuery
  defdelegate list_by_normalized_names(names), to: CardQuery

  @doc """
  Resolves card names to `Card` structs, fetching and caching whatever is
  missing.

  Returns the resolved cards plus the names Scryfall could not resolve — those
  are reported to the user by name, never silently dropped.
  """
  @spec resolve_names([String.t()]) ::
          {:ok, %{cards: [Card.t()], not_found: [String.t()]}} | {:error, Error.t()}
  def resolve_names([]), do: {:ok, %{cards: [], not_found: []}}

  def resolve_names(names) when is_list(names) do
    # Deduplicate on the normalized key, but keep one original spelling per key
    # — Scryfall is queried with a real name, not our lookup key.
    wanted = Enum.uniq_by(names, &Name.normalize/1)
    known = CardQuery.list_by_normalized_names(Enum.map(wanted, &Name.normalize/1))
    known_keys = MapSet.new(known, & &1.name_normalized)

    missing = Enum.reject(wanted, &MapSet.member?(known_keys, Name.normalize(&1)))

    with {:ok, %{found: found, not_found: not_found}} <- fetch_missing(missing),
         {:ok, inserted} <- insert_all(found) do
      {:ok, %{cards: known ++ inserted, not_found: not_found}}
    end
  end

  defp fetch_missing([]), do: {:ok, %{found: [], not_found: []}}
  defp fetch_missing(names), do: Scryfall.fetch_by_names(names)

  defp insert_all(scryfall_cards) do
    scryfall_cards
    |> Enum.reduce_while({:ok, []}, fn scryfall_card, {:ok, acc} ->
      case insert_card(scryfall_card) do
        {:ok, card} -> {:cont, {:ok, [card | acc]}}
        {:error, changeset} -> {:halt, invalid_card_error(scryfall_card, changeset)}
      end
    end)
    |> case do
      {:ok, cards} -> {:ok, Enum.reverse(cards)}
      {:error, _reason} = error -> error
    end
  end

  defp insert_card(scryfall_card) do
    attrs = ScryfallMapper.to_attrs(scryfall_card)

    %Card{}
    |> Card.changeset(attrs)
    # Upsert rather than plain insert, for two reasons. A concurrent import may
    # have inserted this card between our read and this write, and re-fetching a
    # card we already hold is the natural moment to refresh the advisory price
    # and the EDHREC rank — the only fields that legitimately change.
    #
    # Note `on_conflict: :nothing` would NOT work here: UUID primary keys are
    # generated client-side, so a skipped insert still returns a struct carrying
    # an id that was never written, and the caller would hold a phantom card.
    |> Repo.insert(
      on_conflict: {:replace, [:price_usd, :prices_updated_at, :edhrec_rank, :updated_at]},
      conflict_target: :oracle_id,
      returning: true
    )
  end

  defp invalid_card_error(scryfall_card, changeset) do
    {:error,
     Error.new(
       :cards_not_found,
       "A Scryfall devolveu uma carta que não consegui gravar.",
       %{name: scryfall_card["name"], errors: inspect(changeset.errors)}
     )}
  end
end
