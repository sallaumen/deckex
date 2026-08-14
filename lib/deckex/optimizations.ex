defmodule Deckex.Optimizations do
  @moduledoc """
  The Otimizador: a pipeline of AI stages over a sandbox copy of a deck.

  Each stage consults a model through one lens, the engine audits the answer,
  and the clean changes are applied automatically — **to the sandbox, never to
  the real deck**. Later stages see everything earlier stages did and may
  revert it once, with a reason; the audit's flip-flop guard stops churn.

  See `docs/superpowers/specs/2026-08-14-otimizador-design.md`.
  """

  alias Deckex.Analysis.Bracket
  alias Deckex.Analysis.CardEntry
  alias Deckex.Analysis.DeckSnapshot
  alias Deckex.Cards
  alias Deckex.Cards.Name
  alias Deckex.Consults
  alias Deckex.Consults.Audit
  alias Deckex.Consults.Suggestions
  alias Deckex.Decks
  alias Deckex.Decks.Deck
  alias Deckex.Decks.DeckQuery
  alias Deckex.Error
  alias Deckex.Events
  alias Deckex.Optimizations.Optimization
  alias Deckex.Optimizations.OptimizationQuery
  alias Deckex.Optimizations.OptimizationStep
  alias Deckex.Repo
  alias Deckex.Settings

  @doc """
  The goal contract's defaults, derived from the deck and Settings — never
  from constants tuned to any particular deck (spec §8).

  `bracket_max` defaults to the deck's current measured floor: optimize
  without changing which table the deck belongs at. The owner who wants to
  climb sets it higher in the launch modal.
  """
  @spec default_contract(Deck.t()) :: map()
  def default_contract(%Deck{} = deck) do
    ceilings = Settings.ceilings(:upgrade)

    %{
      "bracket_max" => Bracket.floor(Decks.snapshot(deck)).floor,
      "ceilings" => %{"card" => ceilings.card, "land" => ceilings.land},
      "keep" => [],
      "matchups" => ["um deck aggro rápido", "um deck de controle pesado"],
      "notes" => "",
      "model" => Settings.model()
    }
  end

  @doc """
  The default recipe — spec §4's nine stages, as data.

  The scout stage is included only when the deck's dossier is missing or
  stale, decided here at build time: a skipped scout never appears as a stage
  at all.
  """
  @spec recipe(Deck.t()) :: [map()]
  def recipe(%Deck{} = deck) do
    scout =
      if deck.dossier == nil or deck.dossier_stale do
        [%{"kind" => "lens", "lens" => "scout", "label" => "Dossiê"}]
      else
        []
      end

    scout ++
      [
        %{"kind" => "lens", "lens" => "mana_ramp", "label" => "Mana"},
        %{"kind" => "lens", "lens" => "speed_curve", "label" => "Early game"},
        %{"kind" => "lens", "lens" => "interaction", "label" => "Interação"},
        %{"kind" => "lens", "lens" => "consistency", "label" => "Consistência"},
        %{"kind" => "checkpoint", "lens" => "full", "label" => "Estabilização 1"},
        %{"kind" => "validation", "lens" => "matchup", "label" => "Matchups"},
        %{"kind" => "validation", "lens" => "alinhamento", "label" => "Propósito"},
        %{"kind" => "checkpoint", "lens" => "full", "label" => "Estabilização 2"}
      ]
  end

  @doc """
  Launches a run: freezes the contract, the recipe and the sandbox's starting
  list, creates every stage, and starts the first one.

  One running (or paused) optimization per deck — the sandbox is a serialized
  conversation, and two of them editing the same starting point would both be
  wrong.
  """
  @spec start(Deck.t(), map(), [map()] | nil) :: {:ok, Optimization.t()} | {:error, Error.t()}
  def start(%Deck{} = deck, contract_attrs \\ %{}, recipe_override \\ nil) do
    if OptimizationQuery.running_for_deck(deck.id) do
      {:error,
       Error.new(
         :optimization_running,
         "Já tem uma otimização em andamento para esse deck. Espere ou cancele antes de começar outra."
       )}
    else
      %{list: list, commanders: commanders} = list_from_deck(deck)
      recipe = recipe_override || recipe(deck)
      contract = Map.merge(default_contract(deck), contract_attrs)

      {:ok, optimization} =
        Repo.transact(fn ->
          optimization =
            %Optimization{}
            |> Optimization.changeset(%{
              deck_id: deck.id,
              status: :running,
              contract: contract,
              recipe: recipe,
              list_original: list,
              commanders: commanders
            })
            |> Repo.insert!()

          recipe
          |> Enum.with_index(1)
          |> Enum.each(&insert_step!(optimization, &1, list))

          {:ok, optimization}
        end)

      {:ok, optimization} = fetch(optimization.id)
      {:ok, _step} = run_step(hd(optimization.steps))

      fetch(optimization.id)
    end
  end

  @doc "Stops advancing after the consult in flight lands. Paid work is kept."
  @spec pause(Optimization.t()) :: {:ok, Optimization.t()}
  def pause(%Optimization{} = optimization), do: transition(optimization, :paused)

  @doc "Resumes a paused run: the next pending (or failed) stage runs again."
  @spec resume(Optimization.t()) :: {:ok, Optimization.t()}
  def resume(%Optimization{} = optimization) do
    {:ok, resumed} = transition(optimization, :running)

    case resumable_step(resumed) do
      nil -> {:ok, resumed}
      step -> with {:ok, _step} <- run_step(step), do: fetch(resumed.id)
    end
  end

  @doc "Cancels a run. Everything already done stays readable."
  @spec cancel(Optimization.t()) :: {:ok, Optimization.t()}
  def cancel(%Optimization{} = optimization), do: transition(optimization, :cancelled)

  @doc "Stores the owner's feedback on one stage — the margin notes."
  @spec set_feedback(OptimizationStep.t(), map()) :: {:ok, OptimizationStep.t()}
  def set_feedback(%OptimizationStep{} = step, attrs) do
    feedback = Map.merge(step.feedback || %{}, Map.take(attrs, ["rating", "favorite", "note"]))

    {:ok, step |> OptimizationStep.changeset(%{feedback: feedback}) |> Repo.update!()}
  end

  @doc """
  Saves a sandbox state as a brand-new deck — from one stage, or from the
  run's latest state when no stage is given. The original deck is untouched;
  leaving the sandbox is always this explicit action.
  """
  @spec save_as_deck(Optimization.t(), OptimizationStep.t() | nil) ::
          {:ok, Deck.t()} | {:error, Error.t()}
  def save_as_deck(%Optimization{} = optimization, step \\ nil) do
    {:ok, deck} = Decks.fetch_deck(optimization.deck_id)
    list = fork_list(optimization, step)
    suffix = if step, do: " — otimizado, etapa #{step.position}", else: " — otimizado"

    Decks.import_from_text(list_to_text(list, optimization.commanders), %{
      name: "#{deck.name}#{suffix}",
      source: :paste
    })
  end

  @doc "The run's most recent sandbox state."
  @spec current_list(Optimization.t()) :: [map()]
  def current_list(%Optimization{} = optimization) do
    optimization.steps
    |> Enum.filter(&(&1.status == :done))
    |> List.last()
    |> case do
      nil -> optimization.list_original
      step -> list_after(step)
    end
  end

  @doc """
  Starts one stage: builds the sandbox snapshot, freezes a briefing carrying
  the contract and the changelog, and queues the consult.
  """
  @spec run_step(OptimizationStep.t()) :: {:ok, OptimizationStep.t()}
  def run_step(%OptimizationStep{} = step) do
    {:ok, optimization} = fetch(step.optimization_id)
    {:ok, deck} = Decks.fetch_deck(optimization.deck_id)
    step = ensure_list_before(step, optimization)
    snapshot = snapshot_for(step.list_before, optimization.commanders, deck)

    {:ok, consult} =
      Consults.request(deck, String.to_existing_atom(step.lens),
        snapshot: snapshot,
        optimization_id: optimization.id,
        model: optimization.contract["model"],
        against: optimization.contract["matchups"],
        optimization: %{
          contract: optimization.contract,
          changelog: changelog(optimization, step),
          stage_kind: step.kind
        }
      )

    updated =
      step
      |> OptimizationStep.changeset(%{status: :running, consult_id: consult.id})
      |> Repo.update!()

    Events.broadcast_optimization(optimization)

    {:ok, updated}
  end

  @doc """
  A finished pipeline consult comes home: audit the answer, apply the clean
  changes to the sandbox, and start the next stage — or finish.

  Persist first, broadcast last, exactly like `Consults.succeed/3`: the
  optimization event is a promise that the stage's results are readable.
  """
  @spec advance(Consults.Consult.t()) :: :ok
  def advance(consult) do
    step = OptimizationQuery.step_for_consult(consult.id)
    optimization = step.optimization
    {:ok, deck} = Decks.fetch_deck(optimization.deck_id)

    {applied, rejected} = judge(consult, step, optimization, deck)

    done =
      step
      |> OptimizationStep.changeset(%{status: :done, applied: applied, rejected: rejected})
      |> Repo.update!()

    {:ok, refreshed} = fetch(optimization.id)
    settle(refreshed, done)

    {:ok, final} = fetch(optimization.id)
    Events.broadcast_optimization(final)

    :ok
  end

  @doc "A stage's consult failed for good: the run pauses, paid work stays."
  @spec mark_failed(Consults.Consult.t()) :: :ok
  def mark_failed(consult) do
    case OptimizationQuery.step_for_consult(consult.id) do
      nil ->
        :ok

      step ->
        step |> OptimizationStep.changeset(%{status: :failed}) |> Repo.update!()

        {:ok, optimization} = fetch(step.optimization_id)
        {:ok, _paused} = pause(optimization)

        :ok
    end
  end

  # ── the judgment ──────────────────────────────────────────────────────────

  defp judge(consult, step, optimization, deck) do
    snapshot = snapshot_for(step.list_before, optimization.commanders, deck)
    suggestions = Suggestions.for_consult(consult)

    roles =
      suggestions
      |> Enum.filter(&(&1.resolved? and &1.action == :add))
      |> Enum.map(& &1.card.id)
      |> Cards.roles_by_card_ids()

    ceilings = %{
      card: optimization.contract["ceilings"]["card"],
      land: optimization.contract["ceilings"]["land"]
    }

    audit =
      Audit.run(
        snapshot,
        suggestions,
        roles,
        Settings.baselines(),
        ceilings,
        history: history(optimization, step),
        keep: (optimization.contract["keep"] || []) ++ optimization.commanders,
        bracket_max: optimization.contract["bracket_max"]
      )

    split(suggestions, audit)
  end

  defp split(suggestions, audit) do
    {clean, dirty} =
      Enum.split_with(suggestions, fn suggestion ->
        suggestion.resolved? and
          not Map.has_key?(audit.problems, {suggestion.action, suggestion.name})
      end)

    applied =
      Enum.map(clean, fn s ->
        %{"action" => to_string(s.action), "card" => s.name, "reason" => s.reason}
      end)

    rejected =
      Enum.map(dirty, fn s ->
        problems =
          if s.resolved?,
            do: Map.get(audit.problems, {s.action, s.name}, []),
            else: ["não resolvida na Scryfall"]

        %{
          "action" => to_string(s.action),
          "card" => s.name,
          "reason" => s.reason,
          "problems" => problems
        }
      end)

    {applied, rejected}
  end

  # Every change earlier stages actually applied — the flip-flop guard's memory.
  defp history(optimization, current_step) do
    optimization.steps
    |> Enum.filter(&(&1.status == :done and &1.position < current_step.position))
    |> Enum.flat_map(& &1.applied)
  end

  # ── the advance ───────────────────────────────────────────────────────────

  defp settle(optimization, done_step) do
    case next_runnable(optimization, done_step) do
      :finished ->
        finish(optimization)

      {:ok, next} ->
        if optimization.status == :running do
          next
          |> OptimizationStep.changeset(%{list_before: list_after(done_step)})
          |> Repo.update!()
          |> run_step()
        end

        :ok
    end
  end

  # Convergence (spec §4): a checkpoint is skipped when every stage since the
  # previous checkpoint — inclusive — applied zero changes. A second look at
  # an unchanged picture buys noise with money.
  defp next_runnable(optimization, done_step) do
    case Enum.find(optimization.steps, &(&1.status == :pending)) do
      nil ->
        :finished

      %{kind: :checkpoint} = next ->
        if stable_since_last_checkpoint?(optimization, next) do
          skipped = next |> OptimizationStep.changeset(%{status: :skipped}) |> Repo.update!()
          {:ok, refreshed} = fetch(optimization.id)

          next_runnable(refreshed, %{skipped | list_before: done_step && list_after(done_step)})
        else
          {:ok, next}
        end

      next ->
        {:ok, next}
    end
  end

  defp stable_since_last_checkpoint?(optimization, upcoming) do
    prior =
      optimization.steps
      |> Enum.filter(&(&1.position < upcoming.position and &1.status in [:done, :skipped]))
      |> Enum.reverse()

    # The segment ends at the previous checkpoint — inclusive — and never
    # reaches past it: what a lens did BEFORE that checkpoint was already that
    # checkpoint's business, not this one's.
    segment =
      case Enum.split_while(prior, &(&1.kind != :checkpoint)) do
        {lenses, [checkpoint | _older]} -> [checkpoint | lenses]
        {lenses, []} -> lenses
      end

    segment != [] and Enum.all?(segment, &(&1.applied == []))
  end

  defp finish(optimization) do
    # Re-read: the skip that led here was persisted after this struct was
    # loaded, and the outcome depends on seeing it.
    {:ok, optimization} = fetch(optimization.id)

    outcome =
      case List.last(optimization.steps) do
        %{kind: :checkpoint, status: :skipped} -> "estabilizou"
        _ran -> "completo"
      end

    optimization
    |> Optimization.changeset(%{
      status: :done,
      outcome: outcome,
      finished_at: DateTime.utc_now(:second)
    })
    |> Repo.update!()

    :ok
  end

  defp ensure_list_before(%OptimizationStep{list_before: nil} = step, optimization) do
    previous =
      optimization.steps
      |> Enum.filter(&(&1.status == :done and &1.position < step.position))
      |> List.last()

    list = if previous, do: list_after(previous), else: optimization.list_original

    step |> OptimizationStep.changeset(%{list_before: list}) |> Repo.update!()
  end

  defp ensure_list_before(step, _optimization), do: step

  defp changelog(optimization, current_step) do
    optimization.steps
    |> Enum.filter(&(&1.status == :done and &1.position < current_step.position))
    |> Enum.map(&%{label: &1.label, applied: &1.applied, rejected: &1.rejected})
  end

  defp insert_step!(optimization, {spec, position}, list) do
    %OptimizationStep{}
    |> OptimizationStep.changeset(%{
      optimization_id: optimization.id,
      position: position,
      kind: String.to_existing_atom(spec["kind"]),
      lens: spec["lens"],
      label: spec["label"],
      status: :pending,
      list_before: if(position == 1, do: list)
    })
    |> Repo.insert!()
  end

  defp fork_list(optimization, nil), do: current_list(optimization)
  defp fork_list(_optimization, step), do: list_after(step)

  defp resumable_step(%Optimization{steps: steps}) do
    case Enum.find(steps, &(&1.status in [:failed, :pending])) do
      nil ->
        nil

      %{status: :failed} = step ->
        step |> OptimizationStep.changeset(%{status: :pending}) |> Repo.update!()

      step ->
        step
    end
  end

  defp transition(optimization, status) do
    updated =
      optimization
      |> Optimization.changeset(%{status: status})
      |> Repo.update!()

    Events.broadcast_optimization(updated)

    fetch(updated.id)
  end

  @doc "The deck's current main board and commanders, as sandbox data."
  @spec list_from_deck(Deck.t()) :: %{list: [map()], commanders: [String.t()]}
  def list_from_deck(%Deck{} = deck) do
    grouped = deck |> DeckQuery.list_deck_cards() |> Enum.group_by(& &1.board)

    %{
      list:
        grouped
        |> Map.get(:main, [])
        |> Enum.map(&%{"name" => &1.card.name, "quantity" => &1.quantity}),
      commanders: grouped |> Map.get(:commander, []) |> Enum.map(& &1.card.name)
    }
  end

  @doc """
  Applies a stage's accepted changes to a sandbox list. Pure list arithmetic —
  the audit already vetted legality, singleton and the rest before anything
  reaches here.
  """
  @spec apply_changes_to_list([map()], [map()]) :: [map()]
  def apply_changes_to_list(list, changes) do
    Enum.reduce(changes, list, &apply_change/2)
  end

  @doc """
  The sandbox as a stage left it — its `list_before` plus its `applied`
  changes. Derived, never stored: one source of truth.
  """
  @spec list_after(OptimizationStep.t()) :: [map()]
  def list_after(%OptimizationStep{} = step) do
    apply_changes_to_list(step.list_before || [], step.applied || [])
  end

  @doc """
  Builds the snapshot the analysis engine reads, from a sandbox list.

  Cards and roles come from the catalogue; anything a stage added was
  catalogued when its consult finished. A list entry whose card is missing
  from the catalogue is skipped — the same behaviour as import.
  """
  @spec snapshot_for([map()], [String.t()], Deck.t()) :: DeckSnapshot.t()
  def snapshot_for(list, commanders, %Deck{} = deck) do
    names = Enum.map(list, & &1["name"]) ++ commanders
    cards = Cards.list_by_normalized_names(Enum.map(names, &Name.normalize/1))
    roles = cards |> Enum.map(& &1.id) |> Cards.roles_by_card_ids()
    by_key = Map.new(cards, &{&1.name_normalized, &1})

    %DeckSnapshot{
      deck_id: deck.id,
      deck_name: deck.name,
      color_identity: deck.color_identity,
      commanders: entries(Enum.map(commanders, &%{"name" => &1, "quantity" => 1}), by_key, roles),
      main: entries(list, by_key, roles)
    }
  end

  @doc """
  A sandbox list as decklist text `Decks.import_from_text/2` round-trips —
  the commander section first, in the convention the parser reads.
  """
  @spec list_to_text([map()], [String.t()]) :: String.t()
  def list_to_text(list, commanders) do
    commander_block =
      case commanders do
        [] -> ""
        names -> "Commander:\n" <> Enum.map_join(names, "\n", &"1 #{&1}") <> "\n\n"
      end

    commander_block <> Enum.map_join(list, "\n", &"#{&1["quantity"]} #{&1["name"]}")
  end

  defp entries(rows, by_key, roles) do
    Enum.flat_map(rows, fn row ->
      case Map.get(by_key, Name.normalize(row["name"])) do
        nil -> []
        card -> [CardEntry.new(card, row["quantity"], Map.get(roles, card.id, []))]
      end
    end)
  end

  defp apply_change(%{"action" => "add", "card" => name}, list) do
    case Enum.split_with(list, &same_card?(&1, name)) do
      {[], _rest} ->
        list ++ [%{"name" => name, "quantity" => 1}]

      {[existing | dupes], rest} ->
        [%{existing | "quantity" => existing["quantity"] + 1} | dupes] ++ rest
    end
  end

  defp apply_change(%{"action" => "cut", "card" => name}, list) do
    case Enum.split_with(list, &same_card?(&1, name)) do
      {[], _rest} ->
        list

      {[%{"quantity" => 1} | dupes], rest} ->
        dupes ++ rest

      {[existing | dupes], rest} ->
        [%{existing | "quantity" => existing["quantity"] - 1} | dupes] ++ rest
    end
  end

  defp same_card?(row, name), do: Name.normalize(row["name"]) == Name.normalize(name)

  defdelegate fetch_run(id), to: __MODULE__, as: :fetch

  @doc "One run with its steps, or a not-found error."
  @spec fetch(String.t()) ::
          {:ok, Deckex.Optimizations.Optimization.t()} | {:error, Deckex.Error.t()}
  def fetch(id) do
    case OptimizationQuery.get(id) do
      nil -> {:error, Deckex.Error.new(:optimization_not_found, "Não achei essa otimização.")}
      optimization -> {:ok, optimization}
    end
  end

  defdelegate list_for_deck(deck_id), to: OptimizationQuery
end
