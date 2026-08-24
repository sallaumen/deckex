defmodule DeckexWeb.DeckLive do
  @moduledoc """
  One deck, measured.

  The layout is desktop-first and uses width for **comparison**, not for
  stretching: on a wide screen the findings sit in a sticky column beside the
  measurements they cite, so you can read "23 of 25 green sources" and look at
  the green row without scrolling. Below `xl` the same content stacks, findings
  still first — the numbers are evidence for the findings, not the point.
  """
  use DeckexWeb, :live_view

  alias Deckex.AI.Ledger
  alias Deckex.Analysis
  alias Deckex.Analysis.Bracket
  alias Deckex.Budget
  alias Deckex.Cards
  alias Deckex.Cards.PlayRate
  alias Deckex.Consults
  alias Deckex.Consults.Suggestions
  alias Deckex.Decks
  alias Deckex.Decks.Edits
  alias Deckex.Decks.Versions
  alias Deckex.Error
  alias Deckex.Events
  alias Deckex.Money
  alias Deckex.Optimizations
  alias Deckex.Settings
  alias DeckexWeb.Clock

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    case Decks.fetch_deck(id) do
      {:ok, deck} ->
        # Subscribe HERE and only here. assign_deck runs again on every edit
        # and consult event; a subscribe inside it would stack subscriptions,
        # and PubSub delivers once per subscription.
        if connected?(socket), do: Events.subscribe_consults(deck.id)

        {:ok, assign_deck(socket, deck)}

      {:error, %Error{} = error} ->
        {:ok, socket |> put_flash(:error, error.message) |> push_navigate(to: ~p"/")}
    end
  end

  defp assign_deck(socket, deck) do
    snapshot = Decks.snapshot(deck)
    # Read once: every `Settings.get/1` is its own query, and the policy is
    # four of them.
    budget_policy = Budget.policy()

    socket
    |> assign(
      deck: deck,
      snapshot: snapshot,
      report: Analysis.report(snapshot, Settings.baselines()),
      model: Settings.model(),
      card_uris: card_uris(snapshot),
      deck_value: deck_value(snapshot),
      budget_policy: budget_policy,
      budget_line: budget_line(snapshot, budget_policy),
      price_age: price_age_label(),
      running_optimization: Optimizations.running_for_deck(deck.id),
      deletion_cost: Decks.deletion_cost(deck),
      version_count: deck |> Versions.list() |> length(),
      drifted?: Versions.drifted?(deck),
      pending_edits: Edits.changelog(deck),
      card_notes: Decks.card_notes(deck),
      ai_totals: Ledger.totals_for_deck(deck),
      page_title: deck.name
    )
    |> assign_new(:renaming, fn -> false end)
    |> refresh_consults()
  end

  # Spelled out, with counts: a consult cost money, and finding out afterwards
  # that deleting the deck took ten of them is the kind of thing an app gets to
  # do to someone exactly once.
  defp delete_warning(deck, %{consults: 0, optimizations: 0}) do
    "Apagar #{deck.name}? A lista some; o catálogo de cartas fica."
  end

  defp delete_warning(deck, cost) do
    "Apagar #{deck.name}? Vão junto #{cost.consults} consulta(s) e " <>
      "#{cost.optimizations} otimização(ões) — inclusive as já pagas. Não dá para desfazer."
  end

  @impl Phoenix.LiveView
  def handle_event("consult-finding", %{"code" => code}, socket) do
    {:noreply, start_consult(socket, :finding, finding_code: code)}
  end

  def handle_event("consult-full", %{"consult" => params}, socket) do
    lens = String.to_existing_atom(params["lens"] || "full")

    opts = [model: params["model"], against: blank_to_nil(params["against"])]

    {:noreply, start_consult(socket, lens, opts)}
  end

  # The most expensive click in the app: one press buys a consult from every
  # model. A second press before the first round finishes would silently
  # double that, so it is refused with a reason rather than ignored.
  def handle_event("compare-models", _params, socket) do
    if socket.assigns.consult_running? do
      {:noreply,
       put_flash(socket, :error, "Já tem consulta rodando. Espere ela terminar para comparar.")}
    else
      {:ok, _consults} = Consults.compare(socket.assigns.deck, :full, Consults.models())

      {:noreply,
       socket
       |> put_flash(:info, "Rodando a mesma pergunta em #{length(Consults.models())} modelos.")
       |> refresh_consults()}
    end
  end

  def handle_event("gerar-dossie", _params, socket) do
    {:noreply, start_consult(socket, :scout, [])}
  end

  def handle_event("salvar-dossie", %{"dossier" => params}, socket) do
    {:ok, _deck} = Decks.edit_dossier(socket.assigns.deck, params)
    {:ok, fresh} = Decks.fetch_deck(socket.assigns.deck.id)

    {:noreply, socket |> assign_deck(fresh) |> put_flash(:info, "Dossiê salvo.")}
  end

  def handle_event("start-rename", _params, socket),
    do: {:noreply, assign(socket, renaming: true)}

  def handle_event("cancel-rename", _params, socket),
    do: {:noreply, assign(socket, renaming: false)}

  def handle_event("rename", %{"deck" => %{"name" => name}}, socket) do
    case Decks.rename(socket.assigns.deck, name) do
      {:ok, renamed} ->
        {:noreply, socket |> assign(renaming: false) |> assign_deck(renamed)}

      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  # The copy is built from the deck as it stands, so an owner who wants to try
  # a variation does not have to choose between losing their edits and losing
  # the original.
  def handle_event("duplicate", _params, socket) do
    case Decks.duplicate(socket.assigns.deck) do
      {:ok, copy} ->
        {:noreply,
         socket
         |> put_flash(:info, "Cópia criada: #{copy.name}.")
         |> push_navigate(to: ~p"/decks/#{copy.id}")}

      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("delete", _params, socket) do
    case Decks.delete_deck(socket.assigns.deck) do
      {:ok, deleted} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{deleted.name} foi apagado.")
         |> push_navigate(to: ~p"/")}

      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  # Typed by hand rather than suggested by a model, so the name may be anything.
  # `add_card/2` resolves it through the catalogue and answers with a real error
  # when it is not a card — the flash says so instead of the page pretending.
  def handle_event("add-card", %{"card" => %{"name" => name}}, socket) do
    case String.trim(name) do
      "" ->
        {:noreply, socket}

      name ->
        {:noreply,
         apply_edit(socket, Decks.add_card(socket.assigns.deck, name), "#{name} entrou.")}
    end
  end

  def handle_event("apply-add", %{"name" => name}, socket) do
    {:noreply, apply_edit(socket, Decks.add_card(socket.assigns.deck, name), "#{name} entrou.")}
  end

  # The whole answer in one act, and the version that says what it was. The
  # engine's refusals are left where they are: a row the audit flagged is
  # exactly the row nobody should apply by accident.
  def handle_event("aplicar-consulta", %{"consult" => consult_id}, socket) do
    consult = Enum.find(socket.assigns.consults, &(&1.id == consult_id))
    rows = applicable(socket.assigns.suggestions[consult_id], socket.assigns.audits[consult_id])

    {:ok, result} =
      Decks.apply_suggestions(socket.assigns.deck, rows,
        consult_id: consult_id,
        label: "Consulta: #{Consults.lens_label(consult.lens)}"
      )

    {:noreply, socket |> assign_deck(result.deck) |> put_flash(:info, applied_message(result))}
  end

  def handle_event("marcar-versao", _params, socket) do
    {:ok, version} = Versions.mark(socket.assigns.deck)

    {:noreply,
     socket
     |> assign_deck(socket.assigns.deck)
     |> put_flash(:info, "Guardado como v#{version.number}.")}
  end

  def handle_event("apply-cut", %{"name" => name}, socket) do
    {:noreply, apply_edit(socket, Decks.remove_card(socket.assigns.deck, name), "#{name} saiu.")}
  end

  # A finished scout wrote the dossier onto the deck, and a catalogued answer
  # may have reclassified cards — re-read the deck, not just the consults.
  @impl Phoenix.LiveView
  def handle_info({:consult_updated, _id}, socket) do
    {:ok, fresh} = Decks.fetch_deck(socket.assigns.deck.id)

    {:noreply, assign_deck(socket, fresh)}
  end

  # Consults.request/3 raises rather than returning a tagged error — every
  # field it writes is built here, so a failure is a bug, not a user problem.
  defp start_consult(socket, lens, opts) do
    {:ok, _consult} =
      Consults.request(socket.assigns.deck, lens, Enum.reject(opts, &(elem(&1, 1) == nil)))

    socket
    |> put_flash(:info, "Consulta enviada. A resposta aparece aqui quando chegar.")
    |> refresh_consults()
  end

  # An edit changes the deck, so the whole report is rebuilt — that is the point
  # of reports being computed rather than cached. Re-fetched, not reused: the
  # edit may have flipped dossier_stale, and the struct in assigns predates it.
  defp apply_edit(socket, {:ok, _result}, message) do
    {:ok, fresh} = Decks.fetch_deck(socket.assigns.deck.id)

    socket |> assign_deck(fresh) |> put_flash(:info, message)
  end

  defp apply_edit(socket, {:error, error}, _message) do
    put_flash(socket, :error, error.message)
  end

  # A player who says their decks reach R$ 8-10 mil has no way to see where
  # one sits today, and the app has held every price all along.
  defp deck_value(snapshot) do
    (snapshot.main ++ snapshot.commanders)
    |> Enum.map(&{&1.card.price_usd, &1.quantity})
    |> Enum.reject(fn {price, _qty} -> is_nil(price) end)
    |> Enum.reduce(Decimal.new(0), fn {price, qty}, total ->
      Decimal.add(total, Decimal.mult(price, qty))
    end)
  end

  # A price the owner budgets from should say how old it is. Nothing showed
  # this, and the day the whole catalogue turned out to be mispriced there was
  # no way to tell a fresh number from one read a week ago.
  defp price_age_label do
    case Cards.price_age().oldest do
      nil ->
        nil

      oldest ->
        days = DateTime.diff(DateTime.utc_now(), oldest, :day)

        {days, age_sentence(days)}
    end
  end

  defp age_sentence(0), do: "preços de hoje"
  defp age_sentence(1), do: "preços de ontem"
  defp age_sentence(days), do: "preços de #{days} dias atrás"

  # "3/10 caras · 1/2 exceções" — the deck's spending shape in one line, or
  # nothing at all when neither limit is switched on. Written only for the
  # tiers that exist: a line that says 0/0 is noise pretending to be data.
  defp budget_line(snapshot, policy) do
    occupancy = Budget.occupancy(snapshot.main ++ snapshot.commanders, policy)

    [
      policy.expensive.max && "#{occupancy.expensive}/#{policy.expensive.max} caras",
      policy.exception.max && "#{occupancy.exception}/#{policy.exception.max} exceções"
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  # How many of the proposed adds are cards almost nobody plays. The owner's
  # worry was that cheap suggestions are weak ones; price cannot tell him, and
  # reading twenty rows to find out defeats the purpose of a table.
  defp rare_adds(suggestions) do
    suggestions
    |> List.wrap()
    |> Enum.count(
      &(&1.action == :add and not is_nil(&1.card) and PlayRate.worth_a_look?(&1.card))
    )
  end

  # One map for the whole screen, built from the snapshot already in memory —
  # every card the page can name is in it, and no extra query is needed.
  defp card_uris(snapshot) do
    (snapshot.main ++ snapshot.commanders)
    |> Enum.map(& &1.card)
    |> Enum.reject(&is_nil(&1.scryfall_uri))
    |> Map.new(&{&1.name, &1.scryfall_uri})
  end

  defp refresh_consults(socket) do
    consults = Consults.list_for_deck(socket.assigns.deck)
    suggestions = Map.new(consults, &{&1.id, Suggestions.for_consult(&1)})

    assign(socket,
      consults: consults,
      suggestions: suggestions,
      consult_spend: Ledger.by_consult(Enum.map(consults, & &1.id)),
      audits: audits(socket.assigns.snapshot, consults, suggestions),
      scout_running?: running?(consults, :scout),
      consult_running?: running?(consults, :any)
    )
  end

  defp running?(consults, :any), do: Enum.any?(consults, &(&1.status in [:pending, :running]))

  defp running?(consults, lens) do
    Enum.any?(consults, &(&1.lens == lens and &1.status in [:pending, :running]))
  end

  # One audit per answered consult, recomputed against the deck as it is NOW —
  # that is the point: after you apply a cut, an old consult's audit honestly
  # reports that card as no longer in the list.
  # Audited against the lens that was asked, because the price ceiling is part
  # of the question: R$ 400 is a refusal under "gastando pouco" and fine under
  # "sem olhar preço".
  defp audits(snapshot, consults, suggestions) do
    lenses = Map.new(consults, &{&1.id, &1.lens})

    suggestions
    |> Enum.reject(fn {_id, rows} -> rows == [] end)
    |> Map.new(fn {id, rows} -> {id, Consults.audit(snapshot, rows, lenses[id])} end)
  end

  # Resolved, and not flagged by the engine. A suggestion the audit rejected is
  # still on the page with its reason printed — this button is not where the
  # owner overrides the engine, one click at a time is.
  defp applicable(nil, _audit), do: []

  defp applicable(rows, audit) do
    Enum.filter(rows, &(&1.resolved? and problems_for(audit, &1.action, &1.name) == []))
  end

  defp consult_apply_warning(deck, rows, audit) do
    {adds, cuts} = Enum.split_with(applicable(rows, audit), &(&1.action == :add))
    refused = length(rows) - length(adds) - length(cuts)

    "Aplicar #{length(adds)} entrada(s) e #{length(cuts)} corte(s) em #{deck.name}?" <>
      if(refused > 0, do: " #{refused} recusada(s) pelo motor ficam de fora.", else: "") <>
      " A lista de agora fica guardada como versão."
  end

  defp applied_summary(rows, audit) do
    {adds, cuts} = Enum.split_with(applicable(rows, audit), &(&1.action == :add))

    "+#{length(adds)} / −#{length(cuts)}"
  end

  defp applied_message(%{applied: [], failed: []}), do: "Nada para aplicar nessa resposta."

  defp applied_message(%{applied: [], failed: failed}) do
    "Nenhuma mudança entrou: #{Enum.map_join(failed, "; ", fn {name, reason} -> "#{name} — #{reason}" end)}"
  end

  defp applied_message(%{applied: applied, failed: failed, version: version}) do
    base = "#{length(applied)} mudança(s) aplicada(s) — virou a v#{version.number} do deck."

    case failed do
      [] -> base
      some -> base <> " #{length(some)} não deu: #{Enum.map_join(some, "; ", &elem(&1, 0))}"
    end
  end

  defp problems_for(nil, _action, _name), do: []
  defp problems_for(audit, action, name), do: Map.get(audit.problems, {action, name}, [])

  # What the engine allowed but wants said out loud — a card spending one of
  # the exception slots, say. Kept apart from the problems on purpose: this
  # rejects nothing, and reading it as a refusal is the exact mistake the Game
  # Changer note once made.
  defp notes_for(nil, _action, _name), do: []
  defp notes_for(audit, action, name), do: Map.get(audit.notes, {action, name}, [])

  defp dossier_label("plano"), do: "Plano"
  defp dossier_label("sinergias"), do: "Sinergias"
  defp dossier_label("linhas_de_vitoria"), do: "Linhas de vitória"
  defp dossier_label("fraquezas"), do: "Fraquezas que os números não veem"

  defp dossier_source_label(:scout), do: "escrito pelo scout"
  defp dossier_source_label(:manual), do: "editado por você"

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-[1800px] px-6 py-10 lg:px-10 lg:py-14">
      <%!-- Inside the LiveView's own tree, not the root layout: the layout is
            static after mount, so a flash put during an event would never
            reach the screen from there. --%>
      <DeckexWeb.Layouts.flash_group flash={@flash} />
      <.live_component module={DeckexWeb.SettingsPanel} id="settings-panel" />

      <.link
        navigate={~p"/"}
        class="-my-2 inline-flex min-h-touch items-center py-2 text-caption text-ink-faint transition-colors hover:text-ink"
      >
        ← A Mesa
      </.link>

      <%!-- The edits were made here, so the offer to keep them belongs here.
            Sending someone to another screen to save what they just did is
            how work gets lost. --%>
      <div
        :if={@pending_edits != []}
        class="mt-3 flex flex-wrap items-center justify-between gap-3 rounded-lg border border-hairline-soft bg-surface px-4 py-3"
      >
        <div class="min-w-0">
          <p class="text-caption text-ink">
            {length(@pending_edits)} mudança(s) fora de qualquer versão
          </p>
          <p class="mt-0.5 truncate font-mono text-micro text-ink-faint">
            {Enum.map_join(
              @pending_edits,
              " · ",
              &"#{if &1["action"] == "add", do: "+", else: "−"}#{&1["card"]}"
            )}
          </p>
        </div>

        <div class="flex shrink-0 items-center gap-3">
          <.link
            navigate={~p"/decks/#{@deck.id}/versoes"}
            class="-my-2 inline-flex min-h-touch items-center px-1 py-2 text-caption text-ink-faint transition-colors hover:text-ink"
          >
            ver versões
          </.link>
          <.button type="button" phx-click="marcar-versao" phx-disable-with="marcando…">
            Marcar versão
          </.button>
        </div>
      </div>

      <header class="mt-3 mb-10 flex flex-wrap items-end justify-between gap-4">
        <div class="min-w-0">
          <%!-- The name is the one thing about a deck that is purely the
                owner's, and until now it was whatever the import produced. --%>
          <.form
            :if={@renaming}
            for={%{}}
            as={:deck}
            phx-submit="rename"
            class="flex flex-wrap items-center gap-2"
          >
            <%!-- No focus ring here: `:focus-visible` is declared once in
                  app.css, and a local one would be a second answer to a
                  question the design system already settled. --%>
            <input
              type="text"
              name="deck[name]"
              value={@deck.name}
              autofocus
              aria-label="Nome do deck"
              class={[
                "min-h-touch min-w-0 flex-1 rounded-md border border-hairline-strong bg-surface px-3",
                "text-display font-semibold text-ink focus:border-ink-faint"
              ]}
            />
            <.button type="submit" variant="primary">Salvar</.button>
            <.button type="button" phx-click="cancel-rename">Cancelar</.button>
          </.form>

          <h1 :if={not @renaming} class="text-display font-semibold text-ink">{@deck.name}</h1>

          <p :for={commander <- @snapshot.commanders} class="mt-1 flex items-center gap-2">
            <.card_link
              name={commander.card.name}
              uri={commander.card.scryfall_uri}
              class="text-body text-ink-secondary"
            />
            <.mana_cost cost={commander.card.mana_cost} size={14} />
          </p>

          <div :if={not @renaming} class="mt-2 flex flex-wrap items-center gap-1">
            <%!-- The count is the point of the link: "Versões" alone says a
                  screen exists, "Versões (7)" says there is something on it. --%>
            <.link
              navigate={~p"/decks/#{@deck.id}/versoes"}
              class="-my-2 inline-flex min-h-touch items-center px-1 py-2 text-caption text-ink-faint transition-colors hover:text-ink motion-reduce:transition-none"
            >
              Versões ({@version_count}){if @pending_edits != [],
                do: " · #{length(@pending_edits)} soltas",
                else: if(@drifted?, do: " •")}
            </.link>
            <span class="text-ink-faint" aria-hidden="true">·</span>
            <.link
              navigate={~p"/decks/#{@deck.id}/cartas"}
              class="-my-2 inline-flex min-h-touch items-center px-1 py-2 text-caption text-ink-faint transition-colors hover:text-ink motion-reduce:transition-none"
            >
              Cartas ({length(@card_notes)})
            </.link>
            <span class="text-ink-faint" aria-hidden="true">·</span>
            <button
              type="button"
              phx-click="start-rename"
              class="-my-2 inline-flex min-h-touch items-center px-1 py-2 text-caption text-ink-faint transition-colors hover:text-ink motion-reduce:transition-none"
            >
              Renomear
            </button>
            <span class="text-ink-faint" aria-hidden="true">·</span>
            <button
              type="button"
              phx-click="duplicate"
              data-confirm="Criar uma cópia deste deck, com a lista como está agora?"
              class="-my-2 inline-flex min-h-touch items-center px-1 py-2 text-caption text-ink-faint transition-colors hover:text-ink motion-reduce:transition-none"
            >
              Duplicar
            </button>
            <span class="text-ink-faint" aria-hidden="true">·</span>
            <%!-- The list goes back out the door it came in through: the same
                  format the app imports, which is also the format a shop's
                  bulk-add box reads. --%>
            <a
              href={~p"/decks/#{@deck.id}/lista.txt"}
              download
              class="-my-2 inline-flex min-h-touch items-center px-1 py-2 text-caption text-ink-faint transition-colors hover:text-ink motion-reduce:transition-none"
            >
              Baixar lista
            </a>
            <span class="text-ink-faint" aria-hidden="true">·</span>
            <button
              type="button"
              phx-click="delete"
              data-confirm={delete_warning(@deck, @deletion_cost)}
              class="-my-2 inline-flex min-h-touch items-center px-1 py-2 text-caption text-ink-faint transition-colors hover:text-sev-critical motion-reduce:transition-none"
            >
              Apagar
            </button>
          </div>
        </div>
        <%!-- Wraps as a row of whole stats rather than squeezing four of them
              into columns one word wide. Each number keeps its line: at 320px
              "0/10 caras · 0/2 exceções" broke across three. --%>
        <div class="flex flex-wrap items-end gap-x-6 gap-y-4">
          <.button
            :if={@running_optimization}
            navigate={~p"/otimizacoes/#{@running_optimization.id}"}
            variant="primary"
          >
            {case @running_optimization.status do
              :awaiting_choice -> "Otimização esperando você →"
              :paused -> "Otimização pausada →"
              _running -> "Otimização rodando →"
            end}
          </.button>
          <.button
            :if={is_nil(@running_optimization)}
            navigate={~p"/decks/#{@deck.id}/otimizacoes"}
            variant="primary"
          >
            Otimizar
          </.button>

          <%!-- Beside the deck's own value on purpose: one is what the cards
                cost, the other is what asking about them cost, and an owner
                deciding whether to run another optimization is weighing both. --%>
          <.token_meter totals={@ai_totals} label="Gasto com IA" size={:lg} class="text-right" />

          <div class="text-right whitespace-nowrap">
            <p class="text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
              Valor do deck
            </p>
            <p class="font-mono text-numeral-sm font-semibold leading-none text-ink">
              {Money.brl(@deck_value)}
            </p>
            <%!-- The total says what the deck cost; this says what its shape
                  is. Ten cards at four hundred and two above the ceiling is a
                  policy about the list, and the owner cannot hold it in his
                  head while reading suggestions. --%>
            <p
              :if={@price_age}
              class={[
                "mt-1 font-mono text-micro",
                elem(@price_age, 0) > Cards.price_max_age_days() && "text-sev-warning",
                elem(@price_age, 0) <= Cards.price_max_age_days() && "text-ink-faint"
              ]}
            >
              {elem(@price_age, 1)}
            </p>
            <p
              :if={@budget_line}
              title={"Limite: #{@budget_policy.expensive.max} cartas acima de R$ #{@budget_policy.expensive.threshold} e #{@budget_policy.exception.max} exceções acima de R$ #{@budget_policy.exception.threshold}"}
              class="mt-1 font-mono text-micro text-ink-faint"
            >
              {@budget_line}
            </p>
          </div>

          <%!-- Shown always, not only when it is wrong. The legality lens
                raises a finding at 105 cards, but a deck being at exactly 100
                is a fact the owner checks constantly while editing — and a
                number that only appears when broken cannot be checked. --%>
          <div class="text-right whitespace-nowrap">
            <p class="text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
              Cartas
            </p>
            <p class={[
              "font-mono text-numeral-sm font-semibold leading-none",
              @report.legality.size == @report.legality.target_size && "text-ink",
              @report.legality.size != @report.legality.target_size && "text-sev-critical"
            ]}>
              {@report.legality.size}
            </p>
            <p class="mt-1 font-mono text-micro text-ink-faint">
              de {@report.legality.target_size}
            </p>
          </div>

          <div class="text-right whitespace-nowrap">
            <p class="text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
              Bracket (piso)
            </p>
            <p class="text-numeral font-semibold leading-none text-ink">
              {@report.bracket.floor}
              <span class="text-body font-normal text-ink-secondary">
                {Bracket.name(@report.bracket.floor)}
              </span>
            </p>
            <p class="text-micro text-ink-muted">
              {Bracket.turn_expectation(@report.bracket.floor)}
            </p>
          </div>

          <.color_identity colors={@deck.color_identity} full size={20} />
        </div>
      </header>

      <div class="grid gap-10 xl:grid-cols-[minmax(340px,26rem)_1fr] xl:items-start">
        <aside class="xl:sticky xl:top-8 xl:max-h-[calc(100vh-4rem)] xl:overflow-y-auto">
          <div class="mb-4 space-y-2">
            <div class="flex items-center justify-between gap-3">
              <h2 class="text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
                Achados
              </h2>

              <%!-- Disabled while anything is running, rather than refused by a
                    toast after the click: a control that cannot work should look
                    like it cannot work, and keep saying so for as long as it is
                    true. The server still guards — a stale tab can click too. --%>
              <button
                type="button"
                phx-click="compare-models"
                phx-disable-with="enviando…"
                disabled={@consult_running?}
                title={
                  if @consult_running?,
                    do: "Espere a consulta que já está rodando terminar.",
                    else: "Pede a mesma pergunta a todos os modelos, de uma vez."
                }
                data-confirm={"Isso pede uma consulta a cada um dos #{length(Consults.models())} modelos, de uma vez. Continuar?"}
                class="-my-2 inline-flex min-h-touch items-center px-1 py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink disabled:cursor-not-allowed disabled:text-ink-disabled disabled:no-underline"
              >
                Comparar modelos
              </button>
            </div>

            <.form
              for={%{}}
              as={:consult}
              phx-submit="consult-full"
              class="space-y-3 rounded-lg border border-hairline-soft bg-surface p-4"
            >
              <div>
                <label
                  for="consult-lens"
                  class="mb-1 block text-label font-semibold uppercase tracking-[0.1em] text-ink-faint"
                >
                  O que perguntar
                </label>
                <select
                  id="consult-lens"
                  name="consult[lens]"
                  class="min-h-touch w-full rounded-md border border-hairline-soft bg-inlay px-2 py-2 text-caption text-ink"
                >
                  <option :for={{lens, label} <- Consults.lens_labels()} value={lens}>
                    {label}
                  </option>
                </select>
              </div>

              <div>
                <label
                  for="consult-model"
                  class="mb-1 block text-label font-semibold uppercase tracking-[0.1em] text-ink-faint"
                >
                  Modelo
                </label>
                <select
                  id="consult-model"
                  name="consult[model]"
                  class="min-h-touch w-full rounded-md border border-hairline-soft bg-inlay px-2 py-2 font-mono text-caption text-ink"
                >
                  <option :for={model <- Consults.models()} value={model} selected={model == @model}>
                    {model}
                  </option>
                </select>
              </div>

              <div>
                <label
                  for="consult-against"
                  class="mb-1 block text-label font-semibold uppercase tracking-[0.1em] text-ink-faint"
                >
                  Contra qual deck
                </label>
                <input
                  id="consult-against"
                  type="text"
                  name="consult[against]"
                  placeholder="ex.: Krenko goblins"
                  class="min-h-touch w-full rounded-md border border-hairline-soft bg-inlay px-2 py-2 text-caption text-ink placeholder:text-ink-faint"
                />
                <p class="mt-1 text-micro text-ink-muted">
                  Só usado na análise de matchup.
                </p>
              </div>

              <.button type="submit" variant="primary" phx-disable-with="Enviando…" class="w-full">
                Perguntar
              </.button>

              <p class="text-micro text-ink-muted">
                A resposta leva de 2 a 4 minutos e aparece aqui sozinha.
              </p>
            </.form>
          </div>

          <p
            :if={@report.findings == []}
            class="rounded-lg border border-hairline-soft bg-surface p-5 text-body text-ink-secondary"
          >
            Nada a apontar. O deck passou em todas as lentes.
          </p>

          <div class="space-y-2.5">
            <.finding
              :for={finding <- @report.findings}
              severity={finding.severity}
              title={finding.title}
              code={finding.code}
              cards={finding.card_names}
              links={@card_uris}
            >
              <:detail>{finding.detail}</:detail>
              <:actions>
                <%!-- A legality finding is arithmetic against the rules, not a
                      judgement call: nothing a model could say would change
                      what has to happen, and offering to buy an opinion on
                      "your deck has 105 cards" spends money on a fact. What it
                      needs is the list, which is one link away. --%>
                <a
                  :if={legality?(finding)}
                  href="#as-cartas"
                  class="-my-2 inline-flex min-h-touch items-center px-1 py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
                >
                  Ajustar a lista ↓
                </a>

                <button
                  :for={name <- removable_cards(finding, @snapshot)}
                  type="button"
                  phx-click="apply-cut"
                  phx-value-name={name}
                  class="-my-2 inline-flex min-h-touch items-center px-1 py-2 text-caption text-sev-critical underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
                >
                  Tirar {name}
                </button>

                <button
                  :if={not legality?(finding)}
                  type="button"
                  phx-click="consult-finding"
                  phx-disable-with="enviando…"
                  phx-value-code={finding.code}
                  class="-my-2 inline-flex min-h-touch items-center px-1 py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
                >
                  Pedir diagnóstico
                </button>
              </:actions>
            </.finding>
          </div>
        </aside>

        <div class="space-y-8">
          <section>
            <h2 class="mb-3 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
              Curva de mana
            </h2>

            <div class="rounded-xl border border-hairline-soft bg-surface p-6">
              <!-- A grid, not a flex row: eight equal columns so the histogram
                   fills whatever width it is given and the buckets stay
                   comparable to each other. -->
              <div class="grid grid-cols-8 items-end gap-3">
                <.curve_bar
                  :for={bucket <- 0..7}
                  label={if bucket == 7, do: "7+", else: to_string(bucket)}
                  count={Map.get(@report.curve.histogram, bucket, 0)}
                  max={curve_max(@report.curve.histogram)}
                  height={200}
                />
              </div>

              <div class="mt-6 grid grid-cols-2 gap-5 border-t border-hairline-soft pt-5 sm:grid-cols-4">
                <.stat label="Custo médio" value={Format.decimal(@report.curve.avg_cmc, 2)} />
                <.stat
                  label="Até 3 de mana"
                  value={to_string(@report.curve.early_plays)}
                  unit="cartas"
                />
                <.stat
                  label="De 5 pra cima"
                  value={to_string(@report.curve.late_game)}
                  unit="cartas"
                />
                <.stat label="Não-terrenos" value={to_string(@report.curve.nonland_count)} />
              </div>
            </div>
          </section>

          <div class="grid gap-8 2xl:grid-cols-2">
            <section>
              <h2 class="mb-3 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
                Mana e aceleração
              </h2>

              <div class="rounded-xl border border-hairline-soft bg-surface p-6">
                <div class="grid grid-cols-2 gap-5 lg:grid-cols-4 2xl:grid-cols-2">
                  <.stat
                    label="Terrenos"
                    value={Format.decimal(@report.mana.land_count, 1)}
                    target={"alvo #{@report.mana.land_target}"}
                    tone={land_tone(@report.mana)}
                  />
                  <.stat label="Ramp" value={to_string(@report.mana.ramp_total)} unit="peças" />
                  <.stat label="Ramp barato" value={to_string(@report.mana.ramp_cheap)} unit="até 2" />
                  <%!-- Só os incondicionais no numeral. Um fastland e um
                        terreno de battlebond não são a mesma coisa que um
                        Triome, e o número que somava os três dizia que esta
                        base era lenta quando ela não é. --%>
                  <.stat
                    label="Entram virados"
                    value={to_string(@report.mana.taplands)}
                    target={
                      if @report.mana.taplands_conditional > 0,
                        do: "+#{@report.mana.taplands_conditional} condicionais"
                    }
                  />
                </div>

                <div class="mt-6 grid grid-cols-[auto_1fr_auto] items-center gap-x-4 gap-y-3 border-t border-hairline-soft pt-5">
                  <%= for {colour, measured} <- Enum.sort(@report.mana.colors) do %>
                    <.mana_pip symbol={pip(colour)} size={20} />

                    <span class="font-mono text-caption">
                      <span class="text-ink">{measured.sources}</span><span class="text-ink-faint">/{measured.target}</span>
                      <span class="text-ink-faint">fontes</span>
                      <span class="hidden text-ink-faint sm:inline">
                        · pip máx {measured.max_pips}
                      </span>
                    </span>

                    <span class={[
                      "justify-self-end whitespace-nowrap font-mono text-caption",
                      measured.sources < measured.target && "text-sev-critical",
                      measured.sources >= measured.target && "text-sev-healthy"
                    ]}>
                      {if measured.sources < measured.target,
                        do: "faltam #{measured.target - measured.sources}",
                        else: "ok"}
                    </span>
                  <% end %>
                </div>
              </div>
            </section>

            <div class="space-y-8">
              <section>
                <h2 class="mb-3 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
                  Interação
                </h2>
                <div class="grid grid-cols-2 gap-5 rounded-xl border border-hairline-soft bg-surface p-6 lg:grid-cols-4 2xl:grid-cols-2">
                  <.stat label="Respostas reais" value={to_string(@report.interaction.answers)}>
                    remoção + varredura, sem contar counter
                  </.stat>
                  <.stat label="Counters" value={to_string(@report.interaction.counters)} />
                  <.stat
                    label="Varreduras"
                    value={to_string(@report.interaction.board_wipes)}
                    tone={if @report.interaction.board_wipes < 2, do: :warning, else: :neutral}
                  />
                  <.stat label="Proteção" value={to_string(@report.interaction.protection)} />
                </div>
              </section>

              <section>
                <h2 class="mb-3 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
                  Consistência
                </h2>
                <div class="grid grid-cols-2 gap-5 rounded-xl border border-hairline-soft bg-surface p-6 lg:grid-cols-4 2xl:grid-cols-2">
                  <.stat label="Compra" value={to_string(@report.consistency.draw)} unit="peças" />
                  <.stat label="Tutores" value={to_string(@report.consistency.tutors)} />
                  <.stat label="Recursão" value={to_string(@report.consistency.recursion)} />
                  <.stat
                    label="Win conditions"
                    value={to_string(@report.consistency.wincons)}
                    tone={if @report.consistency.wincons == 0, do: :critical, else: :neutral}
                  />
                </div>
              </section>
            </div>
          </div>
          <section>
            <h2 class="mb-3 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
              Commander Brackets
            </h2>

            <div class="rounded-xl border border-hairline-soft bg-surface p-6">
              <p class="text-body text-ink-secondary">
                Pelo que dá para provar da lista, este deck é no mínimo <strong class="text-ink">
                  Bracket {@report.bracket.floor} — {Bracket.name(@report.bracket.floor)}
                </strong>. O bracket espera {Bracket.turn_expectation(
                  @report.bracket.floor
                )}.
              </p>

              <ul class="mt-3 space-y-1">
                <li :for={reason <- @report.bracket.reasons} class="text-caption text-ink-muted">
                  {reason}
                </li>
              </ul>

              <div :if={@report.bracket.game_changers != []} class="mt-4">
                <h3 class="mb-2 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
                  Game Changers no deck ({length(@report.bracket.game_changers)}/3)
                </h3>
                <div class="flex flex-wrap gap-1.5">
                  <span
                    :for={name <- @report.bracket.game_changers}
                    class="rounded-md bg-inlay px-2 py-1 text-caption text-ink"
                  >
                    {name}
                  </span>
                </div>
                <p
                  :if={Bracket.game_changer_headroom(@report.bracket) == 0}
                  class="mt-2 text-caption text-sev-warning"
                >
                  Você está no teto: mais um Game Changer tira o deck do Bracket 3.
                </p>
              </div>

              <div class="mt-4 border-t border-hairline-soft pt-4">
                <h3 class="mb-2 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
                  O motor não consegue responder
                </h3>
                <ul class="space-y-1">
                  <li
                    :for={question <- @report.bracket.open_questions}
                    class="text-caption text-ink-muted"
                  >
                    {question}
                  </li>
                </ul>
              </div>
            </div>
          </section>

          <%!-- Beside the dossier because they are the same kind of thing: what
                the owner knows that no number shows. The dossier is about the
                deck; these are about single cards, and they cost a whole run
                to learn — a stage misread a card, he caught it, and this is
                where that stops happening again.

                A summary and a way in, not an editor. Editing the same rule in
                two places is how the two places drift, and the screen made for
                it is one click away. --%>
          <section>
            <div class="mb-3 flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
              <h2 class="text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
                Suas cartas
              </h2>
              <.link
                navigate={~p"/decks/#{@deck.id}/cartas"}
                class="-my-2 inline-flex min-h-touch items-center py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink motion-reduce:transition-none"
              >
                {if @card_notes == [], do: "obrigar, pedir, corrigir →", else: "gerenciar →"}
              </.link>
            </div>

            <div class="rounded-xl border border-hairline-soft bg-surface p-6">
              <p :if={@card_notes == []} class="max-w-[52ch] text-caption text-ink-muted">
                Nada mandado ainda. Uma carta obrigatória não pode ser cortada por rodada nenhuma —
                é onde vive uma peça de combo que a IA lê errado sozinha.
              </p>

              <ul :if={@card_notes != []} class="space-y-2">
                <li
                  :for={note <- @card_notes}
                  class="flex flex-wrap items-baseline gap-x-2 gap-y-1"
                >
                  <.card_stance stance={note.stance} />
                  <.card_link name={note.card_name} uri={@card_uris[note.card_name]} class="text-ink" />
                  <span :if={note.note} class="min-w-0 text-caption text-ink-muted">
                    — {note.note}
                  </span>
                </li>
              </ul>
            </div>
          </section>

          <section>
            <div class="mb-3 flex items-center gap-3">
              <h2 class="text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
                Dossiê
              </h2>
              <span
                :if={@deck.dossier && @deck.dossier_stale}
                class="font-mono text-micro text-sev-warning"
              >
                desatualizado — o deck mudou depois que ele foi escrito
              </span>
            </div>

            <div class="rounded-xl border border-hairline-soft bg-surface p-6">
              <div :if={is_nil(@deck.dossier) && !@scout_running?} class="text-center">
                <p class="text-body text-ink-secondary">
                  A leitura estratégica que os números não fazem: plano, sinergias,
                  linhas de vitória e fraquezas. Entra em toda consulta.
                </p>
                <div class="mt-4">
                  <.button
                    type="button"
                    phx-click="gerar-dossie"
                    phx-disable-with="Enviando…"
                    variant="primary"
                  >
                    Gerar dossiê
                  </.button>
                </div>
              </div>

              <p :if={@scout_running?} class="font-mono text-caption text-ink-faint">
                scout lendo o deck…
              </p>

              <div :if={@deck.dossier && !@scout_running?} class="space-y-4">
                <div :for={field <- Decks.dossier_fields()}>
                  <h3 class="mb-1 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
                    {dossier_label(field)}
                  </h3>
                  <p class="text-body text-ink-secondary">{@deck.dossier[field]}</p>
                </div>

                <div class="flex flex-wrap items-center justify-between gap-3 border-t border-hairline-soft pt-4">
                  <span class="font-mono text-micro text-ink-faint">
                    {dossier_source_label(@deck.dossier_source)} · {Clock.moment(
                      @deck.dossier_updated_at
                    )}
                  </span>

                  <button
                    type="button"
                    phx-click="gerar-dossie"
                    phx-disable-with="enviando…"
                    data-confirm={
                      @deck.dossier_source == :manual &&
                        "Isso substitui a sua edição pelo texto do scout. Continuar?"
                    }
                    class="-my-2 inline-flex min-h-touch items-center px-1 py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
                  >
                    Rerodar o scout
                  </button>
                </div>

                <details>
                  <summary class="-my-2 inline-flex min-h-touch cursor-pointer items-center py-2 text-caption text-ink-faint transition-colors hover:text-ink motion-reduce:transition-none">
                    Editar dossiê
                  </summary>
                  <.form
                    for={%{}}
                    as={:dossier}
                    id="dossier-form"
                    phx-submit="salvar-dossie"
                    class="mt-3 space-y-3"
                  >
                    <div :for={field <- Decks.dossier_fields()}>
                      <label
                        for={"dossier-#{field}"}
                        class="mb-1 block text-label font-semibold uppercase tracking-[0.1em] text-ink-faint"
                      >
                        {dossier_label(field)}
                      </label>
                      <textarea
                        id={"dossier-#{field}"}
                        name={"dossier[#{field}]"}
                        rows="3"
                        class="w-full rounded-md border border-hairline-soft bg-inlay px-3 py-2 text-caption text-ink"
                      >{@deck.dossier[field]}</textarea>
                    </div>
                    <.button type="submit">Salvar</.button>
                  </.form>
                </details>
              </div>
            </div>
          </section>

          <%!-- A fresh deck showed nothing at all here, which reads as a
                broken screen rather than as "you have not asked anything
                yet". The measurements above are already the deck's; this
                column is what the models said about them. --%>
          <section :if={@consults == []}>
            <h2 class="mb-3 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
              Consultas
            </h2>

            <div class="rounded-xl border border-hairline-soft bg-surface p-6">
              <p class="text-body text-ink-secondary">Nenhuma pergunta feita ainda.</p>
              <p class="mt-1 text-caption text-ink-faint">
                As medições ao lado já são suas. Uma consulta pega esses números e pergunta a um
                modelo o que cortar e o que colocar — a resposta aparece aqui, e o motor confere
                cada sugestão contra a carta de verdade.
              </p>
            </div>
          </section>

          <section :if={@consults != []}>
            <h2 class="mb-3 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
              Consultas
            </h2>

            <div class="space-y-3">
              <article
                :for={consult <- @consults}
                class="rounded-lg border border-hairline-soft bg-surface p-4"
              >
                <header class="mb-2 flex items-center justify-between gap-3">
                  <span class="font-mono text-caption text-ink-faint">
                    {consult.finding_code || consult.lens}
                    <span :if={consult.model} class="text-ink-faint">· {consult.model}</span>
                    <%!-- What this one answer cost, where the answer is. The
                          per-deck total upstairs is the sum of these, and a
                          sum nobody can break down is a number to distrust. --%>
                    <span
                      :if={@consult_spend[consult.id]}
                      title={"#{@consult_spend[consult.id].total_tokens} tokens"}
                      class="text-ink-faint"
                    >
                      · {Money.brl(@consult_spend[consult.id].cost_usd)}
                    </span>
                  </span>
                  <span class={[
                    "font-mono text-caption",
                    consult.status == :done && "text-sev-healthy",
                    consult.status == :failed && "text-sev-critical",
                    consult.status in [:pending, :running] && "text-ink-faint"
                  ]}>
                    {consult_status(consult.status)}
                  </span>
                </header>

                <p :if={consult.error} class="text-caption text-ink-secondary">{consult.error}</p>

                <div :if={consult.response} class="space-y-3">
                  <p
                    :if={consult.response["leitura"]}
                    class="border-l-2 border-hairline-strong pl-3 text-caption italic text-ink-muted"
                  >
                    {consult.response["leitura"]}
                  </p>

                  <p :if={consult.response["diagnosis"]} class="text-caption text-ink">
                    {consult.response["diagnosis"]}
                  </p>

                  <div :if={consult.response["bracket"]} class="space-y-2">
                    <p class="text-body text-ink">
                      <span class="font-mono text-numeral-sm font-semibold">
                        Bracket {consult.response["bracket"]}
                      </span>
                      <span class="text-ink-secondary">
                        {Bracket.name(consult.response["bracket"])}
                      </span>
                    </p>
                    <p class="text-caption text-ink-muted">
                      {consult.response["justificativa"]}
                    </p>
                    <p class="text-caption text-ink-secondary">
                      <span class="text-ink-faint">Combo:</span> {consult.response["combo"]}
                    </p>
                    <p class="text-caption text-ink-secondary">
                      <span class="text-ink-faint">Velocidade:</span> {consult.response["speed"]}
                    </p>
                    <p :if={consult.response["para_descer"]} class="text-caption text-ink-muted">
                      <span class="text-ink-faint">Para descer um bracket:</span>
                      {consult.response["para_descer"]}
                    </p>
                  </div>

                  <%!-- Marked, not blocked. "Comparar modelos" exists precisely
                        to ask cheap models change questions, and someone
                        exploring on purpose should not be argued with — but
                        the answer should not look like the others either. --%>
                  <p
                    :if={Consults.below_floor?(consult) and @suggestions[consult.id] not in [nil, []]}
                    class="mt-3 rounded-md border border-sev-warning/40 bg-sev-warning/10 px-3 py-2 text-caption text-ink"
                  >
                    Resposta de <span class="font-mono">{consult.model}</span>, abaixo do seu piso
                    ({Settings.model_floor()}) para sugerir mudança de carta. Confira antes de aplicar.
                  </p>

                  <div :if={@suggestions[consult.id] not in [nil, []]} class="overflow-x-auto">
                    <table class="w-full text-caption">
                      <thead>
                        <tr class="border-b border-hairline-soft text-left text-label uppercase tracking-[0.1em] text-ink-faint">
                          <th class="py-1.5 pr-2 font-semibold">Carta</th>
                          <th class="py-1.5 pr-2 text-right font-semibold">Preço e uso</th>
                          <th class="py-1.5 font-semibold"></th>
                        </tr>
                      </thead>
                      <tbody>
                        <tr
                          :for={row <- @suggestions[consult.id]}
                          class="border-b border-hairline-soft align-top transition-colors last:border-0 hover:bg-surface-2 motion-reduce:transition-none"
                        >
                          <td class="py-2 pr-2">
                            <div class="flex items-center gap-1.5">
                              <span class={[
                                "font-mono text-micro",
                                row.action == :cut && "text-sev-critical",
                                row.action == :add && "text-sev-healthy"
                              ]}>
                                {if row.action == :cut, do: "−", else: "+"}
                              </span>
                              <.card_link
                                name={row.name}
                                uri={row.card && row.card.scryfall_uri}
                                class="text-ink"
                              />
                              <.mana_cost :if={row.card} cost={row.card.mana_cost} size={12} />
                            </div>

                            <p class="mt-0.5 text-ink-muted">{row.reason}</p>

                            <p
                              :if={row.addresses}
                              class="mt-0.5 font-mono text-micro text-ink-faint"
                            >
                              {row.addresses}
                            </p>

                            <p :if={not row.resolved?} class="mt-0.5 text-micro text-sev-warning">
                              não achei essa carta na Scryfall
                            </p>

                            <p
                              :for={
                                problem <-
                                  problems_for(@audits[consult.id], row.action, row.name)
                              }
                              class="mt-0.5 text-micro text-sev-critical"
                            >
                              motor: {problem}
                            </p>

                            <p
                              :for={note <- notes_for(@audits[consult.id], row.action, row.name)}
                              class="mt-0.5 text-micro text-ink-faint"
                            >
                              motor: {note}
                            </p>
                          </td>

                          <td class="py-2 pr-2 text-right font-mono text-micro whitespace-nowrap">
                            <div class="text-ink-secondary">{Money.brl(row.price_usd)}</div>
                            <div class="text-ink-muted">{Money.usd(row.price_usd)}</div>
                            <%!-- The column price could not answer: is this
                                  card any good? Cheap and elite look identical
                                  in reais. --%>
                            <.play_rate :if={row.card} card={row.card} class="block" />
                          </td>

                          <td class="py-2 text-right">
                            <button
                              :if={row.resolved?}
                              type="button"
                              phx-click={if row.action == :cut, do: "apply-cut", else: "apply-add"}
                              phx-value-name={row.name}
                              class="-my-2 inline-flex min-h-touch items-center whitespace-nowrap px-1 py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
                            >
                              {if row.action == :cut, do: "cortar", else: "colocar"}
                            </button>
                          </td>
                        </tr>
                      </tbody>
                    </table>

                    <div :if={@audits[consult.id]} class="mt-3 rounded-md bg-inlay p-3">
                      <h3 class="mb-2 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
                        Conferido pelo motor — se você aplicar tudo agora
                      </h3>

                      <div class="space-y-1">
                        <p
                          :for={finding <- @audits[consult.id].resolved}
                          class="text-micro text-sev-healthy"
                        >
                          ✓ resolve <span class="font-mono">{finding.code}</span> — {finding.title}
                        </p>

                        <p
                          :for={finding <- @audits[consult.id].introduced}
                          class="text-micro text-sev-critical"
                        >
                          ! cria <span class="font-mono">{finding.code}</span> — {finding.title}
                        </p>

                        <p
                          :for={finding <- @audits[consult.id].remaining}
                          class="text-micro text-ink-faint"
                        >
                          · persiste <span class="font-mono">{finding.code}</span>
                        </p>

                        <p
                          :if={
                            @audits[consult.id].resolved == [] and
                              @audits[consult.id].introduced == []
                          }
                          class="text-micro text-ink-muted"
                        >
                          nenhum achado muda — as trocas são laterais pela régua do motor
                        </p>
                      </div>
                    </div>

                    <%!-- The answer is a small optimization, and it ends where
                          the big one ends: in the deck's own history, with each
                          card carrying the sentence that argued for it. --%>
                    <div
                      :if={applicable(@suggestions[consult.id], @audits[consult.id]) != []}
                      class="mt-3 flex flex-wrap items-center gap-2"
                    >
                      <.button
                        type="button"
                        phx-click="aplicar-consulta"
                        phx-value-consult={consult.id}
                        phx-disable-with="aplicando…"
                        data-confirm={
                          consult_apply_warning(@deck, @suggestions[consult.id], @audits[consult.id])
                        }
                      >
                        Aplicar tudo e marcar versão
                      </.button>

                      <span class="font-mono text-micro text-ink-faint">
                        {applied_summary(@suggestions[consult.id], @audits[consult.id])}
                      </span>
                    </div>

                    <div class="mt-2 flex items-center justify-between gap-3">
                      <span class="font-mono text-micro text-ink-faint">
                        entradas: {Money.brl(Suggestions.total_usd(@suggestions[consult.id]))}
                        <%!-- The line that answers "are these cards any good?"
                              before you read twenty rows. It counts, it does
                              not judge: a card nobody plays can be the right
                              card for this deck, and the reasoning above is
                              where that argument lives. --%>
                        <span
                          :if={rare_adds(@suggestions[consult.id]) > 0}
                          class="text-sev-warning"
                        >
                          · {rare_adds(@suggestions[consult.id])} quase ninguém joga
                        </span>
                      </span>

                      <a
                        href={~p"/consultas/#{consult.id}/csv"}
                        download
                        class="-my-2 inline-flex min-h-touch items-center px-1 py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
                      >
                        Baixar CSV
                      </a>
                    </div>
                  </div>

                  <p :if={consult.response["notes"]} class="text-caption text-ink-muted">
                    {consult.response["notes"]}
                  </p>
                </div>

                <details class="mt-3">
                  <summary class="-my-2 inline-flex min-h-touch cursor-pointer items-center py-2 text-caption text-ink-faint transition-colors hover:text-ink motion-reduce:transition-none">
                    Ver o prompt
                  </summary>
                  <pre class="mt-2 max-h-64 overflow-auto rounded-md bg-inlay p-3 font-mono text-micro text-ink-muted">{consult.briefing}</pre>
                </details>
              </article>
            </div>
          </section>
        </div>
      </div>

      <%!-- The list is where a deck gets fixed, so it is where the tools to
            fix it belong. Until now this section could only be read: an owner
            told by the engine that his deck holds 105 cards had no way to cut
            one without re-importing the whole thing. --%>
      <section id="as-cartas" class="mt-12 scroll-mt-6">
        <div class="mb-3 flex flex-wrap items-end justify-between gap-3">
          <h2 class="text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
            As cartas — {@report.legality.size} de {@report.legality.target_size}
            <span
              :if={@report.legality.size != @report.legality.target_size}
              class="text-sev-critical"
            >
              ({size_gap(@report.legality)})
            </span>
          </h2>

          <.form
            for={%{}}
            as={:card}
            phx-submit="add-card"
            class="flex flex-wrap items-center gap-2"
          >
            <label for="add-card-name" class="sr-only">Nome da carta</label>
            <input
              type="text"
              id="add-card-name"
              name="card[name]"
              value=""
              placeholder="Adicionar carta pelo nome"
              autocomplete="off"
              class="min-h-touch w-56 rounded-md border border-hairline-soft bg-inlay px-3 text-caption text-ink placeholder:text-ink-faint focus:border-ink-faint"
            />
            <.button type="submit">Adicionar</.button>
          </.form>
        </div>

        <ul class="grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-6 2xl:grid-cols-8">
          <li :for={entry <- sorted_cards(@snapshot)}>
            <.card_tile
              name={entry.card.name}
              art={entry.card.image_art_crop_url}
              mana_cost={entry.card.mana_cost}
              type_line={entry.card.type_line}
              quantity={entry.quantity}
            >
              <:footer>
                <div class="flex items-center justify-between gap-2">
                  <span class="flex items-baseline gap-1.5 font-mono text-micro text-ink-faint">
                    {Money.brl(entry.card.price_usd)}
                    <.play_rate card={entry.card} />
                  </span>

                  <%!-- No data-confirm: a card is one click to put back, the
                        engine keeps no record to lose, and a dialog on every
                        tile would make trimming a deck feel dangerous. --%>
                  <button
                    type="button"
                    phx-click="apply-cut"
                    phx-value-name={entry.card.name}
                    aria-label={"Tirar #{entry.card.name} do deck"}
                    class="-my-2 inline-flex min-h-touch shrink-0 items-center px-1 py-2 text-micro text-ink-faint transition-colors hover:text-sev-critical motion-reduce:transition-none"
                  >
                    tirar
                  </button>
                </div>
              </:footer>
            </.card_tile>
          </li>
        </ul>
      </section>
    </div>
    """
  end

  # Format speaks in mana costs, so a bare colour code becomes a one-symbol cost.
  defp pip(colour), do: "{#{colour}}" |> Format.mana_symbols() |> hd()

  defp consult_status(:pending), do: "na fila"
  defp consult_status(:running), do: "pensando…"
  defp consult_status(:done), do: "pronto"
  defp consult_status(:failed), do: "falhou"

  defp curve_max(histogram) do
    histogram |> Map.values() |> Enum.max(fn -> 1 end) |> max(1)
  end

  defp land_tone(%{land_count: count, land_target: target}) when count < target - 1, do: :critical
  defp land_tone(%{land_count: count, land_target: target}) when count > target + 2, do: :warning
  defp land_tone(_mana), do: :healthy

  defp legality?(%{lens: :legality}), do: true
  defp legality?(_finding), do: false

  # The cards a legality finding names are the ones that make it true, so each
  # gets a button. Not the size finding: which card to cut is the owner's call
  # and every card in the deck is a candidate — that one points at the list.
  @removable ~w(legality.outside_identity legality.singleton legality.not_legal)

  defp removable_cards(%{code: code, card_names: names}, snapshot) when code in @removable do
    in_main = MapSet.new(snapshot.main, & &1.card.name)

    Enum.filter(names, &MapSet.member?(in_main, &1))
  end

  defp removable_cards(_finding, _snapshot), do: []

  defp size_gap(%{size: size, target_size: target}) when size > target,
    do: "#{size - target} a mais"

  defp size_gap(%{size: size, target_size: target}), do: "#{target - size} a menos"

  # Cheapest first, then alphabetical — the order a player reads their own list.
  defp sorted_cards(snapshot) do
    Enum.sort_by(snapshot.main, &{Decimal.to_float(&1.card.cmc), &1.card.name})
  end
end
