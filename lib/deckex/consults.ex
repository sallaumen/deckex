defmodule Deckex.Consults do
  @moduledoc """
  Asking the AI what to do about a deck.

  `request/3` measures the deck, freezes both the report and the exact prompt,
  and queues the call. `run/1` sends **the stored briefing verbatim** — never a
  rebuilt one — because a consult whose prompt drifted from what was recorded is
  a consult that cannot be trusted or reproduced.
  """

  require Logger

  alias Deckex.AI
  alias Deckex.Analysis
  alias Deckex.Analysis.DeckSnapshot
  alias Deckex.Budget
  alias Deckex.Cards
  alias Deckex.Consults.Audit
  alias Deckex.Consults.Briefing
  alias Deckex.Consults.Consult
  alias Deckex.Consults.ConsultQuery
  alias Deckex.Consults.Schemas
  alias Deckex.Consults.Suggestion
  alias Deckex.Consults.Suggestions
  alias Deckex.Consults.Visions
  alias Deckex.Decks
  alias Deckex.Decks.Deck
  alias Deckex.Error
  alias Deckex.Events
  alias Deckex.Repo
  alias Deckex.Settings
  alias Deckex.Workers.ConsultWorker
  alias Deckex.Workers.OptimizationAdvanceWorker

  # A consult is a long generation by design: the model reads a 100-card list,
  # searches the web, and reasons about swaps. The AI port's 2-minute default is
  # sized for bulk classification, not for this, and it timed out on the first
  # real deck. Ten minutes with an explicit override, not a bumped global.
  @default_timeout_ms 600_000

  defdelegate list_for_deck(deck), to: ConsultQuery
  defdelegate list_all_for_optimization(id), to: ConsultQuery
  defdelegate fetch(id), to: ConsultQuery

  @doc """
  Measures `deck`, freezes the report, the prompt **and the model**, then queues
  the call.

  The model is recorded now rather than read at run time: changing the setting
  between asking and answering must not silently change what a queued consult
  runs.

  This cannot fail for an expected reason — every field is built here, not
  supplied by a user — so it raises rather than returning a tagged error.
  """
  @spec request(Deck.t(), atom(), keyword()) :: {:ok, Consult.t()}
  def request(%Deck{} = deck, lens, opts \\ []) do
    {:ok, hd(start(deck, lens, [opts[:model] || Settings.model()], opts))}
  end

  @doc """
  Runs one identical briefing across several models, so they can be compared on
  the same question.

  One briefing is built and shared by every consult: an experiment whose input
  differs per arm measures nothing.
  """
  @spec compare(Deck.t(), atom(), [String.t()], keyword()) :: {:ok, [Consult.t()]}
  def compare(%Deck{} = deck, lens, models, opts \\ []) do
    {:ok, start(deck, lens, models, opts)}
  end

  @doc "The model aliases the `claude` CLI accepts."
  @spec models() :: [String.t()]
  def models, do: ["fable", "sonnet", "opus", "haiku"]

  # Ordered by capability, not by price. An unknown alias ranks lowest so a
  # typo can never accidentally clear the floor.
  @model_rank %{"fable" => 4, "opus" => 3, "sonnet" => 2, "haiku" => 1}

  @doc "Where a model sits on the capability ladder; an unknown one sits at the bottom."
  @spec model_rank(String.t() | nil) :: non_neg_integer()
  def model_rank(model), do: Map.get(@model_rank, model, 0)

  # The floor is about what an answer CHANGES, not what it costs. The scout
  # writes a dossier and the bracket lens classifies; neither proposes cutting
  # a card from a real deck, so neither needs the expensive model. Everything
  # else does — including `:visao`, which carries no cuts and no adds but names
  # what the owner will buy and steers nine stages after it.
  @reads_only [:scout, :bracket]

  @doc """
  The models allowed to propose a card change, strongest first.

  The launcher offers only these: a dropdown that lists an option the app will
  refuse is a trap with a reason attached.
  """
  @spec models_at_or_above(String.t()) :: [String.t()]
  def models_at_or_above(floor) do
    models()
    |> Enum.filter(&(model_rank(&1) >= model_rank(floor)))
    |> Enum.sort_by(&model_rank/1, :desc)
  end

  @doc "Whichever of the two models ranks higher — never returns below the floor."
  @spec at_least(String.t() | nil, String.t()) :: String.t()
  def at_least(model, floor) do
    if model_rank(model) >= model_rank(floor), do: model, else: floor
  end

  @doc "Whether an answer from this lens can change the deck."
  @spec changes_deck?(atom()) :: boolean()
  def changes_deck?(lens), do: lens not in @reads_only

  @doc """
  Whether this consult proposed changes while answering below the owner's floor.

  Derived, never stored: the floor is a setting and may move, and a consult
  answered last week should be judged by the floor in force when it is read.
  """
  @spec below_floor?(Consult.t()) :: boolean()
  def below_floor?(%Consult{lens: lens, model: model}) do
    changes_deck?(lens) and model_rank(model) < model_rank(Settings.model_floor())
  end

  @doc "The lenses a user can pick, with their pt-BR labels."
  @spec lens_labels() :: [{atom(), String.t()}]
  def lens_labels do
    [
      {:full, "O deck inteiro"},
      {:matchup, "Contra um deck específico"},
      {:budget, "Melhorar gastando pouco"},
      {:upgrade, "Melhorar sem olhar preço"},
      {:speed_curve, "Só velocidade e curva"},
      {:mana_ramp, "Só mana e aceleração"},
      {:interaction, "Só interação"},
      {:consistency, "Só consistência"},
      {:bracket, "Em que bracket esse deck está?"}
    ]
  end

  defp start(deck, lens, models, opts) do
    # The pipeline analyses its sandbox, not the deck: it passes the snapshot
    # it built. Everything downstream — report, briefing, freeze — is shared.
    snapshot = opts[:snapshot] || Decks.snapshot(deck)
    report = Analysis.report(snapshot, Settings.baselines())
    briefing = Briefing.build(report, snapshot, lens, briefing_opts(deck, lens, snapshot, opts))
    frozen = freeze(report)

    Enum.map(models, fn model ->
      consult = insert!(deck, lens, briefing, frozen, model, opts)

      {:ok, _job} = ConsultWorker.enqueue(consult.id)
      Events.broadcast_consult(consult)

      consult
    end)
  end

  defp briefing_opts(deck, lens, snapshot, opts) do
    opts
    |> Keyword.put_new(:ceilings, Settings.ceilings(lens))
    |> Keyword.put_new(:budget, budget_state(snapshot, opts))
    |> Keyword.put(:dossier, deck.dossier)
    |> Keyword.put(:dossier_stale, deck.dossier_stale)
  end

  # The briefing is pure and cannot ask Settings what the owner's limits are,
  # nor Money what a dollar is worth. Both are read here and handed over as
  # facts — the same reason baselines are passed rather than fetched.
  defp budget_state(snapshot, opts) do
    policy = Budget.from_contract(get_in(opts, [:optimization, :contract, "forma_do_gasto"]))

    %{
      policy: policy,
      occupancy: Budget.occupancy(snapshot.main ++ snapshot.commanders, policy)
    }
  end

  @doc "Sends a consult's stored briefing to the model and records the answer."
  @spec run(Consult.t()) :: {:ok, Consult.t()} | {:error, Error.t()}
  def run(%Consult{} = consult) do
    running = update!(consult, %{status: :running})
    started = System.monotonic_time(:millisecond)
    schema = Schemas.for_lens(running.lens)

    # WebSearch is the point of the whole feature: the app supplies measured
    # facts about this deck, the model supplies knowledge about every card.
    opts = [allowed_tools: ["WebSearch"], timeout_ms: timeout_ms(), model: running.model]

    case AI.complete(running.briefing, schema, opts) do
      {:ok, response} -> {:ok, succeed(running, response, started)}
      {:error, %Error{} = error} -> fail(running, error)
    end
  end

  @doc """
  The engine's verdict on an answer's suggestions: legality problems per
  suggestion, and the measured findings diff of applying the clean ones.

  Computed on read, never stored — it always answers "what would happen if
  applied **now**", against the deck as it currently is.
  """
  @spec audit(DeckSnapshot.t(), [Suggestion.t()], atom()) :: Audit.t()
  def audit(%DeckSnapshot{} = snapshot, suggestions, lens \\ :full) do
    roles =
      suggestions
      |> Enum.filter(&(&1.resolved? and &1.action == :add))
      |> Enum.map(& &1.card.id)
      |> Cards.roles_by_card_ids()

    Audit.run(snapshot, suggestions, roles, Settings.baselines(), Settings.ceilings(lens))
  end

  @doc "How long a consult may take before it is called a timeout."
  @spec timeout_ms() :: pos_integer()
  def timeout_ms do
    :deckex
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:timeout_ms, @default_timeout_ms)
  end

  defp insert!(deck, lens, briefing, frozen, model, opts) do
    %Consult{}
    |> Consult.changeset(%{
      deck_id: deck.id,
      lens: lens,
      finding_code: opts[:finding_code],
      status: :pending,
      briefing: briefing,
      report_snapshot: frozen,
      model: model,
      optimization_id: opts[:optimization_id]
    })
    |> Repo.insert!()
  end

  # Through JSON and back, so the stored snapshot is exactly what a reader will
  # get out of the column — no structs, no atoms.
  defp freeze(report), do: report |> Jason.encode!() |> Jason.decode!()

  # Persist first, broadcast LAST. The "done" event is a promise that
  # everything the answer implies — the dossier on the deck, the suggested
  # cards in the catalogue — is already there when a subscriber re-reads.
  # Broadcasting inside the status update let the deck page re-read the deck
  # before the scout's dossier landed, and no later event ever corrected it.
  defp succeed(consult, response, started) do
    done =
      consult
      |> Consult.changeset(%{
        status: :done,
        response: response,
        duration_ms: System.monotonic_time(:millisecond) - started,
        error: nil
      })
      |> Repo.update!()

    done = done |> deliver_dossier() |> catalogue() |> advance_optimization()

    Events.broadcast_consult(done)

    done
  end

  # A pipeline consult hands its answer to the AdvanceWorker — a separate job,
  # so a crash in the advance never loses an answer already paid for. Enqueued
  # after catalogue(): the audit needs the suggested cards in the catalogue.
  defp advance_optimization(%Consult{optimization_id: nil} = consult), do: consult

  defp advance_optimization(%Consult{} = consult) do
    {:ok, _job} = OptimizationAdvanceWorker.enqueue(consult.id)

    consult
  end

  # A scout's answer IS the dossier. Writing it here — in the background job
  # that already ran — is what lets the deck page only ever read.
  defp deliver_dossier(%Consult{lens: :scout} = consult) do
    {:ok, deck} = Decks.fetch_deck(consult.deck_id)
    {:ok, _deck} = Decks.put_dossier(deck, consult.response)

    consult
  end

  defp deliver_dossier(%Consult{} = consult), do: consult

  # The answer names cards we may never have seen. Fetch them here, once, while
  # we are already in a background job — the suggestion table only reads, so a
  # card missing from the catalogue would render without a price forever.
  # A Scryfall outage is not a reason to lose an answer that already cost money.
  defp catalogue(%Consult{} = consult) do
    refresh_catalogue(consult)

    consult
  end

  @doc """
  Fetches every card the consult's answer names into the catalogue, and
  classifies the new arrivals. Best-effort: a Scryfall failure is logged and
  tolerated — the pipeline's judge retries it before any verdict, so a
  transient failure here must not fail the consult.
  """
  @spec refresh_catalogue(Consult.t()) :: :ok
  def refresh_catalogue(%Consult{} = consult) do
    names = Suggestions.names(consult) ++ Visions.card_names(consult)

    case Cards.resolve_names(names) do
      {:ok, %{cards: cards}} ->
        Enum.each(cards, &Cards.classify_card/1)

      {:error, %Error{} = error} ->
        Logger.warning("catalogue refresh failed for consult #{consult.id}: #{error.message}")
    end

    :ok
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
