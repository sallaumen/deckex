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

  **A card is judged on its rules text.** That is the law the briefing already
  states — the worst misreadings on record all came from a stage reading a name
  and a type line — and it applies to a person exactly as it applies to a model.
  Every candidate carries its oracle text, so the choice is made on what the
  card does rather than on whether he remembers it.
  """
  use DeckexWeb, :live_view

  alias Deckex.Analysis.Report
  alias Deckex.Budget
  alias Deckex.Cards.Card
  alias Deckex.Cards.Name
  alias Deckex.Decks
  alias Deckex.Decks.CardNote
  alias Deckex.Error
  alias Deckex.Money
  alias Deckex.Optimizations
  alias Deckex.Optimizations.Balance
  alias Deckex.Optimizations.Curation

  @filters [
    {:todas, "Todas"},
    {:indecisas, "Sem resposta"},
    {:escolhidas, "Escolhidas"},
    {:avisos, "Com aviso"}
  ]

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
      # What he has already said about these cards. The owner outranks the
      # pipeline about his own cards — the law the review stage wrote — and a
      # screen asking him to judge a cut owes him his own past correction.
      notes: Map.new(Decks.card_notes(deck), &{Name.normalize(&1.card_name), &1}),
      phase: :triagem,
      cursor: 0,
      filter: :todas,
      # The rules text is the reason to be here, so it opens by default; the
      # collapse exists for the second pass, when he already knows the cards.
      texto?: true,
      resumo?: false,
      atalhos?: false,
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

  # ── events ────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def handle_event("escolher", %{"vaga" => key, "carta" => name}, socket) do
    {:noreply, socket |> decide(key, name) |> advance_after_choice(key)}
  end

  def handle_event("pular", %{"vaga" => key}, socket) do
    {:noreply, socket |> decide(key, nil) |> advance_after_choice(key)}
  end

  def handle_event("limpar", %{"vaga" => key}, socket) do
    case Enum.find(socket.assigns.vacancies, &(&1.key == key)) do
      nil ->
        {:noreply, socket}

      vacancy ->
        {:ok, step} = Optimizations.unselect(socket.assigns.step, vacancy)

        # Undoing the add that opened the reserve folds it back, and `visible`
        # shrinks under the cursor — clamp rather than point past the end.
        {:noreply, socket |> assign(step: step) |> measure() |> move(0)}
    end
  end

  def handle_event("ir", %{"para" => "proxima"}, socket), do: {:noreply, move(socket, 1)}
  def handle_event("ir", %{"para" => "anterior"}, socket), do: {:noreply, move(socket, -1)}

  def handle_event("ir", %{"para" => "vaga", "chave" => key}, socket) do
    case Enum.find_index(socket.assigns.visible, &(&1.key == key)) do
      nil -> {:noreply, socket}
      index -> {:noreply, assign(socket, phase: :triagem, cursor: index)}
    end
  end

  def handle_event("fase", %{"fase" => fase}, socket) when fase in ~w(triagem quadro) do
    {:noreply, assign(socket, phase: String.to_existing_atom(fase), atalhos?: false)}
  end

  def handle_event("filtrar", %{"filtro" => filtro}, socket)
      when filtro in ~w(todas indecisas escolhidas avisos) do
    {:noreply, assign(socket, filter: String.to_existing_atom(filtro))}
  end

  def handle_event("filtrar", _junk, socket), do: {:noreply, socket}

  def handle_event("texto", _params, socket) do
    {:noreply, assign(socket, texto?: not socket.assigns.texto?)}
  end

  def handle_event("resumo", _params, socket) do
    {:noreply, assign(socket, resumo?: not socket.assigns.resumo?)}
  end

  def handle_event("atalhos", _params, socket) do
    {:noreply, assign(socket, atalhos?: not socket.assigns.atalhos?)}
  end

  # Idempotent on purpose: Escape, click-away and the X can land in any
  # combination, and a toggle that fires twice reopens what it closed.
  def handle_event("fechar-atalhos", _params, socket) do
    {:noreply, assign(socket, atalhos?: false)}
  end

  # The keyboard's numbers pick the nth candidate of whatever is on screen; 0
  # skips. Sent by position rather than by name so the hook never has to know
  # what a card is called.
  # Guarded to positive integers: `Enum.at/2` wraps a negative index to the
  # END of the list, so an unguarded `n: 0` silently picked the *last*
  # candidate — a selection he never made, which is the one failure this whole
  # screen exists to prevent.
  def handle_event("tecla", %{"n" => n}, socket) when is_integer(n) and n > 0 do
    with vacancy when not is_nil(vacancy) <-
           Enum.at(socket.assigns.visible, socket.assigns.cursor),
         candidate when not is_nil(candidate) <- Enum.at(vacancy.candidatos, n - 1) do
      {:noreply,
       socket |> decide(vacancy.key, candidate.name) |> advance_after_choice(vacancy.key)}
    else
      _no_vacancy_or_no_such_candidate -> {:noreply, socket}
    end
  end

  def handle_event("tecla", %{"acao" => "desfazer"}, socket) do
    case Enum.at(socket.assigns.visible, socket.assigns.cursor) do
      nil -> {:noreply, socket}
      vacancy -> handle_event("limpar", %{"vaga" => vacancy.key}, socket)
    end
  end

  def handle_event("tecla", %{"acao" => "pular"}, socket) do
    case Enum.at(socket.assigns.visible, socket.assigns.cursor) do
      nil -> {:noreply, socket}
      vacancy -> handle_event("pular", %{"vaga" => vacancy.key}, socket)
    end
  end

  def handle_event("tecla", %{"acao" => "fechar-paineis"}, socket) do
    {:noreply, assign(socket, atalhos?: false, resumo?: false)}
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

  # A window key listener hears **every** key, and only a handful mean anything
  # here. Without this clause the first time he pressed a letter the LiveView
  # raised `FunctionClauseError`, the process died, and the remount threw away
  # the cursor — measured, not imagined.
  def handle_event("tecla", _anything_else, socket), do: {:noreply, socket}

  defp decide(socket, key, name) do
    case Enum.find(socket.assigns.vacancies, &(&1.key == key)) do
      nil ->
        socket

      vacancy ->
        {:ok, step} = Optimizations.select(socket.assigns.step, vacancy, name)

        socket |> assign(step: step) |> measure()
    end
  end

  # A decision moves him on, because the whole point of triage is rhythm. It
  # advances from the KEY of the vacancy he answered, not from the cursor: a
  # pick that opens the reserve inserts cut vacancies before the adds, and a
  # numeric +1 landed him back on the vacancy he had just answered. It stops
  # at the end rather than wrapping — arriving back at vacancy one reads as
  # having lost the list.
  defp advance_after_choice(%{assigns: %{phase: :quadro}} = socket, _key), do: socket

  defp advance_after_choice(socket, key) do
    case key && Enum.find_index(socket.assigns.visible, &(&1.key == key)) do
      nil -> move(socket, 1, :stop_at_end)
      index -> assign(socket, cursor: min(index + 1, max(length(socket.assigns.visible) - 1, 0)))
    end
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

  defp closing_flash(optimization) do
    case optimization.status do
      :running -> "Fechado. O crítico está lendo a sua lista."
      _finished -> "Fechado. A rodada acabou."
    end
  end

  # ── reading the state ─────────────────────────────────────────────────────

  # The composition, said in the deck's own terms. The reserve is folded into
  # the cut count when hidden — the number he sees is the number he can answer.
  defp vagas_line(vacancies) do
    cuts = Enum.count(vacancies, &(&1.action == :cut))
    adds = Enum.count(vacancies, &(&1.action == :add))

    "#{cuts} vagas de possível corte · #{adds} de possível entrada"
  end

  defp decided_count(step, vacancies) do
    length(vacancies) - Curation.undecided(step, vacancies)
  end

  defp tallies(step, vacancies) do
    Enum.reduce(vacancies, %{escolhidas: 0, puladas: 0, indecisas: 0}, fn vacancy, acc ->
      case Curation.decision(step, vacancy) do
        :undecided -> Map.update!(acc, :indecisas, &(&1 + 1))
        nil -> Map.update!(acc, :puladas, &(&1 + 1))
        _card -> Map.update!(acc, :escolhidas, &(&1 + 1))
      end
    end)
  end

  defp count_tone(count), do: if(count == Balance.target(), do: :healthy, else: :critical)

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
    # The most specific truth about this exact pick comes first: a cut with no
    # copy left to take is legal, chosen, and inert — and a board that showed
    # it like any other cut was the board that said 106 for a list of 107.
    surplus_note(assigns, vacancy, candidate) ||
      Optimizations.verdict(assigns.preflight, vacancy.action, candidate.name) ||
      Optimizations.verdict(assigns.preview.audit, vacancy.action, candidate.name)
  end

  defp surplus_note(assigns, vacancy, candidate) do
    surplus = Map.get(assigns.preview, :surplus) || MapSet.new()

    if MapSet.member?(surplus, vacancy.key) and candidate.name == decision_name(assigns, vacancy) do
      {:note,
       "Esta cópia já sai por outra vaga — o deck não tem outra. " <>
         "A escolha fica, mas não mexe na conta."}
    end
  end

  defp decision_name(assigns, vacancy) do
    case Curation.decision(assigns.step, vacancy) do
      name when is_binary(name) -> name
      _skipped_or_undecided -> nil
    end
  end

  defp warned?(verdicts, vacancy) do
    Enum.any?(vacancy.candidatos, &(verdict(verdicts, vacancy, &1) != nil))
  end

  defp chosen_badge(:cut), do: "SAI ✓"
  defp chosen_badge(:add), do: "ENTRA ✓"

  defp verb(:cut), do: "Cortar"
  defp verb(:add), do: "Adicionar"

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

  # Sorted by action and position, and by nothing that changes while he works.
  # An earlier version ordered groups by how many were decided, which moved a
  # column out from under the cursor on every single click.
  defp groups(vacancies, action) do
    vacancies
    |> Enum.filter(&(&1.action == action))
    |> Enum.group_by(& &1.grupo)
    |> Enum.sort_by(fn {grupo, rows} -> {Enum.min_by(rows, & &1.index).index, grupo} end)
  end

  # ── the recap's classification ──────────────────────────────────────────────
  # The order a player scans a decklist in, not the alphabet's.
  @type_order [
    "Criaturas",
    "Instantâneas",
    "Feitiços",
    "Artefatos",
    "Encantamentos",
    "Planeswalkers",
    "Batalhas",
    "Terrenos",
    "Outras"
  ]

  defp recap_groups(chosen) do
    chosen
    |> Enum.group_by(&type_bucket(&1.card))
    |> Enum.sort_by(fn {tipo, _picks} -> Enum.find_index(@type_order, &(&1 == tipo)) end)
  end

  # First match wins, and creature comes first: a Dryad Arbor plays as a
  # creature to the person counting bodies, whatever else the type line says.
  @type_buckets [
    {"Creature", "Criaturas"},
    {"Land", "Terrenos"},
    {"Instant", "Instantâneas"},
    {"Sorcery", "Feitiços"},
    {"Planeswalker", "Planeswalkers"},
    {"Battle", "Batalhas"},
    {"Enchantment", "Encantamentos"},
    {"Artifact", "Artefatos"}
  ]

  # Front face only.
  defp type_bucket(%Card{type_line: line}) when is_binary(line) do
    front = line |> String.split("//") |> hd()

    Enum.find_value(@type_buckets, "Outras", fn {marker, tipo} ->
      String.contains?(front, marker) && tipo
    end)
  end

  defp type_bucket(_unresolved), do: "Outras"

  defp tally(picks, action), do: Enum.count(picks, &(&1.action == action))

  defp by_mana(picks, action) do
    picks
    |> Enum.filter(&(&1.action == action))
    |> Enum.sort_by(&{mana(&1), &1.name})
  end

  defp mana(%{card: %Card{cmc: %Decimal{} = cmc}}), do: cmc |> Decimal.to_float() |> trunc()
  defp mana(_unresolved), do: 99

  defp recap_totals(chosen) do
    adds = tally(chosen, :add)
    cuts = tally(chosen, :cut)
    saldo = adds - cuts

    "entram #{adds} · saem #{cuts} · saldo #{if saldo >= 0, do: "+#{saldo}", else: saldo}"
  end

  defp recap_note(pick) do
    mana = if pick.card && pick.card.cmc, do: "#{mana(pick)} mana"
    price = pick.price_usd && Money.brl(pick.price_usd)

    case Enum.filter([mana, price], & &1) do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  defp filtered(vacancies, step, verdicts, filter) do
    Enum.filter(vacancies, fn vacancy ->
      case filter do
        :todas -> true
        :indecisas -> Curation.decision(step, vacancy) == :undecided
        :escolhidas -> is_binary(Curation.decision(step, vacancy))
        :avisos -> warned?(verdicts, vacancy)
      end
    end)
  end

  defp direction_question(:cut), do: "Qual destas sai do deck?"
  defp direction_question(:add), do: "Qual destas entra no deck?"

  defp direction_ask(:cut),
    do: "Clicar numa carta é cortá-la. Se nenhuma merece sair, responda “nenhuma destas”."

  defp direction_ask(:add),
    do: "Clicar numa carta é adicioná-la. Se nenhuma convence, responda “nenhuma destas”."

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

  # His standing words about a card, when he has any. A bare `:wanted` on an
  # add candidate still speaks — he asked for this card by name — but a bare
  # `:locked` on a cut stays silent here: the audit already refuses that cut
  # out loud, and saying it twice reads as two rules instead of one.
  defp owner_line(nil, _action), do: nil

  defp owner_line(%CardNote{note: text}, _action) when is_binary(text) and text != "", do: text

  defp owner_line(%CardNote{stance: :wanted}, :add), do: "você pediu esta carta"

  defp owner_line(_bare_order, _action), do: nil

  defp power_toughness(%Card{power: p, toughness: t}) when is_binary(p) and is_binary(t),
    do: "#{p}/#{t}"

  defp power_toughness(_card), do: nil

  # ── the page ──────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="min-h-dvh bg-felt">
      <a
        href="#trabalho"
        class="sr-only focus:not-sr-only focus:absolute focus:left-4 focus:top-4 focus:z-50 focus:rounded-md focus:bg-ink focus:px-4 focus:py-2 focus:text-body focus:font-semibold focus:text-felt"
      >
        Pular para as vagas
      </a>

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
            <span class="font-sans text-ink-faint">vagas decididas</span>
          </p>

          <%!-- Not a tablist. A tablist owes the reader tabpanels and gives the
                arrow keys to itself, and the arrows here belong to the vacancy
                list. Two buttons that say which one is pressed owe nothing. --%>
          <div
            role="group"
            aria-label="Como decidir"
            class="flex shrink-0 rounded-md border border-hairline-soft bg-inlay p-0.5"
          >
            <button
              :for={{fase, label} <- [{:triagem, "Triagem"}, {:quadro, "Quadro"}]}
              type="button"
              aria-pressed={to_string(@phase == fase)}
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

          <button
            type="button"
            phx-click="atalhos"
            aria-expanded={to_string(@atalhos?)}
            aria-label="Atalhos de teclado"
            title="Atalhos de teclado"
            class="hidden size-touch shrink-0 items-center justify-center rounded-md border border-hairline-soft font-mono text-caption text-ink-faint transition-colors hover:text-ink motion-reduce:transition-none sm:inline-flex"
          >
            ?
          </button>
        </div>

        <.progresso step={@step} visible={@visible} />

        <%!-- The owner's first real board: he read "40" as "40 cards leaving
              the deck" and stopped, afraid each click was spending tokens.
              Both facts fit in one line, and both change how the screen
              feels: a vacancy is a QUESTION, and questions are free. --%>
        <p class="mx-auto flex max-w-[120rem] flex-wrap gap-x-2 px-4 py-1.5 text-micro text-ink-muted sm:px-6">
          <span>
            {vagas_line(@vacancies)} — cada vaga é uma pergunta, e "nenhuma" é resposta.
          </span>
          <span class="text-ink-faint">
            Nada aqui gasta consulta: só o Fechar, no fim, gasta uma.
          </span>
        </p>
      </header>

      <div
        id="bancada"
        phx-hook=".Teclado"
        class="mx-auto flex max-w-[120rem] flex-col gap-4 px-4 py-4 sm:gap-6 sm:px-6 sm:py-6 xl:flex-row xl:items-start xl:gap-8"
      >
        <script :type={Phoenix.LiveView.ColocatedHook} name=".Teclado">
          // The numbers pick, 0 skips, the arrows (or j/k) walk, u undoes, t/q
          // change phase, ? explains, Esc closes. Picks are sent by POSITION, so
          // the hook never learns what a card is called and the two halves cannot
          // drift. A keystroke inside a field is somebody typing, not choosing.
          export default {
            mounted() {
              this.onKey = (event) => {
                if (event.metaKey || event.ctrlKey || event.altKey) return

                const tag = (event.target.tagName || "").toLowerCase()
                if (["input", "textarea", "select"].includes(tag) || event.target.isContentEditable) return

                const key = event.key
                const send = (name, payload) => { event.preventDefault(); this.pushEvent(name, payload) }

                if (["1", "2", "3", "4"].includes(key)) return send("tecla", {n: Number(key)})
                if (key === "0") return send("tecla", {acao: "pular"})
                if (key === "u" || key === "U") return send("tecla", {acao: "desfazer"})
                if (key === "Escape") return send("tecla", {acao: "fechar-paineis"})
                if (key === "?") return send("atalhos", {})
                if (key === "t" || key === "T") return send("fase", {fase: "triagem"})
                if (key === "q" || key === "Q") return send("fase", {fase: "quadro"})
                if (key === "ArrowLeft" || key === "k" || key === "K") return send("ir", {para: "anterior"})
                if (key === "ArrowRight" || key === "j" || key === "J") return send("ir", {para: "proxima"})
              }

              window.addEventListener("keydown", this.onKey)
            },
            destroyed() {
              window.removeEventListener("keydown", this.onKey)
            }
          }
        </script>

        <%!-- The floating navigator is fixed to the viewport, so the work
              column reserves its height: at rest nothing of his — least of all
              card art, which this app never covers — sits underneath it. --%>
        <main id="trabalho" tabindex="-1" class="min-w-0 flex-1 pb-24">
          <.triagem
            :if={@phase == :triagem}
            step={@step}
            visible={@visible}
            cursor={@cursor}
            texto?={@texto?}
            notes={@notes}
            verdicts={%{preflight: @preflight, preview: @preview, step: @step}}
            gate={@step.kind}
          />
          <.quadro
            :if={@phase == :quadro}
            step={@step}
            visible={@visible}
            vacancies={@vacancies}
            filter={@filter}
            reserve_open?={@reserve_open?}
            preview={@preview}
            verdicts={%{preflight: @preflight, preview: @preview, step: @step}}
          />
        </main>

        <.rail
          preview={@preview}
          step={@step}
          visible={@visible}
          vacancies={@vacancies}
          resumo?={@resumo?}
        />
      </div>

      <.atalhos :if={@atalhos?} />
    </div>
    """
  end

  # ── progress ──────────────────────────────────────────────────────────────

  attr :step, :map, required: true
  attr :visible, :list, required: true

  defp progresso(assigns) do
    assigns = assign(assigns, tallies: tallies(assigns.step, assigns.visible))

    ~H"""
    <div
      class="flex h-1 w-full overflow-hidden bg-inlay"
      role="img"
      aria-label={"#{@tallies.escolhidas} escolhidas, #{@tallies.puladas} recusadas, #{@tallies.indecisas} sem resposta"}
    >
      <span
        :for={
          {kind, count} <- [
            {:escolhidas, @tallies.escolhidas},
            {:puladas, @tallies.puladas},
            {:indecisas, @tallies.indecisas}
          ]
        }
        class={[
          "h-full transition-[width] duration-300 ease-out motion-reduce:transition-none",
          kind == :escolhidas && "bg-sev-healthy",
          kind == :puladas && "bg-ink-disabled",
          kind == :indecisas && "bg-transparent"
        ]}
        style={"width:#{share(count, length(@visible))}%"}
      />
    </div>
    """
  end

  defp share(_count, 0), do: 0
  defp share(count, total), do: Float.round(count / total * 100, 2)

  # ── triage ────────────────────────────────────────────────────────────────

  attr :step, :map, required: true
  attr :visible, :list, required: true
  attr :cursor, :integer, required: true
  attr :texto?, :boolean, required: true
  attr :notes, :map, required: true
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

    <div :if={@vacancy}>
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
          vaga {@cursor + 1} de {length(@visible)}
        </span>
      </div>

      <%!-- A heading, not a paragraph: it is the question this screen is
            asking, and it is what a screen reader jumps between. The id
            changes with the cursor, so `phx-mounted` moves focus here on every
            move — otherwise a pick unmounts the button that had focus and the
            next Tab restarts from the top of the page. --%>
      <%!-- The QUESTION is the headline. It used to be the vacancy's prose —
            which on a real board runs four dense lines of plan reference at
            26px, sixty times, with the actual instruction in 12px underneath.
            The eye should land on what to do; the reasoning is what you read
            second, and it is still the second-loudest thing here. --%>
      <h2
        id={"vaga-#{@vacancy.key}"}
        tabindex="-1"
        phx-mounted={JS.focus()}
        class="mt-3 text-heading font-semibold leading-tight text-ink"
      >
        {direction_question(@vacancy.action)}
      </h2>

      <p class="mt-2 max-w-[65ch] text-lead leading-snug text-balance text-ink-secondary">
        {@vacancy.vaga}
      </p>

      <%!-- The mechanic, spelled out. The little "Sai do deck" chip above was
            not enough: on his first real board the owner could not tell
            whether choosing meant wanting or condemning. --%>
      <p class="mt-2 text-caption text-ink-faint">
        {direction_ask(@vacancy.action)}
      </p>

      <div class="mt-4 flex items-center gap-3">
        <button
          type="button"
          phx-click="texto"
          aria-pressed={to_string(@texto?)}
          class="-my-2 inline-flex min-h-touch items-center gap-1.5 py-2 text-caption text-ink-faint transition-colors hover:text-ink motion-reduce:transition-none"
        >
          <.icon
            name={if @texto?, do: "hero-eye-slash-micro", else: "hero-eye-micro"}
            class="size-3.5"
          />
          {if @texto?, do: "esconder o texto das cartas", else: "mostrar o texto das cartas"}
        </button>
      </div>

      <ul class={[
        "mt-3 grid gap-4 sm:grid-cols-2",
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
            texto?={@texto?}
            dono={owner_line(@notes[Name.normalize(candidate.name)], @vacancy.action)}
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
            skipped?(@step, @vacancy) && "border-hairline-strong bg-surface-2 text-ink",
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
          class="-my-2 inline-flex min-h-touch items-center gap-1.5 px-1 py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink motion-reduce:transition-none"
        >
          desfazer
          <kbd class="rounded-xs border border-hairline-soft px-1.5 font-mono text-micro no-underline">
            U
          </kbd>
        </button>
      </div>

      <%!-- FIXED to the viewport, because vacancies have different heights and
            buttons that ride the content move under a finger that is clicking
            through forty of them. Same screen spot, every vacancy. --%>
      <div class={
        [
          "fixed z-30 flex items-center gap-1 bg-rail/95 backdrop-blur-sm",
          # Phone: a real bottom bar — full width, opaque, inside the safe area,
          # under the thumb. The floating island version landed ON the card art,
          # which is the one thing this app never covers, and read as something
          # dropped on the page rather than as chrome.
          "inset-x-0 bottom-0 justify-center border-t border-hairline px-4 pt-3",
          "pb-[max(0.75rem,env(safe-area-inset-bottom))]",
          # From sm up there is margin beside the column, so it becomes the pill.
          "sm:inset-x-auto sm:bottom-5 sm:left-1/2 sm:-translate-x-1/2 sm:rounded-lg",
          "sm:border sm:border-hairline-soft sm:p-1 sm:pb-1 sm:pt-1 sm:shadow-lifted"
        ]
      }>
        <button
          type="button"
          phx-click="ir"
          phx-value-para="anterior"
          disabled={@cursor == 0}
          aria-label="Vaga anterior"
          class="inline-flex size-touch items-center justify-center rounded-md text-ink-secondary transition-colors hover:text-ink disabled:opacity-40 disabled:hover:text-ink-secondary motion-reduce:transition-none"
        >
          <.icon name="hero-arrow-left-micro" class="size-4" />
        </button>
        <span class="px-1 font-mono text-micro tabular-nums text-ink-faint">
          {@cursor + 1}/{length(@visible)}
        </span>
        <button
          type="button"
          phx-click="ir"
          phx-value-para="proxima"
          disabled={@cursor >= length(@visible) - 1}
          aria-label="Próxima vaga"
          class="inline-flex size-touch items-center justify-center rounded-md text-ink-secondary transition-colors hover:text-ink disabled:opacity-40 disabled:hover:text-ink-secondary motion-reduce:transition-none"
        >
          <.icon name="hero-arrow-right-micro" class="size-4" />
        </button>
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
  attr :filter, :atom, required: true
  attr :reserve_open?, :boolean, required: true
  attr :preview, :map, required: true
  attr :verdicts, :map, required: true

  defp quadro(assigns) do
    assigns =
      assign(assigns,
        filters: @filters,
        rows: filtered(assigns.visible, assigns.step, assigns.verdicts, assigns.filter)
      )

    ~H"""
    <div class="space-y-8">
      <%!-- The round he has assembled so far, as CARDS, classified the way a
            player reads a deck: by type, tiles in mana order, entradas and
            saídas counted per group. His words, second board: "mais bem
            classificado por tipo, ou mana por exemplo, pra eu saber quanto eu
            coloquei e quanto tirei". --%>
      <section :if={@preview.chosen != []} class="rounded-xl border border-hairline-soft bg-rail p-4">
        <header class="flex flex-wrap items-baseline gap-x-3 gap-y-1">
          <h2 class="text-label font-semibold uppercase tracking-[0.1em] text-ink-secondary">
            Sua rodada
          </h2>
          <p class="font-mono text-micro tabular-nums text-ink-faint">
            {recap_totals(@preview.chosen)}
          </p>
        </header>
        <div :for={{tipo, picks} <- recap_groups(@preview.chosen)} class="mt-4">
          <h3 class="flex items-baseline gap-2 text-caption font-medium text-ink">
            {tipo}
            <span
              :if={tally(picks, :add) > 0}
              class="font-mono text-micro tabular-nums text-sev-healthy"
            >
              +{tally(picks, :add)}
            </span>
            <span
              :if={tally(picks, :cut) > 0}
              class="font-mono text-micro tabular-nums text-sev-critical"
            >
              −{tally(picks, :cut)}
            </span>
          </h3>
          <div
            :for={
              {action, rotulo, cor} <- [
                {:add, "Entram", "text-sev-healthy"},
                {:cut, "Saem", "text-sev-critical"}
              ]
            }
            :if={tally(picks, action) > 0}
            class="mt-2 flex min-w-0 items-start gap-2"
          >
            <span class={["w-12 shrink-0 pt-1 text-micro font-semibold uppercase tracking-wide", cor]}>
              {rotulo}
            </span>
            <%!-- Wraps. A recap is scanned, not scrolled: ten creatures in a
                  104px row overflowed by 82px, and with eight type groups in
                  two directions that was sixteen separate sideways scrollers
                  hiding the very cards this section exists to show. --%>
            <div class="min-w-0 flex-1">
              <div class="flex flex-wrap gap-2">
                <.card_thumb
                  :for={pick <- by_mana(picks, action)}
                  name={pick.name}
                  art={pick.card && pick.card.image_art_crop_url}
                  uri={pick.card && pick.card.scryfall_uri}
                  note={recap_note(pick)}
                  rank={pick.card && pick.card.edhrec_rank}
                />
              </div>
            </div>
          </div>
        </div>
      </section>
      <%!-- Forty vacancies is a lot to hold at once, and the three questions he
            actually asks of a board are always the same: what is left, what did
            I take, and what did the engine complain about. --%>
      <div
        role="group"
        aria-label="Filtrar vagas"
        class="-mx-1 flex gap-2 overflow-x-auto px-1 pb-1 sm:mx-0 sm:flex-wrap sm:overflow-visible sm:px-0 sm:pb-0"
      >
        <button
          :for={{key, label} <- @filters}
          type="button"
          phx-click="filtrar"
          phx-value-filtro={key}
          aria-pressed={to_string(@filter == key)}
          class={[
            "inline-flex min-h-touch shrink-0 items-center gap-2 rounded-md border px-3 text-caption transition-colors motion-reduce:transition-none",
            @filter == key && "border-hairline-strong bg-surface-2 text-ink",
            @filter != key && "border-hairline-soft text-ink-faint hover:text-ink"
          ]}
        >
          {label}
          <span class="font-mono text-micro text-ink-faint">
            {length(filtered(@visible, @step, @verdicts, key))}
          </span>
        </button>
      </div>

      <p :if={@rows == []} class="rounded-xl border border-hairline-soft bg-surface p-6">
        <span class="text-lead text-ink">Nenhuma vaga com esse filtro.</span>
        <span class="mt-1 block text-caption text-ink-muted">
          Volte para "Todas" para ver a rodada inteira.
        </span>
      </p>

      <section :for={action <- [:cut, :add]} :if={@rows != []}>
        <h2 class="text-heading font-semibold text-ink">{action_heading(action)}</h2>

        <div class="mt-4 grid gap-x-8 gap-y-6 lg:grid-cols-2 2xl:grid-cols-3">
          <section :for={{grupo, rows} <- groups(@rows, action)} class="min-w-0">
            <h3 class="flex items-baseline gap-2 border-b border-hairline pb-1.5">
              <span class="text-label uppercase tracking-[0.1em] text-ink-secondary">{grupo}</span>
              <span class="font-mono text-micro text-ink-faint">
                {decided_count(@step, rows)}/{length(rows)}
              </span>
            </h3>

            <ul class="mt-4 space-y-5">
              <li :for={vacancy <- rows} class="min-w-0">
                <div class="flex items-start gap-2">
                  <p class="min-w-0 max-w-[65ch] flex-1 text-body leading-relaxed text-ink-secondary">
                    {vacancy.vaga}
                  </p>
                  <button
                    type="button"
                    phx-click="ir"
                    phx-value-para="vaga"
                    phx-value-chave={vacancy.key}
                    aria-label={"Ver esta vaga na triagem: #{vacancy.vaga}"}
                    title="Abrir na triagem"
                    class="-my-1 inline-flex size-touch shrink-0 items-center justify-center rounded-md text-ink-disabled transition-colors hover:text-ink motion-reduce:transition-none"
                  >
                    <.icon name="hero-arrows-pointing-out-micro" class="size-3.5" />
                  </button>
                </div>

                <ul class="mt-2 flex flex-wrap gap-2">
                  <li :for={{candidate, index} <- Enum.with_index(vacancy.candidatos, 1)}>
                    <.candidato
                      vacancy={vacancy}
                      candidate={candidate}
                      index={index}
                      chosen={chosen?(@step, vacancy, candidate)}
                      dimmed={passed_over?(@step, vacancy, candidate)}
                      verdict={verdict(@verdicts, vacancy, candidate)}
                      texto?={false}
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
            :if={groups(@rows, action) == []}
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
  attr :texto?, :boolean, default: false
  attr :dono, :string, default: nil, doc: "the owner's own standing words about this card"
  attr :big, :boolean, default: false

  defp candidato(assigns) do
    assigns =
      assign(assigns,
        problem: match?({:problem, _sentence}, assigns.verdict),
        note_id: "aviso-#{assigns.vacancy.key}-#{assigns.index}"
      )

    ~H"""
    <button
      :if={@big}
      type="button"
      phx-click="escolher"
      phx-value-vaga={@vacancy.key}
      phx-value-carta={@candidate.name}
      aria-pressed={to_string(@chosen)}
      aria-label={"#{verb(@vacancy.action)} #{@candidate.name} (opção #{@index})"}
      aria-describedby={@verdict && @note_id}
      class={[
        "group flex h-full w-full flex-col overflow-hidden rounded-card border text-left transition-[border-color,box-shadow,background-color,opacity,filter] duration-200 ease-out motion-reduce:transition-none",
        @chosen && "border-ink bg-surface-2 shadow-lifted ring-1 ring-ink",
        !@chosen && "border-hairline bg-surface shadow-contact hover:border-hairline-strong",
        @dimmed && "opacity-45 grayscale-[0.4]",
        @problem && !@dimmed && "opacity-60"
      ]}
    >
      <div class="relative aspect-art w-full shrink-0 bg-inlay">
        <img
          :if={@candidate.card && @candidate.card.image_art_crop_url}
          src={@candidate.card.image_art_crop_url}
          alt=""
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
          "absolute left-2 top-2 inline-flex min-h-6 items-center justify-center rounded-sm px-1.5 font-mono text-micro",
          @chosen && "bg-ink text-felt",
          !@chosen && "bg-inlay/85 text-ink-secondary"
        ]}>
          {if @chosen, do: chosen_badge(@vacancy.action), else: @index}
        </span>

        <span
          :if={@candidate.card && @candidate.card.game_changer}
          class="absolute right-2 top-2 rounded-sm bg-inlay/85 px-1.5 py-0.5 font-mono text-micro text-sev-warning"
        >
          Game Changer
        </span>
      </div>

      <div class="flex min-w-0 flex-1 flex-col border-t border-hairline px-3 py-2.5">
        <div class="flex items-start justify-between gap-2">
          <p class="min-w-0 text-body-lg font-semibold leading-snug text-ink">{@candidate.name}</p>
          <.mana_cost
            :if={@candidate.card && @candidate.card.mana_cost}
            cost={@candidate.card.mana_cost}
            size={15}
            class="mt-px shrink-0"
          />
        </div>

        <p :if={@candidate.card} class="mt-1 flex items-baseline gap-2 text-caption text-ink-muted">
          <span class="min-w-0 truncate">{@candidate.card.type_line}</span>
          <span
            :if={pt = power_toughness(@candidate.card)}
            class="shrink-0 font-mono text-ink-secondary"
          >
            {pt}
          </span>
        </p>

        <%!-- The fact the card is judged on. Named as the card's own words so
              it is never confused with the model's argument below it. --%>
        <.oracle_text
          :if={@texto? and @candidate.card}
          text={@candidate.card.oracle_text}
          clamp={6}
          class="mt-2.5 border-l border-hairline-soft pl-2.5"
        />

        <p class="mt-2.5 flex flex-wrap items-baseline gap-x-2 gap-y-1">
          <span class="font-mono text-numeral-sm leading-none text-ink-secondary">
            {Money.brl(@candidate.price_usd)}
          </span>
          <.play_rate :if={@candidate.card} card={@candidate.card} />
        </p>

        <%!-- His words above the model's, because that is the ranking the
              review stage already wrote into law: the owner outranks the
              pipeline about his own cards. --%>
        <p :if={@dono} class="mt-2 flex gap-1.5 text-caption leading-relaxed text-ink">
          <span class="shrink-0 font-mono text-micro uppercase text-ink-faint">Você</span>
          <span class="min-w-0">{@dono}</span>
        </p>

        <p class="mt-2 flex gap-1.5 text-caption leading-relaxed text-ink-secondary">
          <span class="shrink-0 font-mono text-micro uppercase text-ink-disabled">IA</span>
          <span class="min-w-0">{@candidate.porque}</span>
        </p>

        <p :if={!@candidate.resolved?} class="mt-2 text-caption text-sev-warning">
          o catálogo ainda não tem essa carta
        </p>

        <.veredito id={@note_id} verdict={@verdict} class="mt-2" />
      </div>
    </button>

    <button
      :if={!@big}
      type="button"
      phx-click="escolher"
      phx-value-vaga={@vacancy.key}
      phx-value-carta={@candidate.name}
      aria-pressed={to_string(@chosen)}
      aria-label={"#{verb(@vacancy.action)} #{@candidate.name} (opção #{@index})"}
      aria-describedby={@verdict && @note_id}
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
        <span :if={@chosen} class="shrink-0 font-mono text-micro text-ink">
          {chosen_badge(@vacancy.action)}
        </span>
      </span>
      <%!-- The board says why before the click, exactly like triage does. A
            candidate dimmed with no reason attached is the engine refusing in
            silence, which is the one thing the audit was built not to do. --%>
      <.veredito id={@note_id} verdict={@verdict} />
    </button>
    """
  end

  attr :verdict, :any, required: true
  attr :id, :string, default: nil
  attr :class, :any, default: nil

  defp veredito(%{verdict: nil} = assigns), do: ~H""

  defp veredito(%{verdict: {kind, sentence}} = assigns) do
    assigns = assign(assigns, kind: kind, sentence: sentence)

    ~H"""
    <p
      id={@id}
      class={[
        "flex items-start gap-1.5 text-caption leading-snug",
        @kind == :problem && "text-sev-critical",
        @kind == :note && "text-sev-warning",
        @class
      ]}
    >
      <span class="mt-1.5 size-1.5 shrink-0 rounded-full bg-current" aria-hidden="true" />
      <span class="min-w-0">{@sentence}</span>
    </p>
    """
  end

  # ── the rail ──────────────────────────────────────────────────────────────

  attr :preview, :map, required: true
  attr :step, :map, required: true
  attr :visible, :list, required: true
  attr :vacancies, :list, required: true
  attr :resumo?, :boolean, required: true

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
      <%!-- Capped, because it is sticky: with the recap open it grew past the
            viewport and buried the very vacancies it reports on. --%>
      <div class="sticky top-[3.5rem] z-10 max-h-[72dvh] space-y-2.5 overflow-y-auto rounded-xl border border-hairline-soft bg-rail p-3 xl:top-[4.75rem] xl:max-h-[calc(100dvh-6rem)] xl:space-y-3 xl:p-4">
        <%!-- The whole premise of this screen is that the numbers move because
              of something he just did. A screen reader gets nothing from a
              silent repaint, so the scoreboard announces itself. --%>
        <div role="status" aria-live="polite" class="space-y-2.5 xl:space-y-3">
          <%!-- Two up, everywhere. Three tiles across a 375px phone left the
                money 100px wide and "R$ 1538,73" rendered "R$ 1538…" — the same
                truncation the criticals tile had, on the number that says what
                the round costs. --%>
          <div class="grid grid-cols-2 gap-2 xl:gap-3">
            <.placar
              label="Cartas"
              value={Integer.to_string(@preview.count)}
              tone={count_tone(@preview.count)}
            >
              <:note>de {Balance.target()}</:note>
            </.placar>

            <%!-- The delta used to be one 28px line, "0 → 5", and at the rail's
                  real width it rendered "0 →…" — the number that says whether
                  his round makes the deck worse, ellipsised. It is a value and
                  the baseline it is measured against, like every other number
                  in this app. --%>
            <.placar
              label="Críticos"
              value={Integer.to_string(elem(@criticals, 1))}
              tone={criticals_tone(@criticals)}
            >
              <:note>{criticals_baseline(@criticals)}</:note>
            </.placar>

            <.placar
              label="Entradas"
              value={Money.brl(@preview.spend_usd)}
              tone={if over_budget?(@preview), do: :warning, else: :neutral}
              class="col-span-2"
            >
              <:note :if={line = exception_line(@preview)}>{line}</:note>
            </.placar>
          </div>
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

        <%!-- After twenty decisions the board is the only place his round
              exists, and reading it back off forty tiles is not reading it
              back. This is the round as a list. --%>
        <div class="rounded-lg border border-hairline bg-surface">
          <button
            type="button"
            phx-click="resumo"
            aria-expanded={to_string(@resumo?)}
            class="flex min-h-touch w-full items-center justify-between gap-2 px-3 text-left transition-colors hover:bg-surface-2 motion-reduce:transition-none"
          >
            <span class="text-label uppercase tracking-[0.1em] text-ink-secondary">
              Suas escolhas
            </span>
            <span class="flex items-center gap-2">
              <%!-- The number he actually wants at a glance is not "9 picks";
                    it is quantos entram e quantos saem. --%>
              <span class="font-mono text-caption tabular-nums">
                <span class="text-sev-healthy">+{tally(@preview.chosen, :add)}</span>
                <span class="text-sev-critical">−{tally(@preview.chosen, :cut)}</span>
              </span>
              <.icon
                name={if @resumo?, do: "hero-chevron-up-micro", else: "hero-chevron-down-micro"}
                class="size-3.5 text-ink-faint"
              />
            </span>
          </button>

          <div :if={@resumo?} class="border-t border-hairline px-3 py-2.5">
            <p :if={@preview.chosen == []} class="text-caption leading-relaxed text-ink-muted">
              Nada escolhido ainda. Cada carta que você marcar aparece aqui, com o preço.
            </p>

            <div :for={action <- [:cut, :add]} class="not-first:mt-3">
              <% picks = Enum.filter(@preview.chosen, &(&1.action == action)) %>
              <p :if={picks != []} class="text-micro uppercase tracking-[0.1em] text-ink-faint">
                {action_heading(action)}
              </p>
              <ul :if={picks != []} class="mt-1 space-y-1">
                <li :for={pick <- picks} class="flex items-baseline justify-between gap-2">
                  <span class="min-w-0 truncate text-caption text-ink-secondary">{pick.name}</span>
                  <span class="shrink-0 font-mono text-micro text-ink-faint">
                    {Money.brl(pick.price_usd)}
                  </span>
                </li>
              </ul>
            </div>
          </div>
        </div>

        <div class="border-t border-hairline pt-2.5 xl:pt-3">
          <p
            :if={@preview.blocker}
            role="alert"
            class="mb-2 text-caption leading-snug text-sev-critical"
          >
            {@preview.blocker}
          </p>
          <%!-- Off 100 is no longer a wall: he chooses freely and the balance
                stages settle the hundred AFTER his decisions — his own ask,
                in his own words. The rail says the plan instead of blocking. --%>
          <p
            :if={is_nil(@preview.blocker) and @preview.count != Balance.target()}
            class="mb-2 text-caption leading-snug text-ink-secondary"
          >
            O deck ficaria com {@preview.count}. Ao fechar, o crítico lê suas escolhas e a IA
            fecha a conta em {Balance.target()} — ciente de tudo que você decidiu.
          </p>
          <p
            :if={
              is_nil(@preview.blocker) and @preview.count == Balance.target() and
                @preview.undecided > 0
            }
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

  # Said in words, because a bare "eram 0" next to a 5 does not say which way
  # the round moved, and this is the one number that judges his own choices.
  defp criticals_baseline({before, before}), do: "seguem #{before}"
  defp criticals_baseline({before, now}) when now > before, do: "eram #{before} — subiu"
  defp criticals_baseline({before, _now}), do: "eram #{before} — caiu"

  defp tone_var(:neutral), do: "var(--ink)"
  defp tone_var(tone), do: "var(--sev-#{tone})"

  # Only an alarm tints its edge, exactly like the stat tile it is a cousin of.
  defp placar_border(tone) when tone in [:critical, :warning],
    do: "color-mix(in srgb, var(--c) 32%, transparent)"

  defp placar_border(_tone), do: "var(--hairline)"

  # ── the shortcuts sheet ───────────────────────────────────────────────────

  defp atalhos(assigns) do
    ~H"""
    <%!-- No handler on the backdrop and no second Escape listener: the hook
          already owns the window's keys, and a backdrop click would fire
          together with click-away — two toggles reopening what one closed.
          One idempotent close, from every path. --%>
    <div class="fixed inset-0 z-40 flex items-end justify-center bg-felt/70 p-4 backdrop-blur-sm sm:items-center">
      <div
        role="dialog"
        aria-modal="true"
        aria-label="Atalhos de teclado"
        phx-click-away="fechar-atalhos"
        class="w-full max-w-md rounded-xl border border-hairline-soft bg-rail p-5 shadow-lifted"
      >
        <div class="flex items-start justify-between gap-4">
          <h2 class="text-heading font-semibold text-ink">Atalhos</h2>
          <button
            type="button"
            phx-click="fechar-atalhos"
            aria-label="Fechar atalhos"
            class="-m-2 inline-flex size-touch items-center justify-center rounded-md text-ink-faint transition-colors hover:text-ink motion-reduce:transition-none"
          >
            <.icon name="hero-x-mark-micro" class="size-4" />
          </button>
        </div>

        <dl class="mt-4 space-y-2">
          <div
            :for={
              {keys, what} <- [
                {~w(1 2 3), "escolhe o candidato"},
                {~w(0), "nenhuma destas"},
                {~w(U), "desfaz esta vaga"},
                {~w(← →), "vaga anterior / próxima"},
                {~w(J K), "o mesmo, sem tirar a mão do teclado"},
                {~w(T Q), "triagem / quadro"},
                {~w(?), "esta lista"},
                {~w(Esc), "fecha o que estiver aberto"}
              ]
            }
            class="flex items-baseline justify-between gap-4"
          >
            <dt class="flex shrink-0 gap-1">
              <kbd
                :for={key <- keys}
                class="rounded-xs border border-hairline-soft px-1.5 font-mono text-micro text-ink-secondary"
              >
                {key}
              </kbd>
            </dt>
            <dd class="min-w-0 text-caption text-ink-muted">{what}</dd>
          </div>
        </dl>
      </div>
    </div>
    """
  end

  defp commit_note(:cardapio) do
    "O motor audita as suas escolhas e o crítico lê a lista. Uma consulta."
  end

  defp commit_note(_critic), do: "Última etapa: isso encerra a rodada. Nenhuma consulta."
end
