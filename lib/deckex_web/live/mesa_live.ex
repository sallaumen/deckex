defmodule DeckexWeb.MesaLive do
  @moduledoc """
  A Mesa: every deck laid out on the table.

  Each tile leads with the commander's art and carries one number — how many
  critical findings the deck has. That is the whole point of the screen: from
  across the room you should be able to see which deck needs you.
  """
  use DeckexWeb, :live_view

  alias Deckex.Analysis
  alias Deckex.Analysis.Bracket
  alias Deckex.Analysis.Report
  alias Deckex.Decks
  alias Deckex.Error
  alias Deckex.Optimizations
  alias Deckex.Settings

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    # No page_title: the root layout already suffixes " · A Mesa", and this
    # screen IS A Mesa — setting it would render "A Mesa · A Mesa".
    {:ok, assign(socket, decks: load_decks(), deck_layout: Settings.get(:deck_layout))}
  end

  # The choice is remembered, because a layout you have to re-pick on every
  # visit is not a preference, it is a chore.
  @impl Phoenix.LiveView
  def handle_event("layout", %{"to" => to}, socket) do
    {:ok, _value} = Settings.put(:deck_layout, to)

    {:noreply, assign(socket, deck_layout: to)}
  end

  # Deleting takes the deck's consults and runs with it, so the confirmation
  # says so by name and by count before the click, not after.
  def handle_event("delete", %{"id" => id}, socket) do
    with {:ok, deck} <- Decks.fetch_deck(id),
         {:ok, _deleted} <- Decks.delete_deck(deck) do
      {:noreply,
       socket
       |> assign(decks: load_decks())
       |> put_flash(:info, "#{deck.name} foi apagado.")}
    else
      {:error, %Error{} = error} -> {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  # One report per deck. Building a report is arithmetic over ~100 structs, so
  # this stays cheap for the handful of decks one person tracks; if that ever
  # stops being true, the vital sign is what to cache, not the report.
  defp load_decks do
    live = Optimizations.live_by_deck()

    Enum.map(Decks.list_decks(), fn deck ->
      snapshot = Decks.snapshot(deck)
      report = Analysis.report(snapshot)

      %{
        deck: deck,
        commander: List.first(snapshot.commanders),
        critical: Report.critical_count(report),
        bracket: report.bracket,
        findings: length(report.findings),
        # Commanders included, because 100 is the number the rule is about.
        # Counting only the main list put "103 cartas" on the tile next to a
        # finding that said 105, and both were honest — which is worse than
        # one of them being wrong.
        cards: report.legality.size,
        # The most expensive state in the app is a run that already spent
        # money and is now waiting on a person. Invisible from here, it waits
        # forever — so the tile says it before you open anything.
        running: live[deck.id],
        cost: Decks.deletion_cost(deck)
      }
    end)
  end

  # Spelled out, with counts, because a consult cost money and a run is a
  # record of a decision. "Tem certeza?" is not a warning, it is a speed bump.
  defp delete_warning(%{deck: deck, cost: %{consults: 0, optimizations: 0}}) do
    "Apagar #{deck.name}? A lista some; o catálogo de cartas fica."
  end

  defp delete_warning(%{deck: deck, cost: cost}) do
    "Apagar #{deck.name}? Vão junto #{cost.consults} consulta(s) e " <>
      "#{cost.optimizations} otimização(ões) — inclusive as já pagas. Não dá para desfazer."
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-[1800px] px-6 py-10 lg:px-10 lg:py-14">
      <%!-- Inside the LiveView's own tree, not the root layout: the layout is
            static after mount, so a flash put during an event would never
            reach the screen from there. --%>
      <DeckexWeb.Layouts.flash_group flash={@flash} />
      <.live_component module={DeckexWeb.SettingsPanel} id="settings-panel" />

      <%!-- Stacked until there is room for a row. At 320px a title, a
            segmented control and a primary button on one line squeeze all
            three into unreadable columns. --%>
      <header class="mb-8 flex flex-col items-start gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h1 class="text-display font-semibold text-ink">A Mesa</h1>
          <p class="mt-1 text-body text-ink-muted">
            {length(@decks)} {if length(@decks) == 1, do: "deck", else: "decks"} na mesa.
          </p>
        </div>

        <div class="flex w-full items-center justify-between gap-3 sm:w-auto sm:justify-end">
          <div
            :if={@decks != []}
            role="group"
            aria-label="Como listar os decks"
            class="flex rounded-md border border-hairline-soft bg-surface-2 p-0.5"
          >
            <button
              :for={{value, label} <- [{"cartoes", "Cartões"}, {"lista", "Lista"}]}
              type="button"
              phx-click="layout"
              phx-value-to={value}
              aria-pressed={to_string(@deck_layout == value)}
              class={[
                "inline-flex min-h-touch items-center rounded-[5px] px-3 text-caption transition-colors",
                @deck_layout == value && "bg-surface text-ink",
                @deck_layout != value && "text-ink-faint hover:text-ink"
              ]}
            >
              {label}
            </button>
          </div>

          <.button navigate={~p"/importar"} variant="primary">Trazer um deck</.button>
        </div>
      </header>

      <div
        :if={@decks == []}
        class="rounded-xl border border-hairline-soft bg-surface p-10 text-center"
      >
        <p class="text-body text-ink-secondary">Nenhum deck ainda.</p>
        <p class="mt-1 mb-5 text-caption text-ink-faint">
          Cole a lista exportada do Moxfield e a mesa começa.
        </p>
        <.button navigate={~p"/importar"} variant="primary">Trazer um deck</.button>
      </div>

      <ul
        :if={@deck_layout == "cartoes"}
        class="grid gap-5 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 2xl:grid-cols-5"
      >
        <li
          :for={row <- @decks}
          class="group flex flex-col overflow-hidden rounded-xl border border-hairline-soft bg-surface transition-colors hover:border-hairline-strong"
        >
          <.link navigate={~p"/decks/#{row.deck.id}"} class="block">
            <div class="aspect-[16/9] overflow-hidden bg-inlay">
              <img
                :if={row.commander}
                src={row.commander.card.image_art_crop_url}
                alt={row.commander.card.name}
                class="size-full object-cover transition-transform duration-300 group-hover:scale-[1.03] motion-reduce:transition-none"
              />
            </div>

            <div class="space-y-2.5 p-4">
              <div class="flex items-start justify-between gap-3">
                <h2 class="text-heading font-semibold leading-tight text-ink">{row.deck.name}</h2>
                <.color_identity colors={row.deck.color_identity} full size={13} />
              </div>

              <p :if={row.commander} class="truncate text-caption text-ink-muted">
                {row.commander.card.name}
              </p>

              <div class="flex items-center gap-2 pt-1">
                <span class="rounded-md bg-inlay px-2 py-0.5 font-mono text-micro text-ink-secondary">
                  B{row.bracket.floor}+
                </span>
                <span class="truncate text-caption text-ink-faint">
                  {Bracket.name(row.bracket.floor)}
                </span>
              </div>

              <div class="flex flex-wrap items-center gap-x-3 gap-y-1.5 text-caption text-ink-faint">
                <span class="font-mono">{row.cards} cartas</span>
                <span aria-hidden="true">·</span>
                <span class={[
                  "font-mono",
                  row.critical > 0 && "text-sev-critical",
                  row.critical == 0 && "text-sev-healthy"
                ]}>
                  {vital_sign(row)}
                </span>
                <.run_chip running={row.running} />
              </div>
            </div>
          </.link>

          <%!-- Outside the link, not inside it: a button nested in an anchor is
                invalid markup and a coin flip about which one the click hits.
                Always visible, never hover-only — half this app is read on a
                phone, where hover does not exist. --%>
          <div class="mt-auto flex justify-end border-t border-hairline-soft px-2">
            <.delete_deck_button row={row} />
          </div>
        </li>
      </ul>

      <ul
        :if={@deck_layout == "lista"}
        class="divide-y divide-hairline-soft rounded-xl border border-hairline-soft bg-surface"
      >
        <li
          :for={row <- @decks}
          class="flex items-center gap-3 pr-2 transition-colors hover:bg-surface-2 motion-reduce:transition-none"
        >
          <.link
            navigate={~p"/decks/#{row.deck.id}"}
            class="flex min-w-0 flex-1 items-center gap-4 p-3"
          >
            <div class="h-touch w-[72px] shrink-0 overflow-hidden rounded-md bg-inlay">
              <img
                :if={row.commander}
                src={row.commander.card.image_art_crop_url}
                alt=""
                class="size-full object-cover"
              />
            </div>

            <%!-- The name owns the leftover width and every other column is
                  fixed, so each column that survives a narrow screen is one
                  the name loses. Below `sm` they all fold into the block
                  below — a row where the deck's own name got crushed to
                  nothing is not a list of decks. --%>
            <div class="min-w-0 flex-1">
              <h2 class="truncate text-body font-semibold leading-tight text-ink">
                {row.deck.name}
              </h2>
              <p :if={row.commander} class="truncate text-caption text-ink-muted">
                {row.commander.card.name}
              </p>
              <p class="mt-0.5 flex flex-wrap items-center gap-2 sm:hidden">
                <.color_identity colors={row.deck.color_identity} size={11} />
                <span class={["font-mono text-micro", vital_tone(row)]}>{vital_sign(row)}</span>
                <.run_chip running={row.running} />
              </p>
            </div>

            <%!-- Wrapped rather than passed `hidden`: the component hardcodes
                  `inline-flex`, and two display utilities on one element is a
                  coin flip decided by Tailwind's output order, not by the one
                  written last. --%>
            <span class="hidden shrink-0 sm:block">
              <.color_identity colors={row.deck.color_identity} full size={13} />
            </span>

            <span class="hidden w-16 shrink-0 rounded-md bg-inlay px-2 py-0.5 text-center font-mono text-micro text-ink-secondary sm:block">
              B{row.bracket.floor}+
            </span>

            <span class="hidden w-20 shrink-0 text-right font-mono text-caption text-ink-faint md:block">
              {row.cards} cartas
            </span>

            <span class={[
              "hidden w-24 shrink-0 text-right font-mono text-caption sm:block",
              vital_tone(row)
            ]}>
              {vital_sign(row)}
            </span>

            <span class="hidden shrink-0 sm:block">
              <.run_chip running={row.running} />
            </span>
          </.link>

          <.delete_deck_button row={row} />
        </li>
      </ul>
    </div>
    """
  end

  attr :running, :map, default: nil

  defp run_chip(assigns) do
    ~H"""
    <span
      :if={@running}
      class={[
        "inline-flex shrink-0 items-center gap-1.5 rounded-full px-2 py-0.5 font-mono text-micro",
        @running.status == :awaiting_choice && "bg-sev-warning/15 text-sev-warning",
        @running.status != :awaiting_choice && "bg-inlay text-ink-secondary"
      ]}
    >
      <span
        :if={@running.status == :running}
        class="size-1.5 animate-pulse rounded-full bg-current motion-reduce:animate-none"
        aria-hidden="true"
      />
      {run_chip_label(@running.status)}
    </span>
    """
  end

  defp run_chip_label(:awaiting_choice), do: "esperando você"
  defp run_chip_label(:paused), do: "otimização pausada"
  defp run_chip_label(_running), do: "otimizando"

  attr :row, :map, required: true

  defp delete_deck_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="delete"
      phx-value-id={@row.deck.id}
      data-confirm={delete_warning(@row)}
      aria-label={"Apagar #{@row.deck.name}"}
      class="inline-flex min-h-touch shrink-0 items-center px-3 text-caption text-ink-faint transition-colors hover:text-sev-critical motion-reduce:transition-none"
    >
      Apagar
    </button>
    """
  end

  # The Quiet-Health Rule: a deck that is fine gets the calm colour, and only a
  # critical count is allowed to pull the eye across the room.
  defp vital_tone(%{critical: 0}), do: "text-sev-healthy"
  defp vital_tone(_row), do: "text-sev-critical"

  defp vital_sign(%{critical: 0, findings: 0}), do: "tudo certo"
  defp vital_sign(%{critical: 0, findings: n}), do: "#{n} #{pluralise(n, "aviso", "avisos")}"
  defp vital_sign(%{critical: n}), do: "#{n} #{pluralise(n, "crítico", "críticos")}"

  defp pluralise(1, singular, _plural), do: singular
  defp pluralise(_n, _singular, plural), do: plural
end
