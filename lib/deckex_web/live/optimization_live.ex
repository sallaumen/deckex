defmodule DeckexWeb.OptimizationLive do
  @moduledoc """
  One optimization run, live.

  A vertical timeline, one card per stage, updating by PubSub as consults
  land. Every stage shows what the model read, what the engine applied, and —
  just as loudly — what it refused and why: a rejection is the audit doing
  its job, not a failure to hide.
  """
  use DeckexWeb, :live_view

  alias Deckex.Analysis
  alias Deckex.Analysis.Report
  alias Deckex.Cards
  alias Deckex.Consults.Visions
  alias Deckex.Decks
  alias Deckex.Error
  alias Deckex.Events
  alias Deckex.Money
  alias Deckex.Optimizations
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
      card_count: Optimizations.card_count(Optimizations.current_list(optimization)),
      stage_progress: stage_progress(optimization, deck, baselines),
      visions: vision_cards(optimization, deck),
      now: DateTime.utc_now(),
      report_original: Analysis.report(original, baselines),
      report_current: Analysis.report(current, baselines),
      page_title: page_title(optimization, deck)
    )
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
       %{criticals: Report.critical_count(report), cards: Optimizations.card_count(list)}}
    end)
  end

  # The tab title carries the progress: the owner leaves this page open in a
  # background tab for half an hour, and the title is all they can see of it.
  defp page_title(%{status: :running} = optimization, deck) do
    "#{stage_counter(optimization)} · Otimização · #{deck.name}"
  end

  defp page_title(%{status: status} = optimization, deck) do
    prefix =
      case status do
        :done -> "Concluída#{if optimization.outcome == "estabilizou", do: " (estabilizou)"}"
        :awaiting_choice -> "Escolha uma direção"
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

  def handle_event("criar-deck", %{"step" => step_id}, socket) do
    step = find_step(socket, step_id)
    fork(socket, step)
  end

  def handle_event("salvar-como-deck", _params, socket) do
    fork(socket, nil)
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
  defp status_label(:skipped), do: "pulada — nada mudou desde o último checkpoint"
  defp status_label(:failed), do: "falhou"

  defp run_status_label(:running), do: "rodando"
  defp run_status_label(:awaiting_choice), do: "esperando você escolher"
  defp run_status_label(:paused), do: "pausada"
  defp run_status_label(:done), do: "concluída"
  defp run_status_label(:failed), do: "falhou"
  defp run_status_label(:cancelled), do: "cancelada"

  defp criticals(report), do: Report.critical_count(report)

  # Only adds carry a price tag: a cut costs nothing, and an unpriced card
  # shows nothing rather than a guess (the price law).
  defp add_price(%{"action" => "add", "card" => name}) do
    case Cards.get_by_name(name) do
      %{price_usd: %Decimal{} = usd} -> Money.brl(usd)
      _missing_or_unpriced -> nil
    end
  end

  defp add_price(_cut), do: nil

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

  defp consolidated_diff(optimization) do
    optimization.steps |> Enum.flat_map(& &1.applied) |> net_changes()
  end

  # A card added and later cut nets to nothing; the diff the owner reads is
  # what actually changed between the original list and the final one.
  defp net_changes(changes) do
    changes
    |> Enum.group_by(& &1["card"])
    |> Enum.flat_map(fn {_card, touches} ->
      adds = Enum.count(touches, &(&1["action"] == "add"))
      cuts = Enum.count(touches, &(&1["action"] == "cut"))

      cond do
        adds > cuts -> [List.last(Enum.filter(touches, &(&1["action"] == "add")))]
        cuts > adds -> [List.last(Enum.filter(touches, &(&1["action"] == "cut")))]
        true -> []
      end
    end)
    |> Enum.sort_by(&{&1["action"], &1["card"]})
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-[1100px] px-6 py-10 lg:px-10 lg:py-14">
      <.live_component module={DeckexWeb.SettingsPanel} id="settings-panel" />

      <.link
        navigate={~p"/decks/#{@deck.id}/otimizacoes"}
        class="-my-2 inline-flex min-h-11 items-center py-2 text-caption text-ink-faint transition-colors hover:text-ink"
      >
        ← Otimizações de {@deck.name}
      </.link>

      <header class="mt-3 mb-8">
        <div class="flex flex-wrap items-end justify-between gap-4">
          <div>
            <h1 class="text-display font-semibold text-ink">Otimização</h1>
            <p class="mt-1 text-body text-ink-muted">
              {run_status_label(@optimization.status)}{if @optimization.status == :running,
                do: " · etapa #{stage_counter(@optimization)}"}{if @optimization.outcome,
                do: " · #{@optimization.outcome}"} · modelo {@optimization.contract["model"]}
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
            <.button
              :if={@optimization.status == :done}
              type="button"
              phx-click="salvar-como-deck"
              phx-disable-with="Salvando…"
              variant="primary"
            >
              Salvar como novo deck
            </.button>
          </div>
        </div>

        <div class="mt-6 grid grid-cols-2 gap-4 rounded-xl border border-hairline-soft bg-surface p-5 sm:grid-cols-5">
          <div>
            <p class="text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">Críticos</p>
            <p class="font-mono text-numeral-sm text-ink">
              {criticals(@report_original)} → {criticals(@report_current)}
            </p>
          </div>
          <div>
            <p class="text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
              Bracket (piso)
            </p>
            <p class="font-mono text-numeral-sm text-ink">
              {@report_original.bracket.floor} → {@report_current.bracket.floor}
            </p>
          </div>
          <div>
            <p class="text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">Entradas</p>
            <p class="font-mono text-numeral-sm text-ink">{Money.brl(changes_cost(@optimization))}</p>
          </div>
          <div>
            <p class="text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">Mudanças</p>
            <p class="font-mono text-numeral-sm text-ink">{changed_count(@optimization)}</p>
          </div>
          <div>
            <p class="text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">Cartas</p>
            <p class={[
              "font-mono text-numeral-sm",
              @card_count == 100 && "text-ink",
              @card_count != 100 && "text-sev-warning"
            ]}>
              {@card_count}<span class="text-caption text-ink-faint">/100</span>
            </p>
          </div>
        </div>
      </header>

      <section :if={@visions != []} class="mb-8">
        <h2 class="mb-1 text-heading font-semibold text-ink">Escolha uma direção</h2>
        <p class="mb-4 text-caption text-ink-muted">
          A rodada está esperando você. Nada mais é gasto até você escolher.
        </p>

        <ul class="grid gap-4 sm:grid-cols-3">
          <li
            :for={{vision, index} <- Enum.with_index(@visions)}
            class="flex flex-col rounded-xl border border-hairline-soft bg-surface p-5"
          >
            <h3 class="text-heading font-semibold text-ink">{vision.nome}</h3>
            <p class="mt-2 flex-1 text-caption text-ink-secondary">{vision.tese}</p>

            <p class="mt-3 text-caption text-ink-muted">
              <span class="font-semibold">O que perde:</span> {vision.custo}
            </p>

            <p :if={vision.comandante_nome} class="mt-3 text-caption">
              <span class="text-ink-muted">Comandante:</span>
              <span class="text-ink">{vision.comandante_nome}</span>
              <span :if={vision.comandante_problem} class="text-sev-critical">
                — {vision.comandante_problem}
              </span>
            </p>

            <ul :if={vision.cartas != []} class="mt-3 space-y-1">
              <li :for={carta <- vision.cartas} class="text-caption text-ink-secondary">
                <span class="text-ink">{carta.name}</span>
                <span class="font-mono text-ink-faint">{Money.brl(carta.price_usd)}</span>
              </li>
            </ul>

            <p class="mt-3 font-mono text-caption text-ink">
              entradas: {Money.brl(vision.total_usd)}
            </p>

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
          class="-my-2 mt-4 inline-flex min-h-11 items-center px-1 py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
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
              <span :if={chip = @stage_progress[step.id]} class="text-ink-faint">
                · {chip.criticals} {if chip.criticals == 1, do: "crítico", else: "críticos"} · {chip.cards} cartas
              </span>
            </span>
          </div>

          <p
            :if={step.status == :failed and @optimization.status == :paused}
            class="mt-2 text-caption text-ink-muted"
          >
            A falha pausou a rodada. Retomar tenta esta etapa de novo — as anteriores ficam.
          </p>

          <p
            :if={step.consult && step.consult.response["leitura"]}
            class="mt-3 border-l-2 border-hairline-strong pl-3 text-caption italic text-ink-muted"
          >
            {step.consult.response["leitura"]}
          </p>

          <p
            :if={step.status == :done and step.applied == [] and step.rejected == []}
            class="mt-3 text-caption text-ink-muted"
          >
            Nenhuma mudança — o modelo olhou e não propôs nada.
          </p>

          <div :if={step.applied != []} class="mt-3">
            <h3 class="mb-1 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
              Aplicadas
            </h3>
            <ul class="space-y-1">
              <li :for={change <- step.applied} class="text-caption text-ink-secondary">
                <span class={[
                  "font-mono",
                  change["action"] == "add" && "text-sev-healthy",
                  change["action"] == "cut" && "text-sev-critical"
                ]}>
                  {if change["action"] == "add", do: "+", else: "−"}
                </span>
                <span class="text-ink">{change["card"]}</span>
                <span class="text-ink-muted">— {change["reason"]}</span>
              </li>
            </ul>
          </div>

          <div :if={step.rejected != []} class="mt-3">
            <h3 class="mb-1 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
              Recusadas pelo motor
            </h3>
            <ul class="space-y-1">
              <li :for={change <- step.rejected} class="text-caption">
                <span class="text-ink-secondary">{change["card"]}</span>
                <span class="text-sev-critical">
                  — {Enum.join(change["problems"] || [], "; ")}
                </span>
              </li>
            </ul>
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
                "inline-flex size-11 items-center justify-center rounded-md transition-colors",
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
                "inline-flex size-11 items-center justify-center rounded-md transition-colors",
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
                "inline-flex size-11 items-center justify-center rounded-md transition-colors",
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
                class="min-h-11 w-full rounded-md border border-hairline-soft bg-inlay px-3 py-2 text-caption text-ink placeholder:text-ink-faint"
              />
              <button
                type="submit"
                class="-my-2 inline-flex min-h-11 items-center px-1 py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
              >
                guardar
              </button>
            </.form>

            <button
              type="button"
              phx-click="criar-deck"
              phx-value-step={step.id}
              phx-disable-with="criando…"
              data-confirm="Criar um deck novo com a lista desta etapa?"
              class="-my-2 inline-flex min-h-11 items-center whitespace-nowrap px-1 py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
            >
              Criar deck deste ponto
            </button>
          </div>
        </li>
      </ol>

      <section :if={@optimization.status == :done} class="mt-10">
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

          <ul class="space-y-1">
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
              <span class="text-ink">{change["card"]}</span>
              <span :if={price = add_price(change)} class="font-mono text-ink-faint">{price}</span>
              <span class="text-ink-muted">— {change["reason"]}</span>
            </li>
          </ul>

          <details class="mt-4 border-t border-hairline-soft pt-4">
            <summary class="cursor-pointer text-caption text-ink-faint hover:text-ink">
              Lista final para copiar
            </summary>
            <button
              id="copiar-lista"
              type="button"
              phx-hook=".CopyList"
              data-target="lista-final"
              class="-my-2 mt-1 inline-flex min-h-11 items-center px-1 py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
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
              class="mt-2 w-full rounded-md border border-hairline-soft bg-inlay px-3 py-2 font-mono text-caption text-ink"
            >{Optimizations.list_to_text(Optimizations.current_list(@optimization), Optimizations.current_commanders(@optimization))}</textarea>
          </details>
        </div>
      </section>
    </div>
    """
  end
end
