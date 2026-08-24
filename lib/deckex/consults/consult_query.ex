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

  @doc """
  The newest consult of one lens on one deck, or nil.

  A screen that asked a question once should still be showing the answer after
  a reload — an answer that cost money and vanishes on F5 is an answer the
  owner pays for twice.
  """
  @spec latest_for_lens(String.t(), atom()) :: Consult.t() | nil
  def latest_for_lens(deck_id, lens) do
    Repo.one(
      from c in Consult,
        where: c.deck_id == ^deck_id and c.lens == ^lens,
        order_by: [desc: c.inserted_at],
        limit: 1
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

  @doc """
  Every consult that has an answer, newest first — pipeline runs included.

  A card lost to a Scryfall outage is lost the same way whether the owner asked
  the question or the pipeline did, so the sweep that finds them reads both.
  """
  @spec list_answered() :: [Consult.t()]
  def list_answered do
    Repo.all(from c in Consult, where: not is_nil(c.response), order_by: [desc: c.inserted_at])
  end

  @doc """
  One optimization's consults for a lens, oldest first.

  A stage may run more than once — asking for other visions is the case that
  needs this — and `step.consult_id` only points at the latest. The declined
  answers stay attached to the run and are read through here.
  """
  @spec list_for_optimization(String.t(), atom()) :: [Consult.t()]
  def list_for_optimization(optimization_id, lens) do
    Repo.all(
      from c in Consult,
        where: c.optimization_id == ^optimization_id and c.lens == ^lens,
        order_by: [asc: c.inserted_at]
    )
  end

  @doc "Every consult a run produced, oldest first — including redone ones."
  @spec list_all_for_optimization(String.t()) :: [Consult.t()]
  def list_all_for_optimization(optimization_id) do
    Repo.all(
      from c in Consult,
        where: c.optimization_id == ^optimization_id,
        order_by: [asc: c.inserted_at]
    )
  end
end
