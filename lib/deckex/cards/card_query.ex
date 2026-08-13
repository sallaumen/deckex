defmodule Deckex.Cards.CardQuery do
  @moduledoc """
  All reads of the card catalogue. Query logic lives here rather than in the
  context or an edge, so it is discoverable, reusable and unit-testable. Every
  function ends in a `Repo` call and returns data, never an `Ecto.Query`.
  """

  import Ecto.Query

  alias Deckex.Cards.Card
  alias Deckex.Cards.CardRole
  alias Deckex.Cards.Name
  alias Deckex.Repo

  @doc "Lists the cards whose normalized names are in `names`."
  @spec list_by_normalized_names([String.t()]) :: [Card.t()]
  def list_by_normalized_names([]), do: []

  def list_by_normalized_names(names) when is_list(names) do
    Repo.all(from c in Card, where: c.name_normalized in ^names)
  end

  @doc "Fetches one card by any spelling of its name."
  @spec get_by_name(String.t()) :: Card.t() | nil
  def get_by_name(name) when is_binary(name) do
    Repo.get_by(Card, name_normalized: Name.normalize(name))
  end

  @doc "Lists cards by id, in no particular order."
  @spec list_by_ids([String.t()]) :: [Card.t()]
  def list_by_ids([]), do: []

  def list_by_ids(ids) when is_list(ids) do
    Repo.all(from c in Card, where: c.id in ^ids)
  end

  @doc "Lists the persisted roles for a card, ordered by kind."
  @spec list_roles(Card.t()) :: [CardRole.t()]
  def list_roles(%Card{id: card_id}) do
    Repo.all(from r in CardRole, where: r.card_id == ^card_id, order_by: r.kind)
  end

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
end
