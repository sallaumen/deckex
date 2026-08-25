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
  alias Deckex.AI.Ledger
  alias Deckex.Analysis
  alias Deckex.Analysis.DeckSnapshot
  alias Deckex.Budget
  alias Deckex.Cards
  alias Deckex.Cards.Name
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
  alias Deckex.Workers.CatalogueWorker
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
  defdelegate latest_for_lens(deck_id, lens), to: ConsultQuery

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
  # writes a dossier, the bracket lens classifies, and `:pilares` names cards
  # already in the list; none of them proposes cutting a card from a real deck,
  # so none needs the expensive model. Nothing a `:pilares` answer says reaches
  # the deck without the owner ticking it first, which is the same reason the
  # scout is here.
  #
  # `:visao` is deliberately NOT here: it carries no cuts and no adds either,
  # but it names what the owner will buy and steers nine stages after it.
  # `:plano` belongs here for the same reason: it reads the whole deck and is
  # forbidden from proposing a single card change. The stages that DO change
  # the deck — `:execucao` and `:critico` — are deliberately not here.
  @reads_only [:scout, :bracket, :pilares, :plano]

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

  @doc "One lens's pt-BR label — the same words the picker offers."
  @spec lens_label(atom()) :: String.t()
  def lens_label(lens) do
    case List.keyfind(lens_labels(), lens, 0) do
      {^lens, label} -> label
      nil -> to_string(lens)
    end
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
    |> Keyword.put(:card_notes, Decks.card_notes(deck))
    |> Keyword.put(:description, deck.description)
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
      {:ok, response, usage} ->
        # Recorded against both the consult and its deck: the run page asks
        # "what did this stage cost", the deck page asks "what has this deck
        # cost", and both are the same rows read differently.
        :ok =
          Ledger.record(usage,
            kind: :consult,
            model: running.model,
            deck_id: running.deck_id,
            consult_id: running.id
          )

        {:ok, succeed(running, response, started)}

      {:error, %Error{} = error} ->
        fail(running, error)
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
  #
  # The plan stage writes it too, and that is why there is no scout stage in
  # the recipe any more: a stage that has just read the whole deck to plan the
  # round can emit the four dossier fields for almost nothing, and a dossier
  # rewritten on every run is a dossier that cannot go stale between runs.
  defp deliver_dossier(%Consult{lens: lens} = consult) when lens in [:scout, :plano] do
    {:ok, deck} = Decks.fetch_deck(consult.deck_id)
    {:ok, _deck} = Decks.put_dossier(deck, Map.take(consult.response, Decks.dossier_fields()))

    consult
  end

  defp deliver_dossier(%Consult{} = consult), do: consult

  # The answer names cards we may never have seen. Fetch them here, once, while
  # we are already in a background job — the suggestion table only reads, so a
  # card missing from the catalogue would render without a price forever.
  # A Scryfall outage is not a reason to lose an answer that already cost money.
  defp catalogue(%Consult{} = consult) do
    case refresh_catalogue(consult) do
      :ok ->
        :ok

      {:error, %Error{} = error} ->
        Logger.warning("catalogue refresh failed for consult #{consult.id}: #{error.message}")

        # The miss is queued, not accepted. Left alone it is permanent: the
        # table only reads, so a card that never reached the catalogue reads as
        # "não achei essa carta na Scryfall" forever, and the audit and the
        # optimizer drop that suggestion from every count they make.
        {:ok, _job} = CatalogueWorker.enqueue(consult.id)
    end

    consult
  end

  @doc """
  Fetches every card the consult's answer names into the catalogue, and
  classifies the new arrivals.

  Reports the failure rather than swallowing it. Callers decide what a miss
  costs them: `run/1` queues `Deckex.Workers.CatalogueWorker` and keeps the
  answer, and the worker hands the error back to Oban so a Scryfall still down
  is retried instead of written off.
  """
  @spec refresh_catalogue(Consult.t()) :: :ok | {:error, Error.t()}
  def refresh_catalogue(%Consult{} = consult) do
    case consult |> card_names() |> Cards.resolve_names() do
      {:ok, %{cards: cards}} ->
        Enum.each(cards, &Cards.classify_card/1)

        :ok

      {:error, %Error{}} = error ->
        error
    end
  end

  @doc """
  Every answered consult whose suggestions name a card the catalogue does not
  hold.

  A card lost to a Scryfall outage is invisible until someone re-reads the
  answer it belonged to, so finding them means reading all of them — one query
  for the whole set rather than one per consult.
  """
  @spec incomplete_catalogue() :: [Consult.t()]
  def incomplete_catalogue do
    wanted = Enum.map(ConsultQuery.list_answered(), &{&1, keys(card_names(&1))})

    known =
      wanted
      |> Enum.flat_map(fn {_consult, keys} -> keys end)
      |> Enum.uniq()
      |> Cards.list_by_normalized_names()
      |> MapSet.new(& &1.name_normalized)

    for {consult, keys} <- wanted,
        Enum.any?(keys, &(not MapSet.member?(known, &1))),
        do: consult
  end

  # Suggestions carry the cuts and the adds; a vision answer has neither, and
  # its key cards would go unpriced without this.
  defp card_names(%Consult{} = consult) do
    Suggestions.names(consult) ++ Visions.card_names(consult)
  end

  defp keys(names), do: names |> Enum.map(&Name.normalize/1) |> Enum.uniq()

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
