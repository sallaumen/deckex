defmodule Deckex.Consults.ConsultQuery do
  @moduledoc "All reads of consults."

  import Ecto.Query

  alias Deckex.Consults.Consult
  alias Deckex.Decks.Deck
  alias Deckex.Error
  alias Deckex.Repo

  @doc """
  A deck's consults, newest first — the ones the OWNER asked, only.

  Pipeline consults are tagged with `optimization_id` and belong to their
  run's timeline; showing them here would bury the deck page under a
  nine-stage run (the spec's "não misturar tudo nessa página principal").
  """
  @spec list_for_deck(Deck.t()) :: [Consult.t()]
  def list_for_deck(%Deck{id: deck_id}) do
    Repo.all(
      from c in Consult,
        where: c.deck_id == ^deck_id and is_nil(c.optimization_id),
        order_by: [desc: c.inserted_at]
    )
  end

  @doc "Fetches a consult by id as a tagged tuple."
  @spec fetch(String.t()) :: {:ok, Consult.t()} | {:error, Error.t()}
  def fetch(id) do
    case Repo.get(Consult, id) do
      nil -> {:error, Error.new(:consult_not_found, "Não achei essa consulta.", %{id: id})}
      consult -> {:ok, consult}
    end
  end
end
