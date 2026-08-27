defmodule DeckexWeb.BancadaLive do
  @moduledoc """
  A Bancada: the screen where the owner fills the vacancies himself.

  Two ways through the same state, and both are his. **Triagem** is one vacancy
  at a time under the biggest art the screen can hold, driven from the keyboard;
  it is where the rhythm is. **O quadro** is everything at once, grouped by the
  reason it belongs to; it is where the thinking is. Neither is a mode he has to
  finish — the toggle costs nothing and no decision is lost either way.

  The rail is the point. Every click recomputes the deck's real report and the
  engine's real audit, so `Cartas 101/100`, `Críticos 2 → 1` and the money are
  the same numbers that will decide the round, moving because of something he
  just did. Nothing here is a separate scoring system invented for a screen.
  """
  use DeckexWeb, :live_view

  alias Deckex.Analysis.Report
  alias Deckex.Budget
  alias Deckex.Decks
  alias Deckex.Error
  alias Deckex.Money
  alias Deckex.Optimizations
  alias Deckex.Optimizations.Balance
  alias Deckex.Optimizations.Curation

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    with {:ok, optimization} <- Optimizations.fetch(id),
         step when not is_nil(step) <- Optimizations.open_gate(optimization),
         false <- step.kind == :visao do
      {:ok, load(socket, optimization, step)}
    else
      {:error, %Error{} = error} ->
        {:ok, socket |> put_flash(:error, error.message) |> push_navigate(to: ~p"/")}

      _no_board_here ->
        {:ok,
         socket
         |> put_flash(:info, "Essa rodada não está esperando você na Bancada.")
         |> push_navigate(to: ~p"/otimizacoes/#{id}")}
    end
  end

  defp load(socket, optimization, step) do
    {:ok, deck} = Decks.fetch_deck(optimization.deck_id)
    vacancies = Optimizations.vacancies(optimization, step)

    socket
    |> assign(
      optimization: optimization,
      deck: deck,
      step: step,
      vacancies: vacancies,
      # Depends on nothing he can change while he works, so it is measured once
      # and then only read.
      preflight: Optimizations.preflight(optimization, step, deck, vacancies),
      phase: :triagem,
      cursor: 0,
      page_title: "A Bancada — #{deck.name}"
    )
    |> measure()
    |> then(&assign(&1, cursor: first_undecided(&1)))
  end

  # Everything derived from the selections, in one place, so a click can never
  # move the board and leave the rail behind.
  defp measure(socket) do
    %{optimization: optimization, step: step, deck: deck, vacancies: vacancies} = socket.assigns

    assign(socket,
      preview: Optimizations.preview(optimization, step, deck, vacancies),
      visible: Curation.visible(step, vacancies),
      reserve_open?: Curation.reserve_open?(step, vacancies)
    )
  end

  # He arrives where the work is, not at the top of a list he already answered.
  defp first_undecided(socket) do
    %{step: step, visible: visible} = socket.assigns

    Enum.find_index(visible, &(Curation.decision(step, &1) == :undecided)) || 0
  end

  @impl Phoenix.LiveView
  def handle_event("escolher", %{"vaga" => key, "carta" => name}, socket) do
    {:noreply, socket |> decide(key, name) |> advance_after_choice()}
  end

  def handle_event("pular", %{"vaga" => key}, socket) do
    {:noreply, socket |> decide(key, nil) |> advance_after_choice()}
  end

  def handle_event("limpar", %{"vaga" => key}, socket) do
    vacancy = Enum.find(socket.assigns.vacancies, &(&1.key == key))
    {:ok, step} = Optimizations.unselect(socket.assigns.step, vacancy)

    {:noreply, socket |> assign(step: step) |> measure()}
  end

  def handle_event("ir", %{"para" => "proxima"}, socket) do
    {:noreply, move(socket, 1)}
  end

  def handle_event("ir", %{"para" => "anterior"}, socket) do
    {:noreply, move(socket, -1)}
  end

  def handle_event("ir", %{"para" => index}, socket) do
    {:noreply, assign(socket, phase: :triagem, cursor: to_index(index, socket))}
  end

  def handle_event("fase", %{"fase" => "quadro"}, socket) do
    {:noreply, assign(socket, phase: :quadro)}
  end

  def handle_event("fase", %{"fase" => "triagem"}, socket) do
    {:noreply, assign(socket, phase: :triagem)}
  end

  # The keyboard's numbers pick the nth candidate of whatever is on screen; 0
  # skips. Sent by position rather than by name so the hook never has to know
  # what a card is called.
  def handle_event("tecla", %{"n" => n}, socket) do
    case Enum.at(socket.assigns.visible, socket.assigns.cursor) do
      nil ->
        {:noreply, socket}

      vacancy ->
        case Enum.at(vacancy.candidatos, n - 1) do
          nil ->
            {:noreply, socket}

          candidate ->
            {:noreply, socket |> decide(vacancy.key, candidate.name) |> advance_after_choice()}
        end
    end
  end

  def handle_event("fechar", _params, socket) do
    case Optimizations.commit(socket.assigns.optimization, socket.assigns.vacancies) do
      {:ok, optimization} ->
        {:noreply,
         socket
         |> put_flash(:info, closing_flash(optimization))
         |> push_navigate(to: ~p"/otimizacoes/#{optimization.id}")}

      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  defp decide(socket, key, name) do
    vacancy = Enum.find(socket.assigns.vacancies, &(&1.key == key))
    {:ok, step} = Optimizations.select(socket.assigns.step, vacancy, name)

    socket |> assign(step: step) |> measure()
  end

  # A decision moves him on, because the whole point of triage is rhythm. It
  # stops at the end rather than wrapping: arriving back at vacancy one reads
  # as having lost the list.
  defp advance_after_choice(%{assigns: %{phase: :quadro}} = socket), do: socket

  defp advance_after_choice(socket) do
    move(socket, 1, :stop_at_end)
  end

  defp move(socket, delta, mode \\ :allow_edges) do
    last = max(length(socket.assigns.visible) - 1, 0)
    next = socket.assigns.cursor + delta

    cursor =
      case mode do
        :stop_at_end -> min(next, last)
        :allow_edges -> next |> max(0) |> min(last)
      end

    assign(socket, cursor: max(cursor, 0))
  end

  defp to_index(index, socket) do
    case Integer.parse(index) do
      {parsed, _rest} -> parsed |> max(0) |> min(max(length(socket.assigns.visible) - 1, 0))
      :error -> socket.assigns.cursor
    end
  end

  defp closing_flash(optimization) do
    case optimization.status do
      :running -> "Fechado. O crítico está lendo a sua lista."
      _finished -> "Fechado. A rodada acabou."
    end
  end

  # ── reading the state ─────────────────────────────────────────────────────

  defp decided_count(step, vacancies) do
    length(vacancies) - Curation.undecided(step, vacancies)
  end

  defp count_tone(count) do
    if count == Balance.target(), do: :healthy, else: :critical
  end

  defp criticals(%{audit: audit}) do
    {Report.critical_count(audit.before_report), Report.critical_count(audit.after_report)}
  end

  defp criticals_tone({before_count, now}) do
    cond do
      now < before_count -> :healthy
      now > before_count -> :critical
      true -> :neutral
    end
  end

  defp histogram(%{audit: audit}), do: audit.after_report.curve.histogram

  defp curve_max(histogram) do
    histogram |> Map.values() |> Enum.max(fn -> 1 end) |> max(1)
  end

  # Two audits answer two different questions, and the board needs both. The
  # pre-flight says what is wrong with this card at all — illegal in these
  # colours, past the ceiling, already in the deck — and it says so before the
  # click. The live one adds what is only true of the set he has assembled:
  # that this add spends the second of his two exception slots.
  defp verdict(assigns, vacancy, candidate) do
    Optimizations.verdict(assigns.preflight, vacancy.action, candidate.name) ||
      Optimizations.verdict(assigns.preview.audit, vacancy.action, candidate.name)
  end

  defp chosen?(step, vacancy, candidate), do: Curation.decision(step, vacancy) == candidate.name

  # A vacancy is one card or none, so choosing is also *not* choosing the other
  # two — and the screen says both halves. The dimming is the answer arriving,
  # not decoration: it is why a pick reads from across the room.
  defp passed_over?(step, vacancy, candidate) do
    case Curation.decision(step, vacancy) do
      :undecided -> false
      name -> name != candidate.name
    end
  end

  defp skipped?(step, vacancy), do: Curation.decision(step, vacancy) == nil

  defp groups(step, vacancies, action) do
    vacancies
    |> Enum.filter(&(&1.action == action))
    |> Enum.group_by(& &1.grupo)
    |> Enum.sort_by(fn {grupo, rows} -> {-decided_count(step, rows), grupo} end)
  end

  defp action_heading(:cut), do: "Sai do deck"
  defp action_heading(:add), do: "Entra no deck"

  defp gate_heading(:cardapio), do: "A Bancada"
  defp gate_heading(_critic), do: "O crítico respondeu"

  defp gate_note(:cardapio) do
    "Cada vaga é um problema do deck com duas ou três respostas. Escolha uma, ou nenhuma."
  end

  defp gate_note(_critic) do
    "Ele leu a sua lista e propôs estas correções. Aceite as que fizerem sentido — recusar todas também fecha a rodada."
  end

  # nil rather than "" when both tiers are switched off: an empty sub-line is
  # still a sub-line, and the tile would keep space for a sentence nobody wrote.
  defp exception_line(%{occupancy: %{occupancy: occupancy, policy: policy}}) do
    case Enum.reject(
           [
             tier_line(occupancy.expensive, policy.expensive, "acima de"),
             tier_line(occupancy.exception, policy.exception, "exceções acima de")
           ],
           &is_nil/1
         ) do
      [] -> nil
      lines -> Enum.join(lines, " · ")
    end
  end

  defp tier_line(_count, %{threshold: nil}, _label), do: nil
  defp tier_line(_count, %{max: nil}, _label), do: nil

  defp tier_line(count, %{threshold: threshold, max: max}, label) do
    "#{count}/#{max} #{label} R$ #{threshold}"
  end

  defp over_budget?(%{occupancy: %{occupancy: occupancy, policy: policy}}) do
    not (Budget.room?(occupancy, :expensive, policy) or occupancy.expensive == 0) or
      not (Budget.room?(occupancy, :exception, policy) or occupancy.exception == 0)
  end

  # ── the page ──────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="min-h-dvh bg-felt">
      <header class="sticky top-0 z-20 border-b border-hairline bg-rail/95 backdrop-blur-sm">
        <div class="mx-auto flex max-w-[120rem] flex-wrap items-center gap-x-4 gap-y-1 px-4 py-2 sm:gap-y-2 sm:px-6 sm:py-3">
          <%!-- The title takes its own line before the controls squeeze it: a
                truncate that wins the fight leaves the page with no name at
                all, which is what happened at 375px. --%>
          <div class="flex w-full min-w-0 items-center gap-3 sm:w-auto sm:flex-1">
            <.link
              navigate={~p"/otimizacoes/#{@optimization.id}"}
              class="-my-2 inline-flex min-h-touch shrink-0 items-center gap-1.5 py-2 text-caption text-ink-faint transition-colors hover:text-ink motion-reduce:transition-none"
            >
              <.icon name="hero-arrow-left-micro" class="size-3.5" /> a rodada
            </.link>

            <h1 class="min-w-0 flex-1 truncate text-heading font-semibold text-ink">
              {gate_heading(@step.kind)}
              <span class="font-normal text-ink-faint">· {@deck.name}</span>
            </h1>
          </div>

          <p class="shrink-0 font-mono text-caption text-ink-muted">
            {decided_count(@step, @visible)} de {length(@visible)}
            <span class="font-sans text-ink-faint">decididas</span>
          </p>

          <div
            role="tablist"
            aria-label="Como decidir"
            class="flex shrink-0 rounded-md border border-hairline-soft bg-inlay p-0.5"
          >
            <button
              :for={{fase, label} <- [{:triagem, "Triagem"}, {:quadro, "Quadro"}]}
              type="button"
              role="tab"
              aria-selected={to_string(@phase == fase)}
              phx-click="fase"
              phx-value-fase={fase}
              class={[
                "min-h-touch rounded-sm px-3 text-caption transition-colors motion-reduce:transition-none",
                @phase == fase && "bg-surface-2 text-ink",
                @phase != fase && "text-ink-faint hover:text-ink-secondary"
              ]}
            >
              {label}
            </button>
          </div>
        </div>
      </header>

      <div class="mx-auto flex max-w-[120rem] flex-col gap-4 px-4 py-4 sm:gap-6 sm:px-6 sm:py-6 xl:flex-row xl:items-start xl:gap-8">
        <main class="min-w-0 flex-1">
          <.triagem
            :if={@phase == :triagem}
            step={@step}
            visible={@visible}
            cursor={@cursor}
            verdicts={%{preflight: @preflight, preview: @preview}}
            gate={@step.kind}
          />
          <.quadro
            :if={@phase == :quadro}
            step={@step}
            visible={@visible}
            vacancies={@vacancies}
            reserve_open?={@reserve_open?}
            verdicts={%{preflight: @preflight, preview: @preview}}
            gate={@step.kind}
          />
        </main>

        <.rail preview={@preview} step={@step} visible={@visible} />
      </div>
    </div>
    """
  end

  # ── triage ────────────────────────────────────────────────────────────────

  attr :step, :map, required: true
  attr :visible, :list, required: true
  attr :cursor, :integer, required: true
  attr :verdicts, :map, required: true
  attr :gate, :atom, required: true

  defp triagem(assigns) do
    assigns = assign(assigns, vacancy: Enum.at(assigns.visible, assigns.cursor))

    ~H"""
    <div :if={is_nil(@vacancy)} class="rounded-xl border border-hairline-soft bg-surface p-8">
      <p class="text-lead text-ink">Não sobrou nenhuma vaga aqui.</p>
      <p class="mt-1 text-caption text-ink-muted">
        Feche a rodada no trilho ao lado, ou volte para o quadro.
      </p>
    </div>

    <div
      :if={@vacancy}
      id="triagem"
      phx-hook=".Teclado"
      phx-window-keydown="tecla"
    >
      <script :type={Phoenix.LiveView.ColocatedHook} name=".Teclado">
        // The number keys pick, 0 skips, the arrows walk. Sent by POSITION, so
        // the hook never learns what a card is called and the two halves cannot
        // drift. A keystroke inside a field is somebody typing, not choosing.
        export default {
          mounted() {
            this.onKey = (event) => {
              if (event.metaKey || event.ctrlKey || event.altKey) return

              const tag = (event.target.tagName || "").toLowerCase()
              if (["input", "textarea", "select"].includes(tag) || event.target.isContentEditable) return

              const key = event.key

              if (["1", "2", "3", "4"].includes(key)) {
                event.preventDefault()
                this.pushEvent("tecla", {n: Number(key)})
              } else if (key === "0") {
                event.preventDefault()
                this.pushEvent("tecla", {n: 0})
              } else if (key === "ArrowLeft") {
                event.preventDefault()
                this.pushEvent("ir", {para: "anterior"})
              } else if (key === "ArrowRight") {
                event.preventDefault()
                this.pushEvent("ir", {para: "proxima"})
              }
            }

            window.addEventListener("keydown", this.onKey)
          },
          destroyed() {
            window.removeEventListener("keydown", this.onKey)
          }
        }
      </script>

      <div class="flex flex-wrap items-center gap-2">
        <span class={[
          "rounded-sm px-2 py-0.5 font-mono text-micro",
          @vacancy.action == :cut && "bg-chip text-ink-secondary",
          @vacancy.action == :add && "bg-surface-2 text-ink-secondary"
        ]}>
          {action_heading(@vacancy.action)}
        </span>
        <span class="rounded-sm border border-hairline-soft px-2 py-0.5 font-mono text-micro text-ink-faint">
          {@vacancy.grupo}
        </span>
        <span :if={@vacancy.reserve?} class="font-mono text-micro text-ink-faint">
          reserva
        </span>
        <span class="ml-auto font-mono text-micro text-ink-faint">
          {@cursor + 1} de {length(@visible)}
        </span>
      </div>

      <%!-- The question, and the biggest type on the page. It steps down on a
            phone because six lines of 26px is a paragraph, not a headline. --%>
      <p class="mt-3 max-w-[65ch] text-heading font-semibold leading-tight text-balance text-ink sm:text-title">
        {@vacancy.vaga}
      </p>

      <ul class={[
        "mt-6 grid gap-4 sm:grid-cols-2",
        length(@vacancy.candidatos) > 2 && "lg:grid-cols-3"
      ]}>
        <li :for={{candidate, index} <- Enum.with_index(@vacancy.candidatos, 1)} class="min-w-0">
          <.candidato
            vacancy={@vacancy}
            candidate={candidate}
            index={index}
            chosen={chosen?(@step, @vacancy, candidate)}
            dimmed={passed_over?(@step, @vacancy, candidate)}
            verdict={verdict(@verdicts, @vacancy, candidate)}
            big
          />
        </li>
      </ul>

      <div class="mt-6 flex flex-wrap items-center gap-3">
        <button
          type="button"
          phx-click="pular"
          phx-value-vaga={@vacancy.key}
          class={[
            "inline-flex min-h-touch items-center gap-2 rounded-md border px-4 text-body transition-colors motion-reduce:transition-none",
            skipped?(@step, @vacancy) &&
              "border-hairline-strong bg-surface-2 text-ink",
            !skipped?(@step, @vacancy) &&
              "border-hairline-soft text-ink-faint hover:border-hairline-strong hover:text-ink"
          ]}
        >
          {if skipped?(@step, @vacancy), do: "Nenhuma destas ✓", else: "Nenhuma destas"}
          <kbd class="rounded-xs border border-hairline-soft px-1.5 font-mono text-micro text-ink-faint">
            0
          </kbd>
        </button>

        <button
          :if={Curation.decision(@step, @vacancy) != :undecided}
          type="button"
          phx-click="limpar"
          phx-value-vaga={@vacancy.key}
          class="-my-2 inline-flex min-h-touch items-center px-1 py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink motion-reduce:transition-none"
        >
          desfazer
        </button>

        <p class="hidden items-center gap-2 font-mono text-micro text-ink-faint sm:flex">
          <kbd class="rounded-xs border border-hairline-soft px-1.5">1</kbd>–<kbd class="rounded-xs border border-hairline-soft px-1.5">3</kbd>
          escolhe · <kbd class="rounded-xs border border-hairline-soft px-1.5">←</kbd>
          <kbd class="rounded-xs border border-hairline-soft px-1.5">→</kbd>
          navega
        </p>

        <div class="ml-auto flex items-center gap-2">
          <button
            type="button"
            phx-click="ir"
            phx-value-para="anterior"
            disabled={@cursor == 0}
            aria-label="Vaga anterior"
            class="inline-flex size-touch items-center justify-center rounded-md border border-hairline-soft text-ink-faint transition-colors hover:text-ink disabled:opacity-40 disabled:hover:text-ink-faint motion-reduce:transition-none"
          >
            <.icon name="hero-arrow-left-micro" class="size-4" />
          </button>
          <button
            type="button"
            phx-click="ir"
            phx-value-para="proxima"
            disabled={@cursor >= length(@visible) - 1}
            aria-label="Próxima vaga"
            class="inline-flex size-touch items-center justify-center rounded-md border border-hairline-soft text-ink-faint transition-colors hover:text-ink disabled:opacity-40 disabled:hover:text-ink-faint motion-reduce:transition-none"
          >
            <.icon name="hero-arrow-right-micro" class="size-4" />
          </button>
        </div>
      </div>

      <p class="mt-5 max-w-[65ch] border-t border-hairline pt-4 text-caption leading-relaxed text-ink-muted">
        {gate_note(@gate)}
      </p>
    </div>
    """
  end

  # ── the board ─────────────────────────────────────────────────────────────

  attr :step, :map, required: true
  attr :visible, :list, required: true
  attr :vacancies, :list, required: true
  attr :reserve_open?, :boolean, required: true
  attr :verdicts, :map, required: true
  attr :gate, :atom, required: true

  defp quadro(assigns) do
    ~H"""
    <div class="space-y-10">
      <section :for={action <- [:cut, :add]}>
        <h2 class="text-heading font-semibold text-ink">{action_heading(action)}</h2>

        <div class="mt-4 grid gap-x-8 gap-y-6 lg:grid-cols-2 2xl:grid-cols-3">
          <section :for={{grupo, rows} <- groups(@step, @visible, action)} class="min-w-0">
            <h3 class="flex items-baseline gap-2 border-b border-hairline pb-1.5">
              <span class="text-label uppercase tracking-[0.1em] text-ink-secondary">{grupo}</span>
              <span class="font-mono text-micro text-ink-faint">
                {decided_count(@step, rows)}/{length(rows)}
              </span>
            </h3>

            <ul class="mt-4 space-y-4">
              <li :for={vacancy <- rows} class="min-w-0">
                <p class="max-w-[65ch] text-body leading-relaxed text-ink-secondary">
                  {vacancy.vaga}
                </p>

                <ul class="mt-2 flex flex-wrap gap-2">
                  <li :for={{candidate, index} <- Enum.with_index(vacancy.candidatos, 1)}>
                    <.candidato
                      vacancy={vacancy}
                      candidate={candidate}
                      index={index}
                      chosen={chosen?(@step, vacancy, candidate)}
                      dimmed={passed_over?(@step, vacancy, candidate)}
                      verdict={verdict(@verdicts, vacancy, candidate)}
                    />
                  </li>
                  <li>
                    <button
                      type="button"
                      phx-click="pular"
                      phx-value-vaga={vacancy.key}
                      class={[
                        "inline-flex min-h-touch items-center rounded-md border px-3 text-caption transition-colors motion-reduce:transition-none",
                        skipped?(@step, vacancy) && "border-hairline-strong bg-surface-2 text-ink",
                        !skipped?(@step, vacancy) &&
                          "border-hairline-soft text-ink-faint hover:text-ink"
                      ]}
                    >
                      nenhuma
                    </button>
                  </li>
                </ul>
              </li>
            </ul>
          </section>

          <p
            :if={groups(@step, @visible, action) == []}
            class="text-caption text-ink-muted lg:col-span-2 2xl:col-span-3"
          >
            Nenhuma vaga deste lado nesta rodada.
          </p>
        </div>
      </section>

      <p
        :if={!@reserve_open? and Enum.any?(@vacancies, & &1.reserve?)}
        class="border-t border-hairline pt-4 text-caption leading-relaxed text-ink-muted"
      >
        Tem {Enum.count(@vacancies, & &1.reserve?)} vagas de corte na reserva. Elas abrem sozinhas
        quando você levar mais entradas do que cortes.
      </p>
    </div>
    """
  end

  # ── one candidate ─────────────────────────────────────────────────────────

  attr :vacancy, :map, required: true
  attr :candidate, :map, required: true
  attr :index, :integer, required: true
  attr :chosen, :boolean, required: true
  attr :dimmed, :boolean, default: false
  attr :verdict, :any, default: nil
  attr :big, :boolean, default: false

  defp candidato(assigns) do
    assigns = assign(assigns, problem: match?({:problem, _sentence}, assigns.verdict))

    ~H"""
    <button
      :if={@big}
      type="button"
      phx-click="escolher"
      phx-value-vaga={@vacancy.key}
      phx-value-carta={@candidate.name}
      aria-pressed={to_string(@chosen)}
      class={[
        "group block w-full overflow-hidden rounded-card border text-left transition-[border-color,box-shadow,background-color,opacity,filter] duration-200 ease-out motion-reduce:transition-none",
        @chosen && "border-ink bg-surface-2 shadow-lifted ring-1 ring-ink",
        !@chosen && "border-hairline bg-surface shadow-contact hover:border-hairline-strong",
        @dimmed && "opacity-45 grayscale-[0.4]",
        @problem && !@dimmed && "opacity-60"
      ]}
    >
      <div class="relative aspect-art w-full bg-inlay">
        <img
          :if={@candidate.card && @candidate.card.image_art_crop_url}
          src={@candidate.card.image_art_crop_url}
          alt={@candidate.name}
          loading="lazy"
          class={[
            "h-full w-full object-cover transition-transform duration-300 ease-out motion-reduce:transition-none",
            @chosen && "scale-[1.03]"
          ]}
        />
        <div
          :if={!(@candidate.card && @candidate.card.image_art_crop_url)}
          class="flex h-full w-full items-center justify-center px-4 text-center"
        >
          <span class="text-caption leading-snug text-ink-faint">{@candidate.name}</span>
        </div>

        <span class={[
          "absolute left-2 top-2 inline-flex size-6 items-center justify-center rounded-sm font-mono text-micro",
          @chosen && "bg-ink text-felt",
          !@chosen && "bg-inlay/85 text-ink-secondary"
        ]}>
          {if @chosen, do: "✓", else: @index}
        </span>
      </div>

      <div class="border-t border-hairline px-3 py-2.5">
        <div class="flex items-start justify-between gap-2">
          <p class="min-w-0 text-body-lg font-semibold leading-snug text-ink">{@candidate.name}</p>
          <.mana_cost
            :if={@candidate.card && @candidate.card.mana_cost}
            cost={@candidate.card.mana_cost}
            size={15}
            class="mt-px shrink-0"
          />
        </div>

        <p :if={@candidate.card} class="mt-1 truncate text-caption text-ink-muted">
          {@candidate.card.type_line}
        </p>

        <p class="mt-2 flex flex-wrap items-baseline gap-x-2 gap-y-1">
          <span class="font-mono text-numeral-sm leading-none text-ink-secondary">
            {Money.brl(@candidate.price_usd)}
          </span>
          <.play_rate :if={@candidate.card} card={@candidate.card} />
        </p>

        <p class="mt-2.5 text-caption leading-relaxed text-ink-secondary">{@candidate.porque}</p>

        <p :if={!@candidate.resolved?} class="mt-2 text-caption text-sev-warning">
          o catálogo ainda não tem essa carta
        </p>

        <.veredito verdict={@verdict} class="mt-2" />
      </div>
    </button>

    <button
      :if={!@big}
      type="button"
      phx-click="escolher"
      phx-value-vaga={@vacancy.key}
      phx-value-carta={@candidate.name}
      aria-pressed={to_string(@chosen)}
      title={@candidate.porque}
      class={[
        "flex min-h-touch max-w-full flex-col justify-center gap-0.5 rounded-md border px-3 py-1.5 text-left text-caption transition-colors motion-reduce:transition-none",
        @chosen && "border-ink bg-surface-2 text-ink",
        !@chosen &&
          "border-hairline-soft text-ink-secondary hover:border-hairline-strong hover:text-ink",
        @dimmed && "opacity-50",
        @problem && !@dimmed && "opacity-60"
      ]}
    >
      <span class="flex items-center gap-2">
        <span class="truncate font-sans">{@candidate.name}</span>
        <span class="shrink-0 font-mono text-micro text-ink-faint">
          {Money.brl(@candidate.price_usd)}
        </span>
        <span :if={@chosen} class="shrink-0 font-mono text-micro text-ink">✓</span>
      </span>
      <%!-- The board says why before the click, exactly like triage does. A
            candidate dimmed with no reason attached is the engine refusing in
            silence, which is the one thing the audit was built not to do. --%>
      <.veredito verdict={@verdict} />
    </button>
    """
  end

  attr :verdict, :any, required: true
  attr :class, :any, default: nil

  defp veredito(%{verdict: nil} = assigns), do: ~H""

  defp veredito(%{verdict: {kind, sentence}} = assigns) do
    assigns = assign(assigns, kind: kind, sentence: sentence)

    ~H"""
    <p class={[
      "flex items-start gap-1.5 text-caption leading-snug",
      @kind == :problem && "text-sev-critical",
      @kind == :note && "text-sev-warning",
      @class
    ]}>
      <span
        class="mt-1.5 size-1.5 shrink-0 rounded-full bg-current"
        aria-hidden="true"
      />
      <span class="min-w-0">{@sentence}</span>
    </p>
    """
  end

  # ── the rail ──────────────────────────────────────────────────────────────

  attr :preview, :map, required: true
  attr :step, :map, required: true
  attr :visible, :list, required: true

  defp rail(assigns) do
    assigns =
      assign(assigns,
        criticals: criticals(assigns.preview),
        histogram: histogram(assigns.preview)
      )

    ~H"""
    <%!-- Above the work on a narrow screen, beside it on a wide one — and
          sticky either way. A scoreboard you have to scroll to is a scoreboard
          that is not moving while you play, and on a phone the full-height
          version of it covered the very thing it was reporting on. So the
          numerals step down, the sub-lines fold away, and the curve waits for
          a screen with room for it. --%>
    <aside class="order-first w-full shrink-0 xl:order-none xl:w-[21rem]">
      <div class="sticky top-[3.25rem] z-10 space-y-2.5 rounded-xl border border-hairline-soft bg-rail p-3 xl:top-[4.5rem] xl:space-y-3 xl:p-4">
        <div class="grid grid-cols-3 gap-2 xl:grid-cols-2 xl:gap-3">
          <.placar
            label="Cartas"
            value={Integer.to_string(@preview.count)}
            tone={count_tone(@preview.count)}
          >
            <:note>de {Balance.target()}</:note>
          </.placar>

          <.placar
            label="Críticos"
            value={"#{elem(@criticals, 0)} → #{elem(@criticals, 1)}"}
            tone={criticals_tone(@criticals)}
          />

          <.placar
            label="Entradas"
            value={Money.brl(@preview.spend_usd)}
            tone={if over_budget?(@preview), do: :warning, else: :neutral}
            class="xl:col-span-2"
          >
            <:note :if={line = exception_line(@preview)}>{line}</:note>
          </.placar>
        </div>

        <div class="hidden rounded-lg border border-hairline bg-surface px-3 pb-2 pt-3 xl:block">
          <p class="text-label uppercase tracking-[0.1em] text-ink-faint">A curva agora</p>
          <div class="mt-2.5 grid grid-cols-8 items-end gap-1.5">
            <.curve_bar
              :for={bucket <- 0..7}
              label={if bucket == 7, do: "7+", else: to_string(bucket)}
              count={Map.get(@histogram, bucket, 0)}
              max={curve_max(@histogram)}
              height={64}
            />
          </div>
        </div>

        <div class="border-t border-hairline pt-2.5 xl:pt-3">
          <p :if={@preview.blocker} class="mb-2 text-caption leading-snug text-sev-critical">
            {@preview.blocker}
          </p>
          <p
            :if={is_nil(@preview.blocker) and @preview.undecided > 0}
            class="mb-2 text-caption leading-snug text-ink-muted"
          >
            A conta fecha. Ainda tem {@preview.undecided} vagas sem resposta — fechar agora as descarta.
          </p>

          <.button
            type="button"
            phx-click="fechar"
            phx-disable-with="fechando…"
            variant="primary"
            disabled={not is_nil(@preview.blocker)}
            class="w-full"
          >
            Fechar a rodada
          </.button>

          <p class="mt-2 hidden text-caption leading-snug text-ink-muted xl:block">
            {commit_note(@step.kind)}
          </p>
        </div>
      </div>
    </aside>
    """
  end

  # One number on the scoreboard. A cousin of `DeckexWeb.UI.stat/1` rather than
  # a call to it: the rail has to put three of these across a 375px screen, and
  # a tile whose numeral cannot step down is a tile that pushes the work it is
  # reporting on off the page.
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :tone, :atom, values: [:neutral, :critical, :warning, :healthy], default: :neutral
  attr :class, :any, default: nil
  slot :note

  defp placar(assigns) do
    ~H"""
    <div
      class={["min-w-0 rounded-lg border bg-surface px-2.5 py-2 xl:px-4 xl:py-3", @class]}
      style={"--c:#{tone_var(@tone)};border-color:#{placar_border(@tone)}"}
    >
      <p class="truncate text-label font-semibold uppercase tracking-[0.12em] text-ink-faint">
        {@label}
      </p>
      <p
        class="mt-1 truncate font-mono text-numeral-sm font-semibold leading-none xl:mt-2 xl:text-numeral"
        style="color:var(--c)"
      >
        {@value}
      </p>
      <p :if={@note != []} class="mt-1.5 hidden text-caption leading-snug text-ink-faint xl:block">
        {render_slot(@note)}
      </p>
    </div>
    """
  end

  defp tone_var(:neutral), do: "var(--ink)"
  defp tone_var(tone), do: "var(--sev-#{tone})"

  # Only an alarm tints its edge, exactly like the stat tile it is a cousin of.
  defp placar_border(tone) when tone in [:critical, :warning],
    do: "color-mix(in srgb, var(--c) 32%, transparent)"

  defp placar_border(_tone), do: "var(--hairline)"

  defp commit_note(:cardapio) do
    "O motor audita as suas escolhas e o crítico lê a lista. Uma consulta."
  end

  defp commit_note(_critic), do: "Última etapa: isso encerra a rodada. Nenhuma consulta."
end
