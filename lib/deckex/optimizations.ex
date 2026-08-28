defmodule Deckex.Optimizations do
  @moduledoc """
  The Otimizador: three AI stages over a sandbox copy of a deck.

  **Plan, execute, judge.** One stage reads the deck and decides what the round
  is for; one stage makes every change against that plan; one stage judges the
  result with the engine's before-and-after in hand and is the only one allowed
  to correct it. The engine audits every answer and applies the clean changes
  **to the sandbox, never to the real deck**.

  The earlier design divided the work by lens instead — mana, curve,
  interaction, consistency, plus checkpoints to reconcile them — and that is
  what made the stages contradict each other: each had a partial view and a
  partial mandate. A measured run applied 44 changes and undid 16, and the
  reverts were correct; the later stages were spending their budget fixing the
  earlier ones. See `recipe/2`.
  """

  alias Deckex.Analysis
  alias Deckex.Analysis.Bracket
  alias Deckex.Analysis.CardEntry
  alias Deckex.Analysis.DeckSnapshot
  alias Deckex.Analysis.Finding
  alias Deckex.Analysis.Report
  alias Deckex.Analysis.ReportDiff
  alias Deckex.Budget
  alias Deckex.Cards
  alias Deckex.Cards.Name
  alias Deckex.Consults
  alias Deckex.Consults.Audit
  alias Deckex.Consults.ConsultQuery
  alias Deckex.Consults.Suggestion
  alias Deckex.Consults.Suggestions
  alias Deckex.Consults.Vacancies
  alias Deckex.Consults.Vacancy
  alias Deckex.Consults.Visions
  alias Deckex.Decks
  alias Deckex.Decks.Deck
  alias Deckex.Decks.DeckQuery
  alias Deckex.Decks.DeckVersion
  alias Deckex.Decks.Versions
  alias Deckex.Error
  alias Deckex.Events
  alias Deckex.Optimizations.Balance
  alias Deckex.Optimizations.Curation
  alias Deckex.Optimizations.Mark
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
    standing = Decks.standing_rules(deck)

    %{
      "bracket_max" => Bracket.floor(Decks.snapshot(deck)).floor,
      "ceilings" => %{"card" => ceilings.card, "land" => ceilings.land},
      # Frozen at launch, like every other rule here: changing Ajustes halfway
      # through must not quietly move the line a finished stage was judged by.
      "forma_do_gasto" => Budget.to_contract(Budget.policy()),
      # The deck's own standing decisions, not an empty box he refills every
      # time. He locked these cards once, on the screen made for it; a launch
      # that started from nothing would make him remember them under pressure,
      # and forgetting is how a combo piece gets cut.
      "keep" => standing["keep"],
      "wanted" => standing["wanted"],
      "matchups" => ["aggro rápido de criaturas", "controle pesado de counters"],
      "notes" => "",
      # Every stage of an optimization proposes cutting and adding cards, so
      # the floor is the default here rather than the global model — the owner
      # should not have to remember to raise it before spending ten consults.
      "model" => Consults.at_least(Settings.model(), Settings.model_floor())
    }
  end

  @doc """
  The stages, as data. Three of them, and each answers a different *kind* of
  question.

  The old recipe had nine or ten, divided by lens — mana, curve, interaction,
  consistency, then checkpoints to clean up after them. That division is what
  made them contradict: every stage had a partial view and a partial mandate,
  so each optimised its own number while the next one disagreed. A measured run
  applied 44 changes and undid 16 of them, and the reverts were *right* — the
  later stages were spending their budget correcting the earlier ones.

  So the division is by **phase of work** instead:

    1. `:plano` reads everything and changes nothing. It writes the diagnosis,
       the priority order, and what this round is going to do — and it rewrites
       the deck's dossier while it is there, which is why there is no scout
       stage any more. Everything after it is bound to this document; it is the
       through-line the old recipe never had.
    2. `:execucao` makes **every** change, against that plan. One author means
       an internally consistent answer by construction, and there is no later
       lens stage left to revert it.
    3. `:critico` judges the result with both measured reports in hand, and is
       the only stage that may correct it.

  `:livre` is one stage and `:revisao` is one stage; neither is automatic, so
  neither counts against the three.
  """
  @spec recipe(Deck.t()) :: [map()]
  def recipe(%Deck{} = deck), do: recipe(deck, :refine)

  @doc """
  The stages for one mode.

  `:reimagine` replaces the plan with the owner's chosen direction — a vision
  he picked IS the plan — and rebuilds against it before the same critic reads
  the result.

  `:curadoria` keeps the plan and replaces the *executor*: the second stage
  lays out vacancies with candidates and the owner fills them. Same three
  consults, same guards; the act of choosing is his.
  """
  @spec recipe(Deck.t(), :livre | :refine | :reimagine | :curadoria) :: [map()]
  def recipe(%Deck{} = _deck, :livre) do
    [%{"kind" => "livre", "lens" => "livre", "label" => "Ajuste direto"}]
  end

  def recipe(%Deck{} = _deck, :refine) do
    [
      %{"kind" => "plano", "lens" => "plano", "label" => "Plano"},
      %{"kind" => "execucao", "lens" => "execucao", "label" => "Execução"},
      %{"kind" => "critico", "lens" => "critico", "label" => "Crítico"}
    ]
  end

  # The owner executes. `:plano` is reused verbatim — it reads everything and
  # proposes nothing, which is exactly what a menu needs behind it — and the
  # stage that would have made the changes becomes a stage that lays out
  # vacancies for him to fill. The critic still runs, and in this mode its
  # answer is offered rather than applied: see `gate_step?/2`.
  def recipe(%Deck{} = _deck, :curadoria) do
    [
      %{"kind" => "plano", "lens" => "plano", "label" => "Plano"},
      %{"kind" => "cardapio", "lens" => "cardapio", "label" => "Cardápio"},
      %{"kind" => "critico", "lens" => "critico", "label" => "Crítico"}
    ]
  end

  def recipe(%Deck{} = _deck, :reimagine) do
    [
      %{"kind" => "visao", "lens" => "visao", "label" => "Visões"},
      %{"kind" => "reconstruction", "lens" => "reconstrucao", "label" => "Reconstrução"},
      %{"kind" => "critico", "lens" => "critico", "label" => "Crítico"}
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

    contract =
      default_contract(deck) |> Map.merge(contract_attrs) |> merge_standing_rules(deck)

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

  # The launch form's protected list is *additional*. A card the owner locked
  # on the Cartas screen is locked in every round of this deck, and a run that
  # dropped it because a textarea came back empty would be the exact failure
  # the screen exists to prevent — he watched a stage cut a combo piece once
  # and had to notice it himself.
  #
  # Merged here so the frozen contract records what was protected at launch;
  # the audit reads the locks live as well, so one written mid-run counts too.
  defp merge_standing_rules(contract, deck) do
    standing = Decks.standing_rules(deck)

    contract
    |> Map.put("keep", Enum.uniq(standing["keep"] ++ (contract["keep"] || [])))
    |> Map.put("wanted", Enum.uniq(standing["wanted"] ++ (contract["wanted"] || [])))
  end

  # Nobody supervises a pipeline mid-flight, so the floor is a refusal here
  # rather than the mark a single consult gets on the deck page.
  defp launch(deck, mode, contract, recipe_override) do
    %{list: list, commanders: commanders} = starting_point(deck, contract["from_version"])
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

  @doc """
  Stops advancing after the consult in flight lands. Paid work is kept.

  A run waiting at a gate is already stopped, and pausing it would lose the one
  fact that matters about it — that it is waiting on its owner. Resuming from
  `:paused` runs the next pending stage, which for a board still being filled
  in would be the critic reading choices nobody had finished making.
  """
  @spec pause(Optimization.t()) :: {:ok, Optimization.t()}
  def pause(%Optimization{status: :awaiting_choice} = optimization), do: {:ok, optimization}
  def pause(%Optimization{} = optimization), do: transition(optimization, :paused)

  @doc "Resumes a paused run: the next pending (or failed) stage runs again."
  @spec resume(Optimization.t()) :: {:ok, Optimization.t()}
  def resume(%Optimization{status: :awaiting_choice} = optimization) do
    case open_gate(optimization) do
      %OptimizationStep{kind: :visao} ->
        if chosen_vision(optimization) do
          do_resume(optimization)
        else
          {:error,
           Error.new(
             :vision_not_chosen,
             "Essa rodada está esperando: escolha uma direção para continuar."
           )}
        end

      %OptimizationStep{} ->
        {:error,
         Error.new(
           :board_open,
           "Essa rodada está esperando você na Bancada: escolha as cartas e feche a rodada."
         )}

      nil ->
        do_resume(optimization)
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
    case Enum.find(optimization.steps, &(&1.kind == :visao)) do
      nil ->
        {:error, Error.new(:no_vision_step, "Essa rodada não tem etapa de visões.")}

      step ->
        {:ok, _running} = transition(optimization, :running)
        {:ok, _step} = run_step(step)

        fetch(optimization.id)
    end
  end

  @doc """
  Flags a card while the run is going, or unflags it.

  Marking is a toggle and costs nothing: it happens at the speed of reading,
  in the middle of a stage, when something catches the eye. What the card is
  worth saying about comes later.
  """
  @spec toggle_mark(Optimization.t(), String.t(), atom() | nil) :: {:ok, :marked | :unmarked}
  def toggle_mark(%Optimization{} = optimization, card_name, action \\ nil) do
    case Repo.get_by(Mark, optimization_id: optimization.id, card_name: card_name) do
      nil ->
        %Mark{}
        |> Mark.changeset(%{
          optimization_id: optimization.id,
          card_name: card_name,
          action: action
        })
        |> Repo.insert!()

        {:ok, :marked}

      mark ->
        Repo.delete!(mark)

        {:ok, :unmarked}
    end
  end

  @doc "Writes (or clears) what the owner has to say about a marked card."
  @spec note_mark(Optimization.t(), String.t(), String.t()) :: {:ok, Mark.t()} | :error
  def note_mark(%Optimization{} = optimization, card_name, note) do
    case Repo.get_by(Mark, optimization_id: optimization.id, card_name: card_name) do
      nil -> :error
      mark -> {:ok, mark |> Mark.changeset(%{note: note}) |> Repo.update!()}
    end
  end

  @doc "Every card flagged in this run, in the order they were flagged."
  @spec marks(Optimization.t()) :: [Mark.t()]
  def marks(%Optimization{id: id}), do: OptimizationQuery.marks_for(id)

  @doc """
  Runs one last stage against what the owner said.

  The pipeline is arithmetic and a model's reading; the owner is the person
  who plays the deck. When he says a card was cut on a misreading — Jaheira
  turns Food into creatures that tap for mana, she does not "only make mana
  for creature tokens" — he is right and the run is wrong, and there was
  nowhere to say so until now.

  The stage is appended like any other, so everything downstream applies to it
  unchanged: the engine still audits, the budget still holds, and the count
  still has to land on a hundred.
  """
  # Bounded like the closing stages, and for the same reason: every one is a
  # paid consult. Three rounds of "não é bem isso" is a conversation; the
  # fourth is a new optimization wearing the old one's clothes.
  @max_reviews 3

  @spec review(Optimization.t(), String.t()) :: {:ok, Optimization.t()} | {:error, Error.t()}
  def review(%Optimization{} = optimization, general_note \\ "") do
    said = Enum.filter(marks(optimization), &Mark.said?/1)
    general = String.trim(general_note || "")

    cond do
      optimization.status != :done ->
        {:error,
         Error.new(:optimization_not_done, "A revisão é a última etapa: espere a rodada acabar.")}

      reviews_spent(optimization) >= @max_reviews ->
        {:error,
         Error.new(
           :review_limit_reached,
           "Esta rodada já teve #{@max_reviews} revisões. Aplique o que ficou bom e comece outra — " <>
             "cada revisão é uma consulta paga, e a quarta discussão sobre a mesma lista não é mais sobre a lista."
         )}

      said == [] and general == "" ->
        {:error,
         Error.new(
           :nothing_to_review,
           "Escreva o que você achou — de alguma carta marcada ou do conjunto. Sem isso não há o que revisar."
         )}

      true ->
        # Said once, kept forever: the correction is a fact about the deck, not
        # about this half-hour. Every future briefing carries it, and he never
        # has to explain the same card twice.
        remember(optimization, said)

        append_review_step(optimization, general)
        {:ok, resumed} = fetch(optimization.id)

        do_resume(resumed)
    end
  end

  # Only in the review stage, and only the cards he wrote about: his word
  # outranks the churn guard for those and nothing else.
  defp exempt_for(optimization, %OptimizationStep{kind: :revisao}) do
    optimization |> marks() |> Enum.filter(&Mark.said?/1) |> Enum.map(& &1.card_name)
  end

  defp exempt_for(_optimization, _other_stage), do: []

  @doc "How many review stages this run has already spent."
  @spec reviews_spent(Optimization.t()) :: non_neg_integer()
  def reviews_spent(%Optimization{steps: steps}), do: Enum.count(steps, &(&1.kind == :revisao))

  @doc "Whether another review is still allowed on this run."
  @spec reviewable?(Optimization.t()) :: boolean()
  def reviewable?(%Optimization{} = optimization), do: reviews_spent(optimization) < @max_reviews

  defp remember(optimization, said) do
    {:ok, deck} = Decks.fetch_deck(optimization.deck_id)

    Enum.each(said, &Decks.put_card_note(deck, &1.card_name, &1.note, :review))
  end

  defp append_review_step(optimization, general) do
    %OptimizationStep{}
    |> OptimizationStep.changeset(%{
      optimization_id: optimization.id,
      position: length(optimization.steps) + 1,
      kind: :revisao,
      lens: "revisao",
      label: "Revisão do dono",
      status: :pending,
      list_before: current_list(optimization)
    })
    |> Repo.insert!()

    optimization
    |> Optimization.changeset(%{
      contract: Map.put(optimization.contract, "revisao_geral", general)
    })
    |> Repo.update!()
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
  Where a run starts: a numbered version, or the deck as it stands.

  A run is an argument about a list, so which list it argued about is part of
  the record — an owner comparing two runs a week later needs to know one
  started from v3 and the other from v7, or the comparison is between two
  different decks.

  A version number nobody can find falls back to the working state rather than
  refusing: the deck on the table is always a legitimate starting point.
  """
  @spec starting_point(Deck.t(), integer() | nil) :: %{list: [map()], commanders: [String.t()]}
  def starting_point(%Deck{} = deck, nil), do: list_from_deck(deck)

  def starting_point(%Deck{} = deck, number) do
    case Versions.fetch(deck, number) do
      {:ok, version} ->
        %{list: DeckVersion.rows(version), commanders: version.commanders}

      {:error, _gone} ->
        list_from_deck(deck)
    end
  end

  @doc """
  Applies a run to the deck it came from, as that deck's next version.

  The sandbox stops being a sandbox here: the list becomes the deck's cards and
  the same act writes the version that says what it did. The changelog carried
  into the version is the consolidated one — a card added by one stage and cut
  by a later one nets to nothing, and the history reads as what happened to the
  deck rather than as a transcript of the run.

  From one stage, or from the run's latest state when no stage is given.
  """
  @spec apply_to_deck(Optimization.t(), OptimizationStep.t() | nil) ::
          {:ok, Deck.t()} | {:error, Error.t()}
  def apply_to_deck(%Optimization{} = optimization, step \\ nil) do
    {:ok, deck} = Decks.fetch_deck(optimization.deck_id)
    rows = Enum.map(fork_list(optimization, step), &Map.take(&1, ["name", "quantity"]))

    case Versions.apply_list(deck, current_commanders(optimization), rows,
           origin: :optimization,
           optimization_id: optimization.id,
           label: version_label(optimization, step),
           changes: %{"applied" => consolidated_diff(optimization, step)}
         ) do
      {:ok, applied, _version} -> {:ok, applied}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp version_label(optimization, nil), do: "Otimização de #{model_of(optimization)}"

  defp version_label(optimization, step),
    do: "Otimização de #{model_of(optimization)} — até a etapa #{step.position}"

  defp model_of(%Optimization{contract: contract}), do: contract["model"]

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
  @spec consolidated_diff(Optimization.t(), OptimizationStep.t() | nil) :: [map()]
  def consolidated_diff(%Optimization{} = optimization, step \\ nil) do
    optimization.steps
    |> up_to(step)
    |> Enum.flat_map(& &1.applied)
    |> Enum.group_by(& &1["card"])
    |> Enum.flat_map(fn {_card, touches} -> surviving(touches) end)
    |> Enum.sort_by(&{&1["action"], &1["card"]})
  end

  defp up_to(steps, nil), do: steps

  defp up_to(steps, %OptimizationStep{position: position}),
    do: Enum.filter(steps, &(&1.position <= position))

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
          # The through-line, carried verbatim rather than summarised, and the
          # engine's own before/after so the critic answers to a measurement
          # instead of to its own impression.
          plan: plan_of(optimization),
          effect: if(step.kind == :critico, do: effect(optimization)),
          card_count: sandbox_size(optimization, step.list_before),
          # Only the ones he actually wrote on: a card marked and left without
          # a word is a card he read twice and had nothing to say about.
          marks: Enum.filter(marks(optimization), &Mark.said?/1)
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
          list_before: nil,
          selections: %{}
        })
        |> Repo.update!()
      end
    end)

    optimization
    |> Optimization.changeset(%{status: :running, outcome: nil, finished_at: nil})
    |> Repo.update!()

    # The board's keys are positions in an answer that is about to be replaced.
    # Carrying his old choices into a new cardápio would map "the second
    # candidate of vacancy four" onto whatever card happens to land there —
    # a selection he never made, on a card he never saw.
    {:ok, _step} =
      step
      |> OptimizationStep.changeset(%{model: model, status: :pending, selections: %{}})
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

    {applied, rejected} =
      if gate_step?(step, optimization) do
        # A gate proposes and stops. Its cards still have to reach the
        # catalogue, though — the board shows art, a price and a play rate
        # beside every candidate, and a page render may never fetch. This is a
        # worker, which always could.
        Consults.refresh_catalogue(consult)

        {[], []}
      else
        judge(consult, step, optimization, deck)
      end

    done =
      step
      |> OptimizationStep.changeset(%{status: :done, applied: applied, rejected: rejected})
      |> Repo.update!()

    {:ok, refreshed} = fetch(optimization.id)

    if gate_open?(done, optimization, consult) do
      {:ok, _waiting} = transition(refreshed, :awaiting_choice)
    else
      settle(refreshed, done)
    end

    {:ok, final} = fetch(optimization.id)
    Events.broadcast_optimization(final)

    :ok
  end

  @doc """
  Whether this stage hands the run to the owner instead of advancing it.

  Three of them, one reason. A vision answer picks no direction and the next
  stage would be built against a direction nobody chose. A cardápio answer is a
  menu, and a menu that serves itself is not a menu. And in `:curadoria` the
  **critic** is a gate too: the mode exists so the last word is his, and a
  critic that silently corrected his curation would take it straight back.
  """
  @spec gate_step?(OptimizationStep.t(), Optimization.t()) :: boolean()
  def gate_step?(%OptimizationStep{kind: :visao}, _optimization), do: true
  def gate_step?(%OptimizationStep{kind: :cardapio}, _optimization), do: true

  def gate_step?(%OptimizationStep{kind: :critico}, %Optimization{mode: :curadoria}), do: true

  def gate_step?(_step, _optimization), do: false

  # A gate with nothing on it is not a gate. A critic that found nothing to
  # correct has said the useful thing already, and parking the run on an empty
  # board would make him click through a screen to be told so.
  defp gate_open?(%OptimizationStep{kind: :visao} = step, optimization, _consult) do
    gate_step?(step, optimization)
  end

  defp gate_open?(step, optimization, consult) do
    gate_step?(step, optimization) and
      Vacancies.for_consult(consult, optimization.contract) != []
  end

  @doc """
  The stage waiting on the owner right now, or nil.

  The **last** completed gate, not the first: a `:curadoria` run passes through
  two of them, and after the cardápio is closed that step is still done and
  still a gate. Where the run stopped is the only thing that says which board
  is open.
  """
  @spec open_gate(Optimization.t()) :: OptimizationStep.t() | nil
  def open_gate(%Optimization{status: :awaiting_choice} = optimization) do
    optimization.steps
    |> Enum.filter(&(&1.status == :done and gate_step?(&1, optimization)))
    |> List.last()
  end

  def open_gate(%Optimization{}), do: nil

  @doc """
  The vacancies the open gate is offering, joined to the catalogue.

  Read from the gate's own consult, so the board and the timeline can never
  disagree about what was proposed.
  """
  @spec vacancies(Optimization.t(), OptimizationStep.t()) :: [Vacancy.t()]
  def vacancies(%Optimization{}, %OptimizationStep{consult_id: nil}), do: []

  def vacancies(%Optimization{} = optimization, %OptimizationStep{} = step) do
    case Consults.fetch(step.consult_id) do
      {:ok, consult} -> Vacancies.for_consult(consult, optimization.contract)
      {:error, %Error{}} -> []
    end
  end

  @doc """
  Everything the board shows about the choices made so far.

  Recomputed on every click, and deliberately so: the whole point of the screen
  is that the deck's own numbers move because of something he just did. All of
  it is `Deckex.Analysis` and `Deckex.Consults.Audit`, both pure and both
  already built — this is the first place they run live rather than once, at
  the end of a stage.

  The balance guard is off here (`card_count: nil`). Mid-triage a net of +5
  means nothing, and the board's own gate — landing on exactly 100 — is
  stricter than the guard would be.
  """
  @spec preview(Optimization.t(), OptimizationStep.t(), Deck.t(), [Vacancy.t()]) :: map()
  def preview(
        %Optimization{} = optimization,
        %OptimizationStep{} = step,
        %Deck{} = deck,
        vacancies
      ) do
    suggestions = Curation.chosen(step, vacancies)
    audit = audit_for(optimization, step, deck, suggestions, card_count: nil, history: [])
    starting = sandbox_size(optimization, step.list_before)

    %{
      audit: audit,
      chosen: suggestions,
      starting: starting,
      count: Curation.count(step, vacancies, starting),
      undecided: Curation.undecided(step, vacancies),
      spend_usd: Suggestions.total_usd(suggestions),
      occupancy: occupancy_of(optimization, step, deck, suggestions),
      blocker: Curation.blocker(step, vacancies, starting)
    }
  end

  @doc """
  The engine's verdict on **every** candidate on the board, whether chosen or not.

  A board that only warned after the click would be warning too late: he has
  already committed the second of his two exception slots by the time the
  screen tells him the card is illegal in these colours.

  Only the per-card guards run here — identity, singleton, legality, the price
  ceiling, the bracket, the salt contract, the keep-list, and whether a cut is
  even in the list. The set-dependent ones are deliberately switched off: the
  quota is a property of the whole answer, and charging every candidate against
  it would refuse forty cards for a limit none of them had reached. Those
  surface in `preview/4`, on the cards he actually chose.

  Depends on nothing that changes while he works, so it is computed once.
  """
  @spec preflight(Optimization.t(), OptimizationStep.t(), Deck.t(), [Vacancy.t()]) :: Audit.t()
  def preflight(
        %Optimization{} = optimization,
        %OptimizationStep{} = step,
        %Deck{} = deck,
        vacancies
      ) do
    suggestions =
      vacancies
      |> Enum.flat_map(fn vacancy ->
        Enum.map(vacancy.candidatos, fn candidate ->
          %Suggestion{
            action: vacancy.action,
            name: candidate.name,
            reason: "",
            card: candidate.card,
            price_usd: candidate.price_usd,
            resolved?: candidate.resolved?
          }
        end)
      end)
      |> Enum.uniq_by(&{&1.action, &1.name})

    audit_for(optimization, step, deck, suggestions,
      card_count: nil,
      history: [],
      budget: nil,
      budget_policy:
        Budget.unlimited(Budget.from_contract(optimization.contract["forma_do_gasto"]))
    )
  end

  @doc """
  Why the engine would refuse this candidate, or what it wants him to know.

  `{:problem, sentence}` disables the card — it is the same refusal a model's
  answer would get. `{:note, sentence}` changes nothing and is shown anyway:
  spending one of two exception slots on a seven-hundred-real card is his
  decision to make, and he can only make it if somebody says so.
  """
  @spec verdict(Audit.t(), :cut | :add, String.t()) ::
          {:problem, String.t()} | {:note, String.t()} | nil
  def verdict(%Audit{} = audit, action, name) do
    cond do
      problem = audit.problems |> Map.get({action, name}, []) |> List.first() ->
        {:problem, problem}

      note = audit.notes |> Map.get({action, name}, []) |> List.first() ->
        {:note, note}

      true ->
        nil
    end
  end

  # How many of the owner's expensive slots this board would be using, counted
  # over the whole list rather than per card — the price rule is a count, and a
  # board that judged card by card would let three suggestions each be told
  # there was room for the last one.
  defp occupancy_of(optimization, step, deck, suggestions) do
    policy = Budget.from_contract(optimization.contract["forma_do_gasto"])
    snapshot = snapshot_for(step.list_before, current_commanders(optimization), deck)

    start = Budget.occupancy(snapshot.main ++ snapshot.commanders, policy)

    %{occupancy: Enum.reduce(suggestions, start, &charge(&1, &2, policy)), policy: policy}
  end

  defp charge(suggestion, occupancy, policy) do
    Budget.charge(
      occupancy,
      Budget.tier(suggestion.price_usd, policy),
      if(suggestion.action == :add, do: 1, else: -1)
    )
  end

  @doc """
  Records one decision on the board. A `nil` name is an explicit skip.

  One small write per click and no consult: the triage of thirty vacancies
  takes minutes, and losing it to a closed tab would be the kind of failure
  nobody forgives a screen for.
  """
  @spec select(OptimizationStep.t(), Vacancy.t(), String.t() | nil) ::
          {:ok, OptimizationStep.t()}
  def select(%OptimizationStep{} = step, %Vacancy{} = vacancy, name) do
    {:ok,
     step
     |> OptimizationStep.changeset(%{selections: Curation.put(step, vacancy, name)})
     |> Repo.update!()}
  end

  @doc "Puts one vacancy back to undecided."
  @spec unselect(OptimizationStep.t(), Vacancy.t()) :: {:ok, OptimizationStep.t()}
  def unselect(%OptimizationStep{} = step, %Vacancy{} = vacancy) do
    {:ok,
     step
     |> OptimizationStep.changeset(%{selections: Curation.clear(step, vacancy)})
     |> Repo.update!()}
  end

  @doc """
  Closes the board: audits what the owner chose and advances the run.

  His choices go through **the same** `audit_for`/`split` every stage's answer
  goes through, and are written to the step as `applied` and `rejected` in the
  same shape. From here the run is indistinguishable from any other one — the
  sandbox advances, the critic reads it, and the version records why each card
  moved.

  The flip-flop guard is handed an empty history on purpose: it exists to stop
  two models arguing in circles, and the party choosing here is not a model.
  """
  @spec commit(Optimization.t(), [Vacancy.t()]) :: {:ok, Optimization.t()} | {:error, Error.t()}
  def commit(%Optimization{id: id}, vacancies) do
    # Read fresh. The board is a session that lasts minutes and writes one
    # selection per click, so the copy the caller is holding was already stale
    # by the second click — auditing it would judge a board nobody assembled.
    {:ok, optimization} = fetch(id)

    with {:ok, step} <- committable_gate(optimization),
         :ok <- committable_board(optimization, step, vacancies) do
      {:ok, deck} = Decks.fetch_deck(optimization.deck_id)

      suggestions = Curation.chosen(step, vacancies)
      audit = audit_for(optimization, step, deck, suggestions, history: [])
      {applied, rejected} = split(suggestions, audit)

      step
      |> OptimizationStep.changeset(%{applied: applied, rejected: rejected})
      |> Repo.update!()

      {:ok, running} = transition(optimization, :running)
      {:ok, refreshed} = fetch(running.id)

      settle(refreshed, Enum.find(refreshed.steps, &(&1.id == step.id)))

      result = fetch(optimization.id)
      {:ok, final} = result
      Events.broadcast_optimization(final)

      result
    end
  end

  defp committable_gate(%Optimization{} = optimization) do
    case open_gate(optimization) do
      %OptimizationStep{kind: :visao} ->
        {:error, Error.new(:not_a_board, "Essa rodada está esperando uma direção, não cartas.")}

      %OptimizationStep{} = step ->
        {:ok, step}

      nil ->
        {:error, Error.new(:no_open_board, "Essa rodada não tem nenhuma bancada aberta.")}
    end
  end

  defp committable_board(optimization, step, vacancies) do
    starting = sandbox_size(optimization, step.list_before)

    case Curation.blocker(step, vacancies, starting) do
      nil -> :ok
      message -> {:error, Error.new(:board_not_closable, message)}
    end
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
    # The audit reads only the local catalogue, and the fetch at answer time
    # is best-effort: the first real run had a transient Scryfall failure
    # there and rejected a perfectly real card as "não resolvida". This is a
    # worker, not a page render — resolution gets one more honest attempt
    # before the verdict.
    Consults.refresh_catalogue(consult)

    suggestions = Suggestions.for_consult(consult)

    audit = audit_for(optimization, step, deck, suggestions)

    split(suggestions, audit)
  end

  @doc """
  The engine's verdict on a set of suggestions, in this run's own terms.

  One place assembles it, because the Bancada needs exactly the same verdict a
  stage gets — live, on every click — and a second assembly would drift from
  this one and start telling the owner a different story than the audit that
  actually decides.

  `card_count: nil` turns the balance guard off, which is what the board wants
  while he is still choosing: mid-triage the net is meaningless, and the board
  enforces landing on exactly 100 at commit, which is stricter than the guard.
  """
  @spec audit_for(Optimization.t(), OptimizationStep.t(), Deck.t(), [Suggestion.t()], keyword()) ::
          Audit.t()
  def audit_for(
        %Optimization{} = optimization,
        %OptimizationStep{} = step,
        %Deck{} = deck,
        suggestions,
        opts \\ []
      ) do
    snapshot = snapshot_for(step.list_before, current_commanders(optimization), deck)

    roles =
      suggestions
      |> Enum.filter(&(&1.resolved? and &1.action == :add))
      |> Enum.map(& &1.card.id)
      |> Cards.roles_by_card_ids()

    ceilings = %{
      card: optimization.contract["ceilings"]["card"],
      land: optimization.contract["ceilings"]["land"]
    }

    Audit.run(
      snapshot,
      suggestions,
      roles,
      Settings.baselines(),
      ceilings,
      budget_policy:
        Keyword.get_lazy(opts, :budget_policy, fn ->
          Budget.from_contract(optimization.contract["forma_do_gasto"])
        end),
      # The count the stage started from. Without it the engine has no idea
      # which direction is "further from 100", and the balance guard is off.
      card_count: Keyword.get(opts, :card_count, sandbox_size(optimization, step.list_before)),
      balance_mode: if(step.kind == :balance, do: :closing, else: :stage),
      # The flip-flop guard exists to stop two models arguing in circles, and
      # a person with new information is not churn — the law the review stage
      # already states. On the Bancada the choices are his, so the caller
      # hands it an empty history.
      history: Keyword.get(opts, :history, history(optimization, step)),
      exempt: exempt_for(optimization, step),
      # Read live, exactly like the commanders beside it. The contract froze
      # what he asked for at launch; a card he locks at stage four — usually
      # because he just watched a stage try to cut it — is protected from
      # stage five, not from the next run. A rule the owner states while
      # watching is the whole reason he watches.
      keep:
        Enum.uniq(
          (optimization.contract["keep"] || []) ++
            Decks.locked_cards(deck) ++ current_commanders(optimization)
        ),
      bracket_max: optimization.contract["bracket_max"],
      avoid: Salt.avoided(optimization.contract["salt"]),
      budget: Keyword.get(opts, :budget, optimization.contract["orcamento_total"]),
      spent: spent_so_far(optimization)
    )
  end

  @doc "Sorts audited suggestions into what the engine took and what it refused."
  @spec split([Suggestion.t()], Audit.t()) :: {[map()], [map()]}
  def split(suggestions, audit) do
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

  defp next_runnable(optimization, _done_step) do
    case Enum.find(optimization.steps, &(&1.status == :pending)) do
      nil -> :finished
      next -> {:ok, next}
    end
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

  # Curadoria closes wider gaps on purpose: the owner chooses freely — his
  # board may leave the copy twenty over — and asked, in as many words, for
  # the engine to balance the count AFTER his decisions instead of blocking
  # them. The bound is the launch contract's own arithmetic: he cannot drift
  # further than the vacancies he was offered. The stages converge: a closing
  # stage that lands short of 100 has its excess refused by the balance guard,
  # and whatever gap remains goes to the next stage, up to the cap.
  @max_closable_gap_curadoria 30

  defp close_or_finish(optimization, done_step) do
    count = sandbox_size(optimization, current_list(optimization))
    spent = Enum.count(optimization.steps, &(&1.kind == :balance))

    if closable?(count, spent, optimization.mode) do
      optimization |> append_balance_step(done_step, count) |> run_step()

      :ok
    else
      finish(optimization)
    end
  end

  defp closable?(count, stages_spent, mode) do
    gap = abs(Balance.target() - count)
    cap = if mode == :curadoria, do: @max_closable_gap_curadoria, else: @max_closable_gap

    gap > 0 and gap <= cap and stages_spent < @max_balance_stages
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
    case sandbox_size(optimization, current_list(optimization)) do
      count when count != 100 -> "fechou em #{count} cartas, não em #{Balance.target()}"
      _hundred -> verdict(criticals_delta(optimization), effect(optimization))
    end
  end

  # The plan stage's own answer, read back off its consult. Every stage after
  # it gets it verbatim — a plan summarised is a plan the next stage gets to
  # reinterpret, which is the whole failure this recipe replaced.
  defp plan_of(%Optimization{steps: steps}) do
    with %OptimizationStep{consult_id: consult_id} when is_binary(consult_id) <-
           Enum.find(steps, &(&1.kind == :plano and &1.status == :done)),
         {:ok, %{response: %{} = response}} <- Consults.fetch(consult_id) do
      response
    else
      _no_plan_yet -> nil
    end
  end

  @doc """
  What the round did to the deck's critical findings: `{before, now}`.

  Measured, not asserted. "Jamais deixar o deck pior" cannot be a sentence in a
  prompt — a model that believes it improved the deck will say so either way —
  so the engine computes both reports from the same baselines and the number is
  what the run reports and what the critic is answerable to.
  """
  @spec criticals_delta(Optimization.t()) :: {non_neg_integer(), non_neg_integer()}
  def criticals_delta(%Optimization{} = optimization) do
    {before_report, after_report} = reports_around(optimization)

    {Report.critical_count(before_report), Report.critical_count(after_report)}
  end

  @doc """
  Which findings the round closed, opened and left standing.

  This is the critic's mandate, and it is the reason the critic can be held to
  "never worse": it is handed the exact list of what its own round broke, by
  code, rather than being asked to notice.
  """
  @spec effect(Optimization.t()) :: ReportDiff.t()
  def effect(%Optimization{} = optimization) do
    {before_report, after_report} = reports_around(optimization)

    ReportDiff.diff(before_report, after_report)
  end

  defp reports_around(%Optimization{} = optimization) do
    {:ok, deck} = Decks.fetch_deck(optimization.deck_id)
    commanders = current_commanders(optimization)
    baselines = Settings.baselines()

    {
      optimization.list_original |> snapshot_for(commanders, deck) |> Analysis.report(baselines),
      optimization
      |> current_list()
      |> snapshot_for(commanders, deck)
      |> Analysis.report(baselines)
    }
  end

  # Said as a fact, in the owner's language, because it is the line he reads
  # before deciding whether to apply half an hour of model time to his deck.
  #
  # A worse run NAMES what appeared instead of counting it. "Críticos 0→1" made
  # the owner open the timeline to learn which critical — and three real runs
  # earned that label from a single finding crossing its threshold by one card.
  # "Apareceu: Nada segura um ataque" is a verdict he can judge from the row:
  # sometimes it is real damage, sometimes it is the deck standing one card
  # from a line it was already leaning on.
  defp verdict({same, same}, _effect), do: "completo · críticos #{same}, sem mudança"

  defp verdict({before, now}, _effect) when now < before,
    do: "completo · críticos #{before}→#{now}"

  defp verdict({before, now}, effect) do
    "ATENÇÃO: o deck saiu pior — críticos #{before}→#{now}#{appeared(effect)}"
  end

  defp appeared(%{introduced: introduced}) do
    case introduced |> Enum.filter(&Finding.critical?/1) |> Enum.map(& &1.title) do
      [] -> ""
      [one] -> " · apareceu: #{one}"
      [one, two] -> " · apareceram: #{one}; #{two}"
      [one | rest] -> " · apareceram: #{one} e mais #{length(rest)}"
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

  defdelegate live_by_deck, to: OptimizationQuery
end
