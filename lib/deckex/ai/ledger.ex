defmodule Deckex.AI.Ledger do
  @moduledoc """
  Every call to the model, and the sums the meters read.

  Three totals, because there are three questions: what has this app cost me
  in all (A Mesa), what has this deck cost me (the deck page), and what did
  this answer cost (the consult, the stage). All three are the same sum over
  the same rows, sliced differently — nothing is stored twice, so no two
  numbers on screen can disagree.
  """

  import Ecto.Query

  alias Deckex.AI.Call
  alias Deckex.AI.Usage
  alias Deckex.Decks.Deck
  alias Deckex.Repo

  @empty %{
    calls: 0,
    input_tokens: 0,
    output_tokens: 0,
    cache_creation_tokens: 0,
    cache_read_tokens: 0,
    total_tokens: 0,
    cost_usd: Decimal.new(0)
  }

  @doc """
  Writes one call to the ledger. Never raises into the caller's path: a lost
  measurement must not cost an answer the owner already paid for.
  """
  @spec record(Usage.t(), keyword()) :: :ok
  def record(%Usage{} = usage, opts) do
    if Usage.measured?(usage) or Keyword.get(opts, :force, false) do
      %Call{} |> Call.changeset(usage, opts) |> Repo.insert!()
    end

    :ok
  rescue
    # A meter is worth exactly nothing next to the answer it measures.
    error ->
      require Logger

      Logger.warning("não consegui registrar o uso da IA: #{inspect(error)}")

      :ok
  end

  @doc "Everything this app has spent on the model."
  @spec totals() :: map()
  def totals, do: sum(Call)

  @doc "What one deck has cost — its consults and its optimizations."
  @spec totals_for_deck(Deck.t() | String.t()) :: map()
  def totals_for_deck(%Deck{id: id}), do: totals_for_deck(id)
  def totals_for_deck(deck_id), do: sum(from c in Call, where: c.deck_id == ^deck_id)

  @doc "What one answer cost."
  @spec totals_for_consult(String.t()) :: map()
  def totals_for_consult(consult_id), do: sum(from c in Call, where: c.consult_id == ^consult_id)

  @doc """
  What each of these consults cost, by consult id.

  One query for a page that lists a dozen answers, rather than a dozen.
  """
  @spec by_consult([String.t()]) :: %{String.t() => map()}
  def by_consult([]), do: %{}

  def by_consult(consult_ids) do
    Repo.all(
      from c in Call,
        where: c.consult_id in ^consult_ids,
        group_by: c.consult_id,
        select: {
          c.consult_id,
          %{
            calls: count(c.id),
            input_tokens: sum(c.input_tokens),
            output_tokens: sum(c.output_tokens),
            cache_creation_tokens: sum(c.cache_creation_tokens),
            cache_read_tokens: sum(c.cache_read_tokens),
            cost_usd: sum(c.cost_usd)
          }
        }
    )
    |> Map.new(fn {id, row} -> {id, complete(row)} end)
  end

  @doc "What every deck has cost, by deck id — one query for A Mesa."
  @spec by_deck() :: %{String.t() => map()}
  def by_deck do
    Repo.all(
      from c in Call,
        where: not is_nil(c.deck_id),
        group_by: c.deck_id,
        select: {
          c.deck_id,
          %{
            calls: count(c.id),
            input_tokens: sum(c.input_tokens),
            output_tokens: sum(c.output_tokens),
            cache_creation_tokens: sum(c.cache_creation_tokens),
            cache_read_tokens: sum(c.cache_read_tokens),
            cost_usd: sum(c.cost_usd)
          }
        }
    )
    |> Map.new(fn {id, row} -> {id, complete(row)} end)
  end

  @doc "An empty total, for a deck or a consult that has never asked anything."
  @spec empty() :: map()
  def empty, do: @empty

  defp sum(query) do
    Repo.one(
      from c in query,
        select: %{
          calls: count(c.id),
          input_tokens: sum(c.input_tokens),
          output_tokens: sum(c.output_tokens),
          cache_creation_tokens: sum(c.cache_creation_tokens),
          cache_read_tokens: sum(c.cache_read_tokens),
          cost_usd: sum(c.cost_usd)
        }
    )
    |> complete()
  end

  # `sum` over no rows is nil, not zero — and a meter that renders "nil tokens"
  # is a bug the database handed to the page.
  defp complete(nil), do: @empty

  defp complete(row) do
    input = row.input_tokens || 0
    output = row.output_tokens || 0
    creation = row.cache_creation_tokens || 0
    read = row.cache_read_tokens || 0

    %{
      calls: row.calls || 0,
      input_tokens: input,
      output_tokens: output,
      cache_creation_tokens: creation,
      cache_read_tokens: read,
      total_tokens: input + output + creation + read,
      cost_usd: row.cost_usd || Decimal.new(0)
    }
  end
end
