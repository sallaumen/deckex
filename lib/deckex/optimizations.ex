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
  alias Deckex.Budget
  alias Deckex.Cards
  alias Deckex.Cards.Name
  alias Deckex.Consults
  alias Deckex.Consults.Audit
  alias Deckex.Consults.ConsultQuery
  alias Deckex.Consults.Suggestions
  alias Deckex.Consults.Visions
  alias Deckex.Decks
  alias Deckex.Decks.Deck
  alias Deckex.Decks.DeckQuery
  alias Deckex.Error
  alias Deckex.Events
  alias Deckex.Optimizations.Balance
  alias Deckex.Optimizations.Optimization
  alias Deckex.Optimizations.OptimizationQuery
  alias Deckex.Optimizations.OptimizationStep
  alias Deckex.Optimizations.Salt
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
      # Frozen at launch, like every other rule here: changing Ajustes halfway
      # through must not quietly move the line a finished stage was judged by.
      "forma_do_gasto" => Budget.to_contract(Budget.policy()),
      "keep" => [],
      "matchups" => ["um deck aggro rápido", "um deck de controle pesado"],
      "notes" => "",
      # Every stage of an optimization proposes cutting and adding cards, so
      # the floor is the default here rather than the global model — the owner
      # should not have to remember to raise it before spending ten consults.
      "model" => Consults.at_least(Settings.model(), Settings.model_floor())
    }
  end

  @doc """
  The default recipe — spec §4's nine stages, as data.

  The scout stage is included only when the deck's dossier is missing or
  stale, decided here at build time: a skipped scout never appears as a stage
  at all.
  """
  @spec recipe(Deck.t()) :: [map()]
  def recipe(%Deck{} = deck), do: recipe(deck, :refine)

  @doc """
  The stages, as data.

  `:refine` opens with a scout only when the dossier is missing or stale.
  `:reimagine` opens with the visions and never scouts: a reimagining does not
  need the deck's current purpose written down first, and the dossier — when
  there is one — is passed as context regardless.

  Stages 3-10 of the reimagine recipe are the refine recipe verbatim, and that
  is the point: once the direction is chosen and the big swap is done, making
  the new deck good is the work the Otimizador already does well.
  """
  @spec recipe(Deck.t(), :refine | :reimagine) :: [map()]
  def recipe(%Deck{} = deck, :refine) do
    scout =
      if deck.dossier == nil or deck.dossier_stale do
        [%{"kind" => "lens", "lens" => "scout", "label" => "Dossiê"}]
      else
        []
      end

    scout ++ tuning_stages()
  end

  def recipe(%Deck{} = _deck, :reimagine) do
    [
      %{"kind" => "lens", "lens" => "visao", "label" => "Visões"},
      %{"kind" => "reconstruction", "lens" => "full", "label" => "Reconstrução"}
    ] ++ tuning_stages()
  end

  defp tuning_stages do
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
    {mode, contract_attrs} = Map.pop(contract_attrs, "mode", :refine)
    contract = Map.merge(default_contract(deck), contract_attrs)

    cond do
      OptimizationQuery.running_for_deck(deck.id) ->
        {:error,
         Error.new(
           :optimization_running,
           "Já tem uma otimização em andamento para esse deck. Espere ou cancele antes de começar outra."
         )}

      Consults.model_rank(contract["model"]) < Consults.model_rank(Settings.model_floor()) ->
        {:error,
         Error.new(
           :model_below_floor,
           "Uma otimização propõe cortar e adicionar cartas do seu deck, e #{contract["model"]} " <>
             "está abaixo do seu piso (#{Settings.model_floor()}). Suba o modelo ou o piso nos Ajustes."
         )}

      true ->
        launch(deck, mode, contract, recipe_override)
    end
  end

  # Nobody supervises a pipeline mid-flight, so the floor is a refusal here
  # rather than the mark a single consult gets on the deck page.
  defp launch(deck, mode, contract, recipe_override) do
    %{list: list, commanders: commanders} = list_from_deck(deck)
    recipe = recipe_override || recipe(deck, mode)

    {:ok, optimization} =
      Repo.transact(fn ->
        optimization =
          %Optimization{}
          |> Optimization.changeset(%{
            deck_id: deck.id,
            mode: mode,
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

  @doc "Stops advancing after the consult in flight lands. Paid work is kept."
  @spec pause(Optimization.t()) :: {:ok, Optimization.t()}
  def pause(%Optimization{} = optimization), do: transition(optimization, :paused)

  @doc "Resumes a paused run: the next pending (or failed) stage runs again."
  @spec resume(Optimization.t()) :: {:ok, Optimization.t()}
  def resume(%Optimization{status: :awaiting_choice} = optimization) do
    if chosen_vision(optimization) do
      do_resume(optimization)
    else
      {:error,
       Error.new(
         :vision_not_chosen,
         "Essa rodada está esperando: escolha uma direção para continuar."
       )}
    end
  end

  def resume(%Optimization{} = optimization), do: do_resume(optimization)

  defp do_resume(%Optimization{} = optimization) do
    {:ok, resumed} = transition(optimization, :running)

    case resumable_step(resumed) do
      nil -> {:ok, resumed}
      step -> with {:ok, _step} <- run_step(step), do: fetch(resumed.id)
    end
  end

  @doc "The visions this run has asked for, oldest first. Declined sets stay."
  @spec vision_consults(Optimization.t()) :: [Consults.Consult.t()]
  def vision_consults(%Optimization{} = optimization) do
    ConsultQuery.list_for_optimization(optimization.id, :visao)
  end

  @doc "The direction the owner picked, or nil while the run still waits."
  @spec chosen_vision(Optimization.t()) :: map() | nil
  def chosen_vision(%Optimization{} = optimization), do: optimization.contract["visao"]

  @doc """
  Freezes the chosen direction into the contract and resumes the run.

  `index` is the position in the most recent set of visions — what the owner
  clicked. Frozen like every other contract field: a run whose target drifts
  mid-flight is one nobody can reason about afterwards.
  """
  @spec choose_vision(Optimization.t(), non_neg_integer()) ::
          {:ok, Optimization.t()} | {:error, Error.t()}
  def choose_vision(%Optimization{} = optimization, index) do
    visions =
      case List.last(vision_consults(optimization)) do
        nil -> []
        consult -> List.wrap(consult.response["visoes"])
      end

    case Enum.at(visions, index) do
      nil ->
        {:error, Error.new(:vision_not_found, "Não achei essa direção nesta rodada.")}

      vision ->
        contract = Map.put(optimization.contract, "visao", vision)

        optimization
        |> Optimization.changeset(%{contract: contract})
        |> Repo.update!()
        |> resume()
    end
  end

  @doc """
  Spends one more consult on a fresh set of directions.

  The same step runs again with a new consult, so no position moves and the
  declined sets stay attached to the run by `optimization_id` — what the owner
  turned down is part of the record.
  """
  @spec ask_again(Optimization.t()) :: {:ok, Optimization.t()} | {:error, Error.t()}
  def ask_again(%Optimization{} = optimization) do
    case Enum.find(optimization.steps, &vision_step?/1) do
      nil ->
        {:error, Error.new(:no_vision_step, "Essa rodada não tem etapa de visões.")}

      step ->
        {:ok, _running} = transition(optimization, :running)
        {:ok, _step} = run_step(step)

        fetch(optimization.id)
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

    Decks.import_from_text(list_to_text(list, current_commanders(optimization)), %{
      name: "#{deck.name}#{suffix}",
      source: :paste
    })
  end

  @doc """
  What actually changed between the original list and the final one.

  A card added by one stage and cut by a later one nets to nothing, so it does
  not belong on a list the owner reads to know what to buy.

  **The count matters, not just the name.** A mana stage that cuts two basic
  Mountains made two changes, and collapsing them to one row reported thirteen
  cuts against fourteen adds on a run that stayed at exactly 100 cards — the
  arithmetic looked broken when only the display was. Basic lands are the one
  card a deck holds several of, and they are precisely what a mana stage cuts
  in multiples. Each surviving copy keeps its own stage's reason: the two
  Mountains were cut for related but different arguments, and the second one is
  not an echo of the first.
  """
  @spec consolidated_diff(Optimization.t()) :: [map()]
  def consolidated_diff(%Optimization{} = optimization) do
    optimization.steps
    |> Enum.flat_map(& &1.applied)
    |> Enum.group_by(& &1["card"])
    |> Enum.flat_map(fn {_card, touches} -> surviving(touches) end)
    |> Enum.sort_by(&{&1["action"], &1["card"]})
  end

  defp surviving(touches) do
    {adds, cuts} = Enum.split_with(touches, &(&1["action"] == "add"))
    net = length(adds) - length(cuts)

    cond do
      net > 0 -> Enum.take(adds, -net)
      net < 0 -> Enum.take(cuts, net)
      true -> []
    end
  end

  @doc """
  What this run says to buy: its net adds, minus whatever the real deck
  already holds.

  The diff answers "what changed in the sandbox". This answers the question
  the owner actually walks into a shop with, and they are not the same list:
  a card he applied to the real deck after reading the run is a change he
  already made, not a card he still needs. Subtracting them is the difference
  between a shopping list and a changelog.

  A card with no known price is listed and left out of the total. Guessing what
  it costs to make the arithmetic tidy would be exactly the invention this app
  refuses everywhere else.
  """
  @spec shopping_list(Optimization.t(), Deck.t()) :: %{
          cards: [map()],
          total_usd: Decimal.t(),
          unpriced: non_neg_integer()
        }
  def shopping_list(%Optimization{} = optimization, %Deck{} = deck) do
    owned =
      deck
      |> Decks.list_deck_cards()
      |> MapSet.new(&Name.normalize(&1.card.name))

    cards =
      optimization
      |> consolidated_diff()
      |> Enum.filter(&(&1["action"] == "add"))
      |> Enum.reject(&MapSet.member?(owned, Name.normalize(&1["card"])))
      |> Enum.map(&priced_entry/1)

    # Totalled in dollars and converted once, like every other sum here: the
    # rate is applied at the edge, so the number on screen rounds the same way
    # the prices beside it do.
    %{
      cards: cards,
      total_usd:
        Enum.reduce(cards, Decimal.new(0), &Decimal.add(&2, &1.price_usd || Decimal.new(0))),
      unpriced: Enum.count(cards, &is_nil(&1.price_usd))
    }
  end

  defp priced_entry(change) do
    card = Cards.get_by_name(change["card"])

    %{
      name: change["card"],
      reason: change["reason"],
      card: card,
      price_usd: card && card.price_usd,
      rank: card && card.edhrec_rank
    }
  end

  @doc """
  The shopping list as plain text, one card per line.

  The format a shop's bulk-add box reads, which is the same one this app's own
  importer reads.
  """
  @spec shopping_list_text(Optimization.t(), Deck.t()) :: String.t()
  def shopping_list_text(%Optimization{} = optimization, %Deck{} = deck) do
    case shopping_list(optimization, deck).cards do
      [] -> ""
      cards -> Enum.map_join(cards, "\n", &"1 #{&1.name}") <> "\n"
    end
  end

  @doc """
  The sandbox's commanders as they stand now.

  `optimization.commanders` stays frozen as the original — the before/after
  diff is measured against it — so a vision's commander swap lives in the
  contract and is derived here. One source of truth, never two stored copies
  that can drift.

  A commander the engine refused is not applied: the refusal was already
  printed on the vision card, and a refused swap quietly taking effect would
  be worse than the swap being impossible.
  """
  @spec current_commanders(Optimization.t()) :: [String.t()]
  def current_commanders(%Optimization{} = optimization) do
    with vision when is_map(vision) <- chosen_vision(optimization),
         name when is_binary(name) and name != "" <- vision["comandante"],
         card when not is_nil(card) <- Cards.get_by_name(name),
         nil <- Visions.commander_problem(card, identity_of(optimization)) do
      [card.name]
    else
      _keep_the_original -> optimization.commanders
    end
  end

  defp identity_of(%Optimization{} = optimization) do
    {:ok, deck} = Decks.fetch_deck(optimization.deck_id)

    deck.color_identity
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
    snapshot = snapshot_for(step.list_before, current_commanders(optimization), deck)

    {:ok, consult} =
      Consults.request(deck, String.to_existing_atom(step.lens),
        snapshot: snapshot,
        optimization_id: optimization.id,
        model: step.model || optimization.contract["model"],
        against: optimization.contract["matchups"],
        optimization: %{
          contract: optimization.contract,
          changelog: changelog(optimization, step),
          stage_kind: step.kind,
          card_count: sandbox_size(optimization, step.list_before)
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
  Recomputes one stage with a different model, rewinding everything after it.

  Stage N's answer is the input to N+1, so recomputing N while keeping the
  stages that were built on it would leave the sandbox describing a history
  that never happened. Everything after N goes back to `:pending`; its
  `list_before` is derived and costs nothing to rebuild.

  The discarded consults are **not** deleted — they stay attached to the run by
  `optimization_id`, and reading what the cheaper model said beside the better
  one is most of why this exists.

  Refused while a consult is in flight: redoing under a live stage would race
  the answer that is already on its way.
  """
  @spec redo_step(Optimization.t(), String.t(), String.t()) ::
          {:ok, Optimization.t()} | {:error, Error.t()}
  def redo_step(%Optimization{} = optimization, step_id, model) do
    step = Enum.find(optimization.steps, &(&1.id == step_id))

    cond do
      is_nil(step) ->
        {:error, Error.new(:step_not_found, "Não achei essa etapa nesta rodada.")}

      Enum.any?(optimization.steps, &(&1.status == :running)) ->
        {:error,
         Error.new(
           :stage_in_flight,
           "Tem uma etapa consultando agora. Espere ela chegar antes de refazer outra."
         )}

      Consults.model_rank(model) < Consults.model_rank(Settings.model_floor()) ->
        {:error,
         Error.new(
           :model_below_floor,
           "#{model} está abaixo do seu piso (#{Settings.model_floor()}) para mudar cartas."
         )}

      true ->
        rewind_to(optimization, step, model)
    end
  end

  defp rewind_to(optimization, step, model) do
    Enum.each(optimization.steps, fn other ->
      if other.position > step.position do
        other
        |> OptimizationStep.changeset(%{
          status: :pending,
          applied: [],
          rejected: [],
          consult_id: nil,
          list_before: nil
        })
        |> Repo.update!()
      end
    end)

    optimization
    |> Optimization.changeset(%{status: :running, outcome: nil, finished_at: nil})
    |> Repo.update!()

    {:ok, _step} =
      step
      |> OptimizationStep.changeset(%{model: model, status: :pending})
      |> Repo.update!()
      |> run_step()

    fetch(optimization.id)
  end

  @doc """
  What the run's applied entries have cost so far, in reais.

  The run page already shows this as **Entradas**; the budget guard compares
  against the same number the owner is reading.
  """
  @spec spent_so_far(Optimization.t()) :: Decimal.t()
  def spent_so_far(%Optimization{} = optimization) do
    optimization.steps
    |> Enum.flat_map(& &1.applied)
    |> Enum.filter(&(&1["action"] == "add"))
    |> Enum.map(&Cards.get_by_name(&1["card"]))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(& &1.price_usd)
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(Decimal.new(0), fn usd, total ->
      Decimal.add(total, Deckex.Money.to_brl(usd) || Decimal.new(0))
    end)
  end

  @doc "How many stages a redo of this one would discard."
  @spec stages_after(Optimization.t(), String.t()) :: non_neg_integer()
  def stages_after(%Optimization{} = optimization, step_id) do
    case Enum.find(optimization.steps, &(&1.id == step_id)) do
      nil ->
        0

      step ->
        Enum.count(optimization.steps, &(&1.position > step.position and &1.status != :pending))
    end
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

    if vision_step?(done) do
      {:ok, _waiting} = transition(refreshed, :awaiting_choice)
    else
      settle(refreshed, done)
    end

    {:ok, final} = fetch(optimization.id)
    Events.broadcast_optimization(final)

    :ok
  end

  # A vision answer proposes no changes and picks no direction — the owner
  # does that. The pipeline stops here rather than spending the next stage
  # against a direction nobody chose.
  defp vision_step?(%OptimizationStep{lens: "visao"}), do: true
  defp vision_step?(_step), do: false

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
    # The audit reads only the local catalogue, and the fetch at answer time
    # is best-effort: the first real run had a transient Scryfall failure
    # there and rejected a perfectly real card as "não resolvida". This is a
    # worker, not a page render — resolution gets one more honest attempt
    # before the verdict.
    Consults.refresh_catalogue(consult)

    snapshot = snapshot_for(step.list_before, current_commanders(optimization), deck)
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
        budget_policy: Budget.from_contract(optimization.contract["forma_do_gasto"]),
        # The count the stage started from. Without it the engine has no idea
        # which direction is "further from 100", and the balance guard is off.
        card_count: sandbox_size(optimization, step.list_before),
        balance_mode: if(step.kind == :balance, do: :closing, else: :stage),
        history: history(optimization, step),
        keep: (optimization.contract["keep"] || []) ++ current_commanders(optimization),
        bracket_max: optimization.contract["bracket_max"],
        avoid: Salt.avoided(optimization.contract["salt"]),
        budget: optimization.contract["orcamento_total"],
        spent: spent_so_far(optimization)
      )

    split(suggestions, audit)
  end

  defp split(suggestions, audit) do
    {clean, dirty} =
      Enum.split_with(suggestions, fn suggestion ->
        suggestion.resolved? and
          not Map.has_key?(audit.problems, {suggestion.action, suggestion.name})
      end)

    # The engine's note rides along with the change it is about. A run that
    # spent one of the two exception slots on a seven-hundred-real card said so
    # once, in a fold that was thrown away the moment the stage was recorded —
    # and the owner reading the run a week later had no way to know.
    applied =
      Enum.map(clean, fn s ->
        %{
          "action" => to_string(s.action),
          "card" => s.name,
          "reason" => s.reason,
          "note" => audit.notes |> Map.get({s.action, s.name}, []) |> List.first()
        }
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
        close_or_finish(optimization, done_step)

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

  # A run may not end on a list that cannot go on a table. The ordinary stages
  # walk the count back a card or two at a time — that is the owner's own
  # preference, and it means every card that leaves was the worst card left
  # when it left — but walking slowly does not guarantee arriving. Whatever gap
  # is still open when the recipe runs out becomes one more stage whose only
  # job is closing it.
  #
  # Bounded, because the alternative is a run that buys consults forever. After
  # `@max_balance_stages` the run finishes and says plainly that it did not get
  # there, which is the honest end — inventing the last three cuts ourselves
  # would be the engine choosing cards, and choosing cards is the one thing it
  # does not do.
  @max_balance_stages 2

  # And a gap one answer can honestly close. "Cut exactly three" is a real
  # instruction; "add exactly ninety-five" is not a deck being finished, it is
  # a deck being invented, and a stage asked for it would return filler by
  # definition. Past this the run stops and says where it landed — the ordinary
  # stages have eight chances to walk a large gap down into reach first.
  @max_closable_gap 10

  defp close_or_finish(optimization, done_step) do
    count = sandbox_size(optimization, current_list(optimization))
    spent = Enum.count(optimization.steps, &(&1.kind == :balance))

    if closable?(count, spent) do
      optimization |> append_balance_step(done_step, count) |> run_step()

      :ok
    else
      finish(optimization)
    end
  end

  defp closable?(count, stages_spent) do
    gap = abs(Balance.target() - count)

    gap > 0 and gap <= @max_closable_gap and stages_spent < @max_balance_stages
  end

  defp append_balance_step(optimization, done_step, count) do
    gap = abs(Balance.target() - count)
    verb = if count > Balance.target(), do: "Cortar", else: "Completar"

    %OptimizationStep{}
    |> OptimizationStep.changeset(%{
      optimization_id: optimization.id,
      position: length(optimization.steps) + 1,
      kind: :balance,
      lens: "balanco",
      label: "#{verb} #{gap} para fechar 100",
      status: :pending,
      list_before: list_after(done_step)
    })
    |> Repo.insert!()
  end

  defp finish(optimization) do
    # Re-read: the skip that led here was persisted after this struct was
    # loaded, and the outcome depends on seeing it.
    {:ok, optimization} = fetch(optimization.id)

    outcome = outcome_for(optimization)

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

  # The count comes first: a run that improved every measurement and left the
  # list at 103 cards did not finish the job, and an outcome of "completo" on
  # an illegal deck is the app lying to the person who has to shuffle it.
  defp outcome_for(optimization) do
    count = sandbox_size(optimization, current_list(optimization))

    cond do
      count != Balance.target() ->
        "fechou em #{count} cartas, não em #{Balance.target()}"

      match?(%{kind: :checkpoint, status: :skipped}, List.last(optimization.steps)) ->
        "estabilizou"

      true ->
        "completo"
    end
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
    Decks.decklist_text(commanders, Enum.map(list, &{&1["quantity"], &1["name"]}))
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

  @doc """
  How many cards a sandbox list holds — quantities summed, not rows.

  The **main list only**. Commanders live in their own field, so this is not
  the number the hundred-card rule is about: use `sandbox_size/2` for that.
  """
  @spec card_count([map()]) :: non_neg_integer()
  def card_count(list) when is_list(list) do
    list |> Enum.map(&(&1["quantity"] || 0)) |> Enum.sum()
  end

  @doc """
  The size of the deck this sandbox would produce — commanders included.

  The one number the hundred-card rule is about, and for a long time nothing
  computed it. The sandbox list is the main board; commanders are a separate
  field, so every "Cartas 100/100" the run page printed meant a deck of 101
  cards, and a pipeline driving the main list to 100 was driving the deck to
  one card over legal. Found on the reference deck, which finished a whole
  eight-stage run at 101.
  """
  @spec sandbox_size(Optimization.t(), [map()]) :: non_neg_integer()
  def sandbox_size(%Optimization{} = optimization, list) do
    card_count(list) + length(current_commanders(optimization))
  end

  defdelegate list_for_deck(deck_id), to: OptimizationQuery

  defdelegate running_for_deck(deck_id), to: OptimizationQuery
end
