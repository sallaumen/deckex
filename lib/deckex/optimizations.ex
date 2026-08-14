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
          |> Enum.each(fn {spec, position} ->
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
          end)

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

  # Replaced by the real pipeline runner in Task 5 of the plan; the lifecycle
  # is testable without a consult in flight.
  defp run_step(%OptimizationStep{} = step), do: {:ok, step}

  defp fork_list(optimization, nil), do: current_list(optimization)
  defp fork_list(_optimization, step), do: list_after(step)

  defp resumable_step(%Optimization{steps: steps}) do
    Enum.find(steps, &(&1.status in [:pending, :failed]))
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
