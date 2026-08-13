defmodule Deckex.Consults do
  @moduledoc """
  Asking the AI what to do about a deck.

  `request/3` measures the deck, freezes both the report and the exact prompt,
  and queues the call. `run/1` sends **the stored briefing verbatim** — never a
  rebuilt one — because a consult whose prompt drifted from what was recorded is
  a consult that cannot be trusted or reproduced.
  """

  alias Deckex.AI
  alias Deckex.Analysis
  alias Deckex.Consults.Briefing
  alias Deckex.Consults.Consult
  alias Deckex.Consults.ConsultQuery
  alias Deckex.Consults.Schemas
  alias Deckex.Decks
  alias Deckex.Decks.Deck
  alias Deckex.Error
  alias Deckex.Events
  alias Deckex.Repo
  alias Deckex.Workers.ConsultWorker

  # A consult is a long generation by design: the model reads a 100-card list,
  # searches the web, and reasons about swaps. The AI port's 2-minute default is
  # sized for bulk classification, not for this, and it timed out on the first
  # real deck. Ten minutes with an explicit override, not a bumped global.
  @default_timeout_ms 600_000

  defdelegate list_for_deck(deck), to: ConsultQuery
  defdelegate fetch(id), to: ConsultQuery

  @doc """
  Measures `deck`, freezes the report and the prompt, and queues the AI call.

  This cannot fail for an expected reason — every field is built here, not
  supplied by a user — so it raises rather than returning a tagged error. The
  `{:ok, _}` wrapper is kept because the caller composes with `run/1`, which
  genuinely can fail.
  """
  @spec request(Deck.t(), atom(), keyword()) :: {:ok, Consult.t()}
  def request(%Deck{} = deck, lens, opts \\ []) do
    snapshot = Decks.snapshot(deck)
    report = Analysis.report(snapshot)
    consult = insert!(deck, lens, Briefing.build(report, snapshot, lens, opts), report, opts)

    {:ok, _job} = ConsultWorker.enqueue(consult.id)
    Events.broadcast_consult(consult)

    {:ok, consult}
  end

  @doc "Sends a consult's stored briefing to the model and records the answer."
  @spec run(Consult.t()) :: {:ok, Consult.t()} | {:error, Error.t()}
  def run(%Consult{} = consult) do
    running = update!(consult, %{status: :running})
    started = System.monotonic_time(:millisecond)
    schema = Schemas.for_lens(running.lens)

    # WebSearch is the point of the whole feature: the app supplies measured
    # facts about this deck, the model supplies knowledge about every card.
    opts = [allowed_tools: ["WebSearch"], timeout_ms: timeout_ms()]

    case AI.complete(running.briefing, schema, opts) do
      {:ok, response} -> {:ok, succeed(running, response, started)}
      {:error, %Error{} = error} -> fail(running, error)
    end
  end

  @doc "How long a consult may take before it is called a timeout."
  @spec timeout_ms() :: pos_integer()
  def timeout_ms do
    :deckex |> Application.get_env(__MODULE__, []) |> Keyword.get(:timeout_ms, @default_timeout_ms)
  end

  defp insert!(deck, lens, briefing, report, opts) do
    %Consult{}
    |> Consult.changeset(%{
      deck_id: deck.id,
      lens: lens,
      finding_code: opts[:finding_code],
      status: :pending,
      briefing: briefing,
      report_snapshot: freeze(report)
    })
    |> Repo.insert!()
  end

  # Through JSON and back, so the stored snapshot is exactly what a reader will
  # get out of the column — no structs, no atoms.
  defp freeze(report), do: report |> Jason.encode!() |> Jason.decode!()

  defp succeed(consult, response, started) do
    update!(consult, %{
      status: :done,
      response: response,
      model: AI.model(),
      duration_ms: System.monotonic_time(:millisecond) - started,
      error: nil
    })
  end

  defp fail(consult, %Error{} = error) do
    update!(consult, %{status: :failed, error: error.message})

    {:error, error}
  end

  defp update!(consult, attrs) do
    updated = consult |> Consult.changeset(attrs) |> Repo.update!()

    Events.broadcast_consult(updated)

    updated
  end
end
