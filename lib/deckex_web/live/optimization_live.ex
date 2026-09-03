defmodule DeckexWeb.OptimizationLive do
  @moduledoc """
  One optimization run, live.

  A vertical timeline, one card per stage, updating by PubSub as consults
  land. Every stage shows what the model read, what the engine applied, and —
  just as loudly — what it refused and why: a rejection is the audit doing
  its job, not a failure to hide.
  """
  use DeckexWeb, :live_view

  alias Deckex.AI.Ledger
  alias Deckex.Analysis
  alias Deckex.Analysis.Report
  alias Deckex.Cards
  alias Deckex.Consults
  alias Deckex.Consults.Visions
  alias Deckex.Decks
  alias Deckex.Decks.Versions
  alias Deckex.Error
  alias Deckex.Events
  alias Deckex.Money
  alias Deckex.Optimizations
  alias Deckex.Optimizations.Balance
  alias Deckex.Settings

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    case Optimizations.fetch(id) do
      {:ok, optimization} ->
        # Mount-only, the duplicate-subscription law.
        if connected?(socket) do
          Events.subscribe_optimization(optimization.id)
          schedule_tick(optimization)
        end

        {:ok, load(socket, optimization)}

      {:error, %Error{} = error} ->
        {:ok, socket |> put_flash(:error, error.message) |> push_navigate(to: ~p"/")}
    end
  end

  defp load(socket, optimization) do
    {:ok, deck} = Decks.fetch_deck(optimization.deck_id)
    baselines = Settings.baselines()

    original =
      Optimizations.snapshot_for(optimization.list_original, optimization.commanders, deck)

    current =
      Optimizations.snapshot_for(
        Optimizations.current_list(optimization),
        Optimizations.current_commanders(optimization),
        deck
      )

    assign(socket,
      optimization: optimization,
      deck: deck,
      applied_version: Versions.applied_runs(deck)[optimization.id],
      marks: Map.new(Optimizations.marks(optimization), &{&1.card_name, &1}),
      run_spend: Ledger.by_consult(Enum.map(optimization.steps, & &1.consult_id)),
      card_count:
        Optimizations.sandbox_size(optimization, Optimizations.current_list(optimization)),
      stage_progress: stage_progress(optimization, deck, baselines),
      visions: vision_cards(optimization, deck),
      board: board_waiting(optimization),
      card_uris: Cards.uris_for_names(named_cards(optimization)),
      card_ranks: Cards.ranks_for_names(named_cards(optimization)),
      shopping: Optimizations.shopping_list(optimization, deck),
      now: DateTime.utc_now(),
      report_original: Analysis.report(original, baselines),
      report_current: Analysis.report(current, baselines),
      page_title: page_title(optimization, deck)
    )
  end

  # Every card name this page can render, in one query: the changes each stage
  # applied or had refused, plus the current list. A cut card is gone from the
  # list but still named on the timeline, so the list alone is not enough.
  defp named_cards(optimization) do
    from_steps =
      optimization.steps
      |> Enum.flat_map(&((&1.applied || []) ++ (&1.rejected || [])))
      |> Enum.map(& &1["card"])

    from_list = Enum.map(Optimizations.current_list(optimization), & &1["name"])

    (from_steps ++ from_list) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  # Only while the run is waiting: the latest set is the live one. Priced and
  # commander-validated here so the owner sees both before choosing.
  defp vision_cards(%{status: :awaiting_choice} = optimization, deck) do
    case List.last(Optimizations.vision_consults(optimization)) do
      nil -> []
      consult -> Visions.for_consult(consult, deck.color_identity)
    end
  end

  defp vision_cards(_settled, _deck), do: []

  # The Bancada's gate, seen from the timeline. A run parked on a board is not
  # a run that stopped: it is one waiting on the person it belongs to, and the
  # page has to say so loudly enough that he does not read it as a hang.
  defp board_waiting(optimization) do
    case Optimizations.open_gate(optimization) do
      %{kind: :visao} -> nil
      %{} = step -> %{step: step, pending: length(Optimizations.vacancies(optimization, step))}
      nil -> nil
    end
  end

  # Where the needle stood after each stage — computed, never stored, so it
  # is always measured against the rules as they are NOW.
  defp stage_progress(optimization, deck, baselines) do
    optimization.steps
    |> Enum.filter(&(&1.status == :done))
    |> Map.new(fn step ->
      list = Optimizations.list_after(step)

      snapshot =
        Optimizations.snapshot_for(list, Optimizations.current_commanders(optimization), deck)

      report = Analysis.report(snapshot, baselines)

      {step.id,
       %{
         criticals: Report.critical_count(report),
         cards: Optimizations.sandbox_size(optimization, list)
       }}
    end)
  end

  # The tab title carries the progress: the owner leaves this page open in a
  # background tab for half an hour, and the title is all they can see of it.
  defp page_title(%{status: :running} = optimization, deck) do
    "#{stage_counter(optimization)} · Otimização · #{deck.name}"
  end

  defp page_title(%{status: status}, deck) do
    prefix =
      case status do
        :done -> "Concluída"
        :awaiting_choice -> "Sua vez"
        :paused -> "Pausada"
        :failed -> "Falhou"
        :cancelled -> "Cancelada"
      end

    "#{prefix} · Otimização · #{deck.name}"
  end

  defp stage_counter(optimization) do
    total = length(optimization.steps)
    settled = Enum.count(optimization.steps, &(&1.status in [:done, :skipped]))

    "#{min(settled + 1, total)}/#{total}"
  end

  # A consult takes minutes; a wall clock that never moves reads as a hang.
  # Tick only while there is something to time.
  defp schedule_tick(%{status: status}) when status in [:running, :paused] do
    Process.send_after(self(), :tick, 30_000)
  end

  defp schedule_tick(_settled), do: :ok

  @impl Phoenix.LiveView
  def handle_info({:optimization_updated, _id}, socket) do
    {:ok, optimization} = Optimizations.fetch(socket.assigns.optimization.id)

    {:noreply, load(socket, optimization)}
  end

  def handle_info(:tick, socket) do
    schedule_tick(socket.assigns.optimization)

    {:noreply, assign(socket, now: DateTime.utc_now())}
  end

  @impl Phoenix.LiveView
  def handle_event("pausar", _params, socket) do
    {:ok, optimization} = Optimizations.pause(socket.assigns.optimization)

    {:noreply,
     socket |> load(optimization) |> put_flash(:info, "Pausada. O que já foi pago fica.")}
  end

  def handle_event("retomar", _params, socket) do
    {:ok, optimization} = Optimizations.resume(socket.assigns.optimization)

    {:noreply, socket |> load(optimization) |> put_flash(:info, "Retomada.")}
  end

  def handle_event("cancelar", _params, socket) do
    {:ok, optimization} = Optimizations.cancel(socket.assigns.optimization)

    {:noreply,
     socket
     |> load(optimization)
     |> put_flash(:info, "Cancelada. As etapas feitas ficam legíveis.")}
  end

  def handle_event("escolher-visao", %{"index" => index}, socket) do
    case Optimizations.choose_vision(socket.assigns.optimization, String.to_integer(index)) do
      {:ok, optimization} ->
        {:noreply, socket |> load(optimization) |> put_flash(:info, "Direção escolhida.")}

      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("outras-visoes", _params, socket) do
    case Optimizations.ask_again(socket.assigns.optimization) do
      {:ok, optimization} ->
        {:noreply, socket |> load(optimization) |> put_flash(:info, "Pedindo outras três…")}

      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("feedback", %{"step" => step_id} = params, socket) do
    step = find_step(socket, step_id)
    attrs = Map.take(params, ["rating", "favorite", "note"]) |> normalize_feedback(step)
    {:ok, _step} = Optimizations.set_feedback(step, attrs)
    {:ok, optimization} = Optimizations.fetch(socket.assigns.optimization.id)

    {:noreply, load(socket, optimization)}
  end

  def handle_event("nota", %{"step" => step_id, "feedback" => %{"note" => note}}, socket) do
    step = find_step(socket, step_id)
    {:ok, _step} = Optimizations.set_feedback(step, %{"note" => note})
    {:ok, optimization} = Optimizations.fetch(socket.assigns.optimization.id)

    {:noreply, socket |> load(optimization) |> put_flash(:info, "Nota guardada.")}
  end

  def handle_event("refazer", %{"step" => step_id, "modelo" => model}, socket) do
    case Optimizations.redo_step(socket.assigns.optimization, step_id, model) do
      {:ok, optimization} ->
        {:noreply, socket |> load(optimization) |> put_flash(:info, "Refazendo com #{model}.")}

      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("criar-deck", %{"step" => step_id}, socket) do
    step = find_step(socket, step_id)
    fork(socket, step)
  end

  def handle_event("salvar-como-deck", _params, socket) do
    fork(socket, nil)
  end

  def handle_event("marcar", %{"card" => card} = params, socket) do
    {:ok, _state} =
      Optimizations.toggle_mark(socket.assigns.optimization, card, action_of(params["action"]))

    {:noreply, load(socket, socket.assigns.optimization)}
  end

  def handle_event("anotar", %{"card" => card, "nota" => note}, socket) do
    Optimizations.note_mark(socket.assigns.optimization, card, note)

    {:noreply, load(socket, socket.assigns.optimization)}
  end

  def handle_event("revisar", %{"revisao" => %{"geral" => general}}, socket) do
    case Optimizations.review(socket.assigns.optimization, general) do
      {:ok, optimization} ->
        {:noreply,
         socket
         |> load(optimization)
         |> put_flash(:info, "Revisão na fila. A última etapa responde ao que você escreveu.")}

      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("aplicar-no-deck", %{"step" => step_id}, socket) do
    apply_run(socket, find_step(socket, step_id))
  end

  def handle_event("aplicar-no-deck", _params, socket) do
    apply_run(socket, nil)
  end

  # Summed from the stages rather than stored on the run: one set of rows, and
  # no second number that can disagree with the first.
  defp run_cost(spend) do
    Enum.reduce(spend, Decimal.new(0), fn {_id, totals}, sum ->
      Decimal.add(sum, totals.cost_usd)
    end)
  end

  defp run_tokens(spend) do
    Enum.reduce(spend, 0, fn {_id, totals}, sum -> sum + totals.total_tokens end)
  end

  defp mark_action(:add), do: "a rodada colocou"
  defp mark_action(:cut), do: "a rodada tirou"
  defp mark_action(:rejected), do: "o motor recusou"
  defp mark_action(_none), do: "marcada por você"

  defp action_of(action) when action in ["add", "cut", "rejected"],
    do: String.to_existing_atom(action)

  defp action_of(_none), do: nil

  defp apply_run(socket, step) do
    case Optimizations.apply_to_deck(socket.assigns.optimization, step) do
      {:ok, deck} ->
        {:noreply,
         socket
         |> put_flash(:info, "Aplicado em #{deck.name}. Virou a versão mais nova do deck.")
         |> push_navigate(to: ~p"/decks/#{deck.id}/versoes")}

      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  defp fork(socket, step) do
    case Optimizations.save_as_deck(socket.assigns.optimization, step) do
      {:ok, deck} ->
        {:noreply,
         socket
         |> put_flash(:info, "Deck criado: #{deck.name}.")
         |> push_navigate(to: ~p"/decks/#{deck.id}")}

      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  defp find_step(socket, step_id) do
    Enum.find(socket.assigns.optimization.steps, &(&1.id == step_id))
  end

  # Rating and favorite toggle off when clicked again.
  defp normalize_feedback(attrs, step) do
    attrs
    |> Map.new(fn
      {"rating", rating} ->
        {"rating", if(step.feedback["rating"] == rating, do: nil, else: rating)}

      {"favorite", _any} ->
        {"favorite", not (step.feedback["favorite"] == true)}

      other ->
        other
    end)
  end

  # Spelled out because it writes over the deck's cards: the number is the one
  # thing that decides whether this is safe to click, and the sentence after it
  # is the reason it is — the list being replaced does not disappear.
  defp apply_warning(deck, card_count, applied, optimization) do
    repeat =
      if applied, do: "Esta rodada já virou a v#{applied.number} deste deck. ", else: ""

    regression(optimization) <>
      repeat <>
      "Aplicar esta otimização em #{deck.name}? " <>
      "O deck passa a ter #{card_count} cartas, e a lista de agora fica guardada como versão."
  end

  # A run that measured worse is still applicable — it is his deck and the
  # engine's criticals are not the whole truth about a list — but it is not
  # applicable by accident. The number goes in the dialog, first.
  defp regression(%{status: :done} = optimization) do
    case Optimizations.criticals_delta(optimization) do
      {before, now} when now > before ->
        "ATENÇÃO: esta rodada deixou o deck PIOR pelo que o motor mede — " <>
          "críticos #{before}→#{now}. "

      _same_or_better ->
        ""
    end
  end

  defp regression(_not_finished), do: ""

  defp elapsed_label(started_at, now) do
    minutes = DateTime.diff(now, started_at, :minute)
    if minutes < 1, do: "começou agora", else: "há #{minutes} min"
  end

  defp duration_label(consult) do
    minutes = DateTime.diff(consult.updated_at, consult.inserted_at, :minute)
    if minutes < 1, do: "menos de 1 min", else: "#{minutes} min"
  end

  defp status_label(:pending), do: "na fila"
  defp status_label(:running), do: "consultando…"
  defp status_label(:done), do: "feita"
  defp status_label(:skipped), do: "pulada"
  defp status_label(:failed), do: "falhou"

  defp from_label(%{contract: %{"from_version" => number}}) when is_integer(number),
    do: "da v#{number}"

  defp from_label(_working_state), do: "da lista de então"

  defp board_note(%{step: %{kind: :cardapio}, pending: pending}) do
    "#{pending} vagas esperando você. Nada mais é gasto até você fechar a rodada."
  end

  defp board_note(%{pending: pending}) do
    "O crítico leu a sua lista e propôs #{pending} correções. " <>
      "Elas só entram se você quiser — recusar todas também fecha a rodada."
  end

  defp run_status_label(:running), do: "rodando"
  defp run_status_label(:awaiting_choice), do: "esperando você escolher"
  defp run_status_label(:paused), do: "pausada"
  defp run_status_label(:done), do: "concluída"
  defp run_status_label(:failed), do: "falhou"
  defp run_status_label(:cancelled), do: "cancelada"

  defp criticals(report), do: Report.critical_count(report)

  # Direction, not magnitude: the owner wants to know whether the needle moved
  # the right way. Unchanged is neutral — The Quiet-Health Rule says a deck
  # that is fine should not glow.
  defp delta_tone(before, now) when now < before, do: :healthy
  defp delta_tone(before, now) when now > before, do: :critical
  defp delta_tone(_same, _now), do: :neutral

  # Only adds carry a price tag: a cut costs nothing, and an unpriced card
  # shows nothing rather than a guess (the price law).
  defp add_price(%{"action" => "add", "card" => name}) do
    case Cards.get_by_name(name) do
      %{price_usd: %Decimal{} = usd} -> Money.brl(usd)
      _missing_or_unpriced -> nil
    end
  end

  defp add_price(_cut), do: nil

  # The cost, in the currency that matters: how many paid stages this discards.
  defp redo_warning(optimization, step) do
    case Optimizations.stages_after(optimization, step.id) do
      0 ->
        "Refazer esta etapa com outro modelo?"

      n ->
        "Refazer esta etapa descarta as #{n} etapas seguintes, que serão consultadas de novo. Seguir?"
    end
  end

  defp running_position(optimization) do
    Enum.find_value(optimization.steps, &(&1.status == :running and &1.position))
  end

  defp changes_cost(optimization) do
    names =
      optimization.steps
      |> Enum.flat_map(& &1.applied)
      |> Enum.filter(&(&1["action"] == "add"))
      |> Enum.map(& &1["card"])

    prices =
      names
      |> Enum.map(&Cards.get_by_name/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.price_usd)
      |> Enum.reject(&is_nil/1)

    Enum.reduce(prices, Decimal.new(0), &Decimal.add(&2, &1))
  end

  defp changed_count(optimization) do
    optimization.steps |> Enum.map(&length(&1.applied)) |> Enum.sum()
  end

  # What actually changed, net of a card that entered and left. The arithmetic
  # is the domain's — an edge translates and delegates.
  defdelegate consolidated_diff(optimization), to: Optimizations

  attr :card, :string, required: true
  attr :action, :string, default: nil
  attr :marked?, :boolean, default: false

  # A bookmark, not a verdict: it costs one click in the middle of reading and
  # says only "come back to this". What he thinks about it comes at the end,
  # when the run has stopped moving and there is a list to write against.
  defp mark_toggle(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="marcar"
      phx-value-card={@card}
      phx-value-action={@action}
      aria-pressed={to_string(@marked?)}
      aria-label={if @marked?, do: "Desmarcar #{@card}", else: "Marcar #{@card} para comentar"}
      class={[
        "-my-1 inline-flex size-6 items-center justify-center rounded transition-colors align-middle",
        @marked? && "text-sev-warning",
        not @marked? && "text-hairline-strong hover:text-ink-faint"
      ]}
    >
      <.icon name={if @marked?, do: "hero-bookmark-solid", else: "hero-bookmark"} class="size-3.5" />
    </button>
    """
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <%!-- A run is the longest page in the app — ten stages, each with two lists
          under it — and at 1100px it scrolled for a minute. The container grows
          in two steps so the stage detail can go two-up (2xl) and then the
          closing sections can sit side by side (3xl); it stops at 1760px
          because past that a line of reasoning stops being readable no matter
          how much felt is left over. --%>
    <div class="mx-auto max-w-[1100px] px-6 py-10 lg:px-10 lg:py-14 2xl:max-w-[1440px] 3xl:max-w-[1760px]">
      <%!-- Inside the LiveView's own tree, not the root layout: the layout is
            static after mount, so a flash put during an event would never
            reach the screen from there. --%>
      <DeckexWeb.Layouts.flash_group flash={@flash} />
      <.live_component module={DeckexWeb.SettingsPanel} id="settings-panel" />

      <.link
        navigate={~p"/decks/#{@deck.id}/otimizacoes"}
        class="-my-2 inline-flex min-h-touch items-center py-2 text-caption text-ink-faint transition-colors hover:text-ink"
      >
        ← Otimizações de {@deck.name}
      </.link>

      <.deck_nav deck={@deck} current={:runs} />

      <header class="mt-3 mb-8">
        <div class="flex flex-wrap items-end justify-between gap-4">
          <div>
            <h1 class="text-display font-semibold text-ink">Otimização</h1>
            <p class="mt-1 text-body text-ink-muted">
              {run_status_label(@optimization.status)}{if @optimization.status == :running,
                do: " · etapa #{stage_counter(@optimization)}"}{if @optimization.outcome,
                do: " · #{@optimization.outcome}"} · modelo {@optimization.contract["model"]}
              <%!-- Which list this argued about. Two runs a week apart are not
                    comparable unless you know one started from a v3 and the
                    other from a v7. --%>
              · a partir {from_label(@optimization)}
              <%!-- On a ten-stage run nobody remembers what they marked in
                    stage two. The count says the review has something waiting
                    in it, before the review section exists. --%>
              <span :if={@marks != %{}} class="text-sev-warning">
                · {map_size(@marks)} carta(s) marcada(s)
              </span>
              <span :if={vision = Optimizations.chosen_vision(@optimization)}>
                · direção: <span class="text-ink">{vision["nome"]}</span>
              </span>
              <a
                :if={position = running_position(@optimization)}
                href={"#etapa-#{position}"}
                class="text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
              >
                ir à etapa rodando ↓
              </a>
            </p>
          </div>

          <div class="flex items-center gap-2">
            <.button
              :if={@optimization.status == :running}
              type="button"
              phx-click="pausar"
              phx-disable-with="…"
            >
              Pausar
            </.button>
            <.button
              :if={@optimization.status == :paused}
              type="button"
              phx-click="retomar"
              phx-disable-with="…"
              variant="primary"
            >
              Retomar
            </.button>
            <.button
              :if={@optimization.status in [:running, :paused]}
              type="button"
              phx-click="cancelar"
              data-confirm="Cancelar esta otimização? As etapas já feitas ficam legíveis."
            >
              Cancelar
            </.button>
            <%!-- Applying is the default and forking is the exception: a run
                  is work done on a deck, and the deck is where it belongs.
                  Forking stays for the case the owner wants both lists side by
                  side, which is a different intention and reads as one. --%>
            <%!-- Said on the button, not in a footnote: "aplicar" on a run
                  already in the deck is a second copy of the same changes. --%>
            <.link
              :if={@applied_version}
              navigate={~p"/decks/#{@deck.id}/versoes"}
              class="inline-flex min-h-touch items-center rounded-full bg-inlay px-3 font-mono text-micro text-ink-secondary transition-colors hover:text-ink"
            >
              já aplicada · v{@applied_version.number} →
            </.link>
            <.button
              :if={@optimization.status == :done}
              type="button"
              phx-click="aplicar-no-deck"
              phx-disable-with="Aplicando…"
              data-confirm={apply_warning(@deck, @card_count, @applied_version, @optimization)}
              variant={if @applied_version, do: nil, else: "primary"}
            >
              {if @applied_version, do: "Aplicar de novo", else: "Aplicar no deck"}
            </.button>
            <.button
              :if={@optimization.status == :done}
              type="button"
              phx-click="salvar-como-deck"
              phx-disable-with="Salvando…"
            >
              Salvar como deck separado
            </.button>
          </div>
        </div>

        <%!-- Six tiles, and five columns left one orphan on its own row at
              every width above 640px while squeezing the other five (118px each
              at 640, where "R$ 1.234,56" in the numeral face does not fit).
              Three and six both divide six: two clean rows until the container
              is wide enough for one. --%>
        <div class="mt-6 grid grid-cols-2 gap-3 sm:grid-cols-3 2xl:grid-cols-6">
          <.stat
            label="Críticos"
            value={Integer.to_string(criticals(@report_current))}
            target={"eram #{criticals(@report_original)}"}
            tone={delta_tone(criticals(@report_original), criticals(@report_current))}
          />
          <.stat
            label="Bracket (piso)"
            value={Integer.to_string(@report_current.bracket.floor)}
            target={"era #{@report_original.bracket.floor}"}
          />
          <.stat label="Entradas" value={Money.brl(changes_cost(@optimization))} />
          <%!-- A ten-stage run is ten paid answers; the number belongs next to
                what the run bought, not in a bill somewhere else. Before the
                first stage lands there is nothing to show, and "R$ 0,00" for a
                run in flight reads as a broken meter rather than as an empty
                one. --%>
          <.stat
            label="Custo da rodada"
            value={if @run_spend == %{}, do: "—", else: Money.brl(run_cost(@run_spend))}
            target={
              if @run_spend == %{},
                do: "quando a 1ª etapa responder",
                else: "#{DeckexWeb.UI.token_count(run_tokens(@run_spend))} tokens"
            }
          />
          <.stat label="Mudanças" value={Integer.to_string(changed_count(@optimization))} />
          <.stat
            label="Cartas"
            value={Integer.to_string(@card_count)}
            target="alvo 100"
            tone={if @card_count == 100, do: :healthy, else: :warning}
          />
        </div>
      </header>

      <section
        :if={@board}
        class="mb-8 rounded-xl border border-hairline-strong bg-surface p-5 sm:flex sm:items-center sm:gap-6"
      >
        <div class="min-w-0 flex-1">
          <h2 class="text-heading font-semibold text-ink">Sua vez</h2>
          <p class="mt-1 text-caption leading-relaxed text-ink-muted">
            {board_note(@board)}
          </p>
        </div>

        <.link
          navigate={~p"/otimizacoes/#{@optimization.id}/bancada"}
          class="mt-4 inline-flex min-h-touch w-full items-center justify-center rounded-md bg-ink px-4 text-body font-semibold text-felt transition-opacity hover:opacity-90 motion-reduce:transition-none sm:mt-0 sm:w-auto"
        >
          Abrir a Bancada
        </.link>
      </section>

      <section :if={@visions != []} class="mb-8">
        <h2 class="mb-1 text-heading font-semibold text-ink">Escolha uma direção</h2>
        <p class="mb-4 text-caption text-ink-muted">
          A rodada está esperando você. Nada mais é gasto até você escolher.
        </p>

        <ul class="grid gap-4 sm:grid-cols-3">
          <li
            :for={{vision, index} <- Enum.with_index(@visions)}
            class="flex min-w-0 flex-col rounded-xl border border-hairline-soft bg-surface p-5"
          >
            <div class="flex items-start justify-between gap-2">
              <h3 class="text-heading font-semibold leading-tight text-ink">{vision.nome}</h3>
              <span class="flex shrink-0 flex-wrap justify-end gap-1">
                <span
                  :if={vision.arquetipo != ""}
                  class="rounded-sm bg-chip px-2 py-0.5 font-mono text-micro text-ink-secondary"
                >
                  {vision.arquetipo}
                </span>
                <span
                  :if={vision.tema != ""}
                  class="rounded-sm border border-hairline-soft px-2 py-0.5 font-mono text-micro text-ink-faint"
                >
                  {vision.tema}
                </span>
              </span>
            </div>

            <p class="mt-3 font-mono text-numeral-sm leading-none text-ink">
              {Money.brl(vision.total_usd)}
              <span class="font-sans text-caption text-ink-faint">em entradas</span>
            </p>

            <p class="mt-3 flex-1 text-caption leading-relaxed text-ink-secondary">{vision.tese}</p>

            <div :if={vision.cartas != []} class="-mx-1 mt-4 min-w-0 overflow-x-auto px-1 pb-1">
              <div class="flex gap-2">
                <.card_thumb
                  :for={carta <- vision.cartas}
                  name={carta.name}
                  art={carta.card && carta.card.image_art_crop_url}
                  uri={carta.card && carta.card.scryfall_uri}
                  note={carta.price_usd && Money.brl(carta.price_usd)}
                  rank={carta.card && carta.card.edhrec_rank}
                />
              </div>
            </div>

            <p :if={vision.comandante_nome} class="mt-3 text-caption">
              <span class="text-ink-muted">Comandante:</span>
              <.card_link
                name={vision.comandante_nome}
                uri={vision.comandante && vision.comandante.scryfall_uri}
                class="text-ink"
              />
              <span :if={vision.comandante_problem} class="block text-sev-critical">
                {vision.comandante_problem}
              </span>
            </p>

            <details class="mt-3">
              <summary class="-my-2 inline-flex min-h-touch cursor-pointer items-center py-2 text-caption text-ink-faint transition-colors hover:text-ink motion-reduce:transition-none">
                O que o deck perde
              </summary>
              <p class="mt-1 text-caption leading-relaxed text-ink-muted">{vision.custo}</p>
            </details>

            <.button
              type="button"
              phx-click="escolher-visao"
              phx-value-index={index}
              phx-disable-with="seguindo…"
              variant="primary"
              class="mt-4"
            >
              Seguir esta
            </.button>
          </li>
        </ul>

        <button
          type="button"
          phx-click="outras-visoes"
          phx-disable-with="pedindo…"
          data-confirm="Pedir outras três direções? Isso gasta mais uma consulta."
          class="-my-2 mt-4 inline-flex min-h-touch items-center px-1 py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
        >
          Pedir outras três (mais uma consulta)
        </button>
      </section>

      <ol class="space-y-4">
        <li
          :for={step <- @optimization.steps}
          id={"etapa-#{step.position}"}
          class="scroll-mt-6 rounded-xl border border-hairline-soft bg-surface p-5"
        >
          <div class="flex flex-wrap items-center justify-between gap-3">
            <h2 class="text-heading font-semibold text-ink">
              <span class="font-mono text-caption text-ink-faint">{step.position}.</span>
              {step.label}
            </h2>
            <span class={[
              "font-mono text-caption",
              step.status == :done && "text-sev-healthy",
              step.status == :failed && "text-sev-critical",
              step.status == :skipped && "text-ink-faint",
              step.status in [:pending, :running] && "text-sev-warning"
            ]}>
              <span class={step.status == :running && "animate-pulse"}>
                {status_label(step.status)}
              </span>
              <span
                :if={step.status == :running && step.consult}
                class="text-ink-faint"
              >
                · {elapsed_label(step.consult.inserted_at, @now)}
              </span>
              <span :if={step.status == :done && step.consult} class="text-ink-faint">
                · {duration_label(step.consult)}
              </span>
              <%!-- The count is the one number on this line that has a right
                    answer, so it is the one allowed to be coloured: reading
                    105 → 103 → 101 → 100 down the timeline is the whole story
                    of the balance walking home. --%>
              <span :if={chip = @stage_progress[step.id]} class="text-ink-faint">
                · {chip.criticals} {if chip.criticals == 1, do: "crítico", else: "críticos"} ·
                <span class={[
                  chip.cards == Balance.target() && "text-sev-healthy",
                  chip.cards != Balance.target() && "text-sev-warning"
                ]}>
                  {chip.cards} cartas
                </span>
              </span>
            </span>
          </div>

          <%!-- A stage that failed used to say only that the run was paused —
                never what went wrong. The reason was on the consult row the
                whole time, one join away, and this page already had it. --%>
          <.failure :if={step.status == :failed and step.consult} consult={step.consult} class="mt-3" />

          <p
            :if={step.status == :failed and @optimization.status == :paused}
            class="mt-2 text-caption text-ink-muted"
          >
            A falha pausou a rodada. Retomar tenta esta etapa de novo — as anteriores ficam.
          </p>

          <p
            :if={step.consult && step.consult.response["leitura"]}
            class="mt-3 max-w-[78ch] border-l-2 border-hairline-strong pl-3 text-caption italic text-ink-muted"
          >
            {step.consult.response["leitura"]}
          </p>

          <p
            :if={step.status == :done and step.applied == [] and step.rejected == []}
            class="mt-3 text-caption text-ink-muted"
          >
            Nenhuma mudança — o modelo olhou e não propôs nada.
          </p>

          <%!-- The two halves of a stage's verdict, stacked on a laptop and
                side by side once there is room. They are read against each
                other — what went in, what the motor refused — and on an
                ultra-wide the pair used to be two narrow lists one under the
                other with half the screen empty beside them. --%>
          <div
            :if={step.applied != [] or step.rejected != []}
            class="mt-3 grid gap-x-10 gap-y-3 2xl:grid-cols-2 2xl:items-start"
          >
            <div :if={step.applied != []}>
              <h3 class="mb-1 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
                Aplicadas
              </h3>
              <ul class="max-w-[78ch] space-y-1">
                <li :for={change <- step.applied} class="text-caption text-ink-secondary">
                  <.mark_toggle
                    card={change["card"]}
                    action={change["action"]}
                    marked?={Map.has_key?(@marks, change["card"])}
                  />
                  <span class={[
                    "font-mono",
                    change["action"] == "add" && "text-sev-healthy",
                    change["action"] == "cut" && "text-sev-critical"
                  ]}>
                    {if change["action"] == "add", do: "+", else: "−"}
                  </span>
                  <.card_link name={change["card"]} uri={@card_uris[change["card"]]} class="text-ink" />
                  <.play_rate :if={change["action"] == "add"} rank={@card_ranks[change["card"]]} />
                  <span class="text-ink-muted">— {change["reason"]}</span>
                  <span :if={change["note"]} class="block text-micro text-ink-faint">
                    motor: {change["note"]}
                  </span>
                </li>
              </ul>
            </div>

            <div :if={step.rejected != []}>
              <h3 class="mb-1 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
                Recusadas pelo motor
              </h3>
              <ul class="max-w-[78ch] space-y-1">
                <li :for={change <- step.rejected} class="text-caption">
                  <.mark_toggle
                    card={change["card"]}
                    action="rejected"
                    marked?={Map.has_key?(@marks, change["card"])}
                  />
                  <.card_link
                    name={change["card"]}
                    uri={@card_uris[change["card"]]}
                    class="text-ink-secondary"
                  />
                  <span class="text-sev-critical">
                    — {Enum.join(change["problems"] || [], "; ")}
                  </span>
                </li>
              </ul>
            </div>
          </div>

          <div
            :if={step.status == :done}
            class="mt-4 flex flex-wrap items-center gap-2 border-t border-hairline-soft pt-3"
          >
            <button
              type="button"
              phx-click="feedback"
              phx-value-step={step.id}
              phx-value-rating="up"
              aria-label="Etapa boa"
              class={[
                "inline-flex size-touch items-center justify-center rounded-md transition-colors",
                step.feedback["rating"] == "up" && "bg-inlay text-sev-healthy",
                step.feedback["rating"] != "up" && "text-ink-faint hover:text-ink"
              ]}
            >
              <.icon name="hero-hand-thumb-up" class="size-5" />
            </button>
            <button
              type="button"
              phx-click="feedback"
              phx-value-step={step.id}
              phx-value-rating="down"
              aria-label="Etapa ruim"
              class={[
                "inline-flex size-touch items-center justify-center rounded-md transition-colors",
                step.feedback["rating"] == "down" && "bg-inlay text-sev-critical",
                step.feedback["rating"] != "down" && "text-ink-faint hover:text-ink"
              ]}
            >
              <.icon name="hero-hand-thumb-down" class="size-5" />
            </button>
            <button
              type="button"
              phx-click="feedback"
              phx-value-step={step.id}
              phx-value-favorite="toggle"
              aria-label="Favoritar etapa"
              class={[
                "inline-flex size-touch items-center justify-center rounded-md transition-colors",
                step.feedback["favorite"] == true && "bg-inlay text-sev-warning",
                step.feedback["favorite"] != true && "text-ink-faint hover:text-ink"
              ]}
            >
              <.icon name="hero-star" class="size-5" />
            </button>

            <.form
              for={%{}}
              as={:feedback}
              id={"nota-#{step.id}"}
              phx-submit="nota"
              class="flex min-w-0 flex-1 items-center gap-2"
            >
              <input type="hidden" name="step" value={step.id} />
              <label for={"nota-campo-#{step.id}"} class="sr-only">Nota da etapa</label>
              <input
                id={"nota-campo-#{step.id}"}
                type="text"
                name="feedback[note]"
                value={step.feedback["note"]}
                placeholder="anotar algo sobre esta etapa…"
                class={[control_class(), "min-h-touch"]}
              />
              <button
                type="submit"
                class="-my-2 inline-flex min-h-touch items-center px-1 py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
              >
                guardar
              </button>
            </.form>

            <.form
              for={%{}}
              as={:refazer}
              id={"refazer-#{step.id}"}
              phx-submit="refazer"
              class="flex items-center gap-1"
            >
              <input type="hidden" name="step" value={step.id} />
              <label for={"modelo-#{step.id}"} class="sr-only">Refazer esta etapa com</label>
              <select
                id={"modelo-#{step.id}"}
                name="modelo"
                class={[control_class(), "min-h-touch w-auto font-mono"]}
              >
                <option
                  :for={model <- Consults.models_at_or_above(Settings.model_floor())}
                  value={model}
                  selected={model == (step.model || @optimization.contract["model"])}
                >
                  {model}
                </option>
              </select>
              <button
                type="submit"
                phx-disable-with="refazendo…"
                data-confirm={redo_warning(@optimization, step)}
                class="-my-2 inline-flex min-h-touch items-center whitespace-nowrap px-1 py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink motion-reduce:transition-none"
              >
                Refazer
              </button>
            </.form>

            <button
              type="button"
              phx-click="aplicar-no-deck"
              phx-value-step={step.id}
              phx-disable-with="aplicando…"
              data-confirm={"Aplicar o deck até esta etapa em #{@deck.name}? A lista de agora fica guardada como versão."}
              class="-my-2 inline-flex min-h-touch items-center whitespace-nowrap px-1 py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
            >
              Aplicar até aqui
            </button>

            <button
              type="button"
              phx-click="criar-deck"
              phx-value-step={step.id}
              phx-disable-with="criando…"
              data-confirm="Criar um deck novo com a lista desta etapa?"
              class="-my-2 inline-flex min-h-touch items-center whitespace-nowrap px-1 py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
            >
              Criar deck deste ponto
            </button>
          </div>
        </li>
      </ol>

      <%!-- Before the changelog, because this is the one the owner acts on.
            It is not the same list: a card he already applied to the real deck
            is a change he made, not a card he still needs to buy. --%>
      <%!-- The stage that exists because a pipeline cannot read a card as well
            as the person who plays it. Jaheira turns Food into creatures that
            tap for mana; a stage cut her for "só dá mana a tokens de criatura",
            and there was nowhere to say so. --%>
      <section :if={@optimization.status == :done} class="mt-10">
        <h2 class="mb-1 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
          Sua revisão
        </h2>
        <p class="mb-3 max-w-[75ch] text-caption text-ink-muted">
          Uma última etapa, contra o que você escrever. Ela pode desfazer o que as outras fizeram —
          você joga esse deck, o modelo só leu as cartas.
        </p>

        <div class="rounded-xl border border-hairline-soft bg-surface p-6">
          <p :if={@marks == %{}} class="max-w-[75ch] text-caption text-ink-muted">
            Nenhuma carta marcada. Durante a rodada, o marcador ao lado de cada carta guarda ela
            para você comentar aqui — e o campo abaixo vale para a rodada inteira.
          </p>

          <%!-- A card and a two-line box is a shape that tiles: on a wide screen
                twelve marked cards were twelve full-width rows and a scroll,
                and they are read as a set. `space-y-0` because a grid gap and a
                sibling margin are two spacings arguing. --%>
          <ul
            :if={@marks != %{}}
            class="mb-4 space-y-3 2xl:grid 2xl:grid-cols-2 2xl:gap-x-8 2xl:gap-y-4 2xl:space-y-0 3xl:grid-cols-3"
          >
            <li :for={{card, mark} <- Enum.sort_by(@marks, &elem(&1, 0))}>
              <div class="flex flex-wrap items-baseline gap-2">
                <.mark_toggle card={card} marked?={true} />
                <.card_link name={card} uri={@card_uris[card]} class="text-ink" />
                <span class="font-mono text-micro text-ink-faint">{mark_action(mark.action)}</span>
              </div>

              <.form
                for={%{}}
                id={"nota-carta-#{mark.id}"}
                phx-change="anotar"
                phx-submit="anotar"
                class="mt-1"
              >
                <input type="hidden" name="card" value={card} />
                <label for={"nota-#{mark.id}"} class="sr-only">O que você acha de {card}</label>
                <textarea
                  id={"nota-#{mark.id}"}
                  name="nota"
                  rows="2"
                  phx-debounce="blur"
                  placeholder={"o que o motor errou sobre #{card}, ou por que ela fica"}
                  class={[control_class()]}
                >{mark.note}</textarea>
              </.form>
            </li>
          </ul>

          <%!-- Capped past 2xl only: a three-row box the width of an ultra-wide
                is a field nobody can proofread, and narrower screens already
                had a sane one. --%>
          <.form for={%{}} id="revisao" phx-submit="revisar" class="space-y-2 2xl:max-w-[80ch]">
            <label for="revisao-geral" class="block text-caption font-semibold text-ink-secondary">
              E da rodada inteira
            </label>
            <textarea
              id="revisao-geral"
              name="revisao[geral]"
              rows="3"
              placeholder="ex.: ficou lento demais; cortou cartas do tema; quero mais remoção barata"
              class={[control_class()]}
            >{@optimization.contract["revisao_geral"]}</textarea>

            <div class="flex flex-wrap items-center gap-3">
              <.button
                type="submit"
                phx-disable-with="mandando…"
                variant={if Optimizations.reviewable?(@optimization), do: "primary", else: nil}
                disabled={not Optimizations.reviewable?(@optimization)}
              >
                Rodar a revisão
              </.button>
              <span class="text-micro text-ink-faint">
                {if Optimizations.reviewable?(@optimization),
                  do: "Uma consulta a mais, com o motor conferindo como em qualquer etapa.",
                  else:
                    "Esta rodada já teve as revisões que cabem. Aplique o que ficou bom e comece outra."}
              </span>
            </div>
          </.form>
        </div>
      </section>

      <%!-- The shopping list and the changelog are the two things read after a
            run lands, and they answer different questions about the same set of
            cards — what it costs, what it did. Side by side once both fit; when
            there is nothing to buy the changelog keeps the whole width rather
            than sitting in a half-column beside a hole. --%>
      <div
        :if={@optimization.status == :done}
        class={[
          "mt-10 grid gap-10 3xl:items-start",
          @shopping.cards != [] && "3xl:grid-cols-2"
        ]}
      >
        <section :if={@optimization.status == :done and @shopping.cards != []}>
          <h2 class="mb-3 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
            O que comprar
          </h2>

          <div class="rounded-xl border border-hairline-soft bg-surface p-6">
            <ul class="divide-y divide-hairline-soft">
              <li
                :for={item <- @shopping.cards}
                class="flex flex-wrap items-baseline gap-x-2 gap-y-1 py-2 first:pt-0 last:pb-0"
              >
                <.card_link
                  name={item.name}
                  uri={item.card && item.card.scryfall_uri}
                  class="text-body text-ink"
                />
                <.play_rate rank={item.rank} />
                <span class="ml-auto font-mono text-caption text-ink-secondary">
                  {Money.brl(item.card && item.card.price_usd)}
                </span>
              </li>
            </ul>

            <div class="mt-4 flex flex-wrap items-baseline justify-between gap-3 border-t border-hairline-soft pt-4">
              <p class="font-mono text-numeral-sm leading-none text-ink">
                {Money.brl(@shopping.total_usd)}
                <span class="font-sans text-caption text-ink-faint">
                  por {length(@shopping.cards)} carta(s)
                </span>
              </p>

              <div class="flex items-center gap-3">
                <a
                  href={~p"/otimizacoes/#{@optimization.id}/compras.txt"}
                  download
                  class="-my-2 inline-flex min-h-touch items-center px-1 py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
                >
                  Baixar
                </a>
                <button
                  id="copiar-compras"
                  type="button"
                  phx-hook=".CopyList"
                  data-target="lista-compras"
                  class="-my-2 inline-flex min-h-touch items-center px-1 py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
                >
                  copiar tudo
                </button>
              </div>
            </div>

            <%!-- Unpriced cards are listed and left out of the total: guessing
                what one costs to make the arithmetic tidy is the invention
                this app refuses everywhere else. --%>
            <p :if={@shopping.unpriced > 0} class="mt-2 text-micro text-ink-faint">
              {@shopping.unpriced} carta(s) sem preço conhecido não entram no total.
            </p>

            <label for="lista-compras" class="sr-only">Lista de compra</label>
            <textarea id="lista-compras" readonly rows="1" class="sr-only">{Optimizations.shopping_list_text(@optimization, @deck)}</textarea>
          </div>
        </section>

        <section :if={@optimization.status == :done}>
          <h2 class="mb-3 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
            O que mudou, no total
          </h2>

          <div class="rounded-xl border border-hairline-soft bg-surface p-6">
            <p :if={@card_count != 100} class="mb-4 text-caption text-sev-warning">
              A lista final tem {@card_count} cartas — um deck de Commander precisa de 100.
              Complete a diferença antes de levar este deck para a mesa.
            </p>

            <p :if={consolidated_diff(@optimization) == []} class="text-body text-ink-secondary">
              Nada — o deck já estava onde o pipeline queria levar.
            </p>

            <%!-- Measure, not width: a card, a price and a sentence of
                  reasoning stay one readable line however wide the panel
                  gets. --%>
            <ul class="max-w-[78ch] space-y-1">
              <li
                :for={change <- consolidated_diff(@optimization)}
                class="text-caption text-ink-secondary"
              >
                <span class={[
                  "font-mono",
                  change["action"] == "add" && "text-sev-healthy",
                  change["action"] == "cut" && "text-sev-critical"
                ]}>
                  {if change["action"] == "add", do: "+", else: "−"}
                </span>
                <.card_link name={change["card"]} uri={@card_uris[change["card"]]} class="text-ink" />
                <span :if={price = add_price(change)} class="font-mono text-ink-faint">{price}</span>
                <.play_rate :if={change["action"] == "add"} rank={@card_ranks[change["card"]]} />
                <span class="text-ink-muted">— {change["reason"]}</span>
              </li>
            </ul>

            <details class="mt-4 border-t border-hairline-soft pt-4">
              <summary class="-my-2 inline-flex min-h-touch cursor-pointer items-center py-2 text-caption text-ink-faint transition-colors hover:text-ink motion-reduce:transition-none">
                Lista final para copiar
              </summary>
              <button
                id="copiar-lista"
                type="button"
                phx-hook=".CopyList"
                data-target="lista-final"
                class="-my-2 mt-1 inline-flex min-h-touch items-center px-1 py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
              >
                copiar tudo
              </button>
              <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyList">
                // The clipboard API can refuse (permissions, embedded browsers).
                // Refusal must not be silence: fall back to selecting the text
                // so one keystroke finishes the job, and say so on the button.
                export default {
                  mounted() {
                    this.el.addEventListener("click", () => {
                      const target = document.getElementById(this.el.dataset.target)

                      const flash = (text) => {
                        this.el.textContent = text
                        setTimeout(() => { this.el.textContent = "copiar tudo" }, 2500)
                      }

                      navigator.clipboard.writeText(target.value).then(
                        () => flash("copiado ✓"),
                        () => {
                          target.focus()
                          target.select()
                          flash("selecionei — copia com Ctrl/⌘+C")
                        }
                      )
                    })
                  }
                }
              </script>
              <textarea
                id="lista-final"
                readonly
                rows="12"
                class={[control_class(), "mt-2 font-mono"]}
              >{Optimizations.list_to_text(Optimizations.current_list(@optimization), Optimizations.current_commanders(@optimization))}</textarea>
            </details>
          </div>
        </section>
      </div>
    </div>
    """
  end
end
