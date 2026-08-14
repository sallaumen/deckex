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

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    # No page_title: the root layout already suffixes " · A Mesa", and this
    # screen IS A Mesa — setting it would render "A Mesa · A Mesa".
    {:ok, assign(socket, decks: load_decks())}
  end

  # One report per deck. Building a report is arithmetic over ~100 structs, so
  # this stays cheap for the handful of decks one person tracks; if that ever
  # stops being true, the vital sign is what to cache, not the report.
  defp load_decks do
    Enum.map(Decks.list_decks(), fn deck ->
      snapshot = Decks.snapshot(deck)
      report = Analysis.report(snapshot)

      %{
        deck: deck,
        commander: List.first(snapshot.commanders),
        critical: Report.critical_count(report),
        bracket: report.bracket,
        findings: length(report.findings),
        cards: Enum.sum(Enum.map(snapshot.main, & &1.quantity))
      }
    end)
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

      <header class="mb-8 flex items-end justify-between gap-4">
        <div>
          <h1 class="text-display font-semibold text-ink">A Mesa</h1>
          <p class="mt-1 text-body text-ink-muted">
            {length(@decks)} {if length(@decks) == 1, do: "deck", else: "decks"} na mesa.
          </p>
        </div>

        <div class="flex items-center gap-4">
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

      <ul class="grid gap-5 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 2xl:grid-cols-5">
        <li :for={row <- @decks}>
          <.link
            navigate={~p"/decks/#{row.deck.id}"}
            class="group block overflow-hidden rounded-xl border border-hairline-soft bg-surface transition-colors hover:border-hairline-strong"
          >
            <div class="aspect-[16/9] overflow-hidden bg-inlay">
              <img
                :if={row.commander}
                src={row.commander.card.image_art_crop_url}
                alt={row.commander.card.name}
                class="size-full object-cover transition-transform duration-300 group-hover:scale-[1.03]"
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

              <div class="flex items-center gap-3 text-caption text-ink-faint">
                <span class="font-mono">{row.cards} cartas</span>
                <span aria-hidden="true">·</span>
                <span class={[
                  "font-mono",
                  row.critical > 0 && "text-sev-critical",
                  row.critical == 0 && "text-sev-healthy"
                ]}>
                  {vital_sign(row)}
                </span>
              </div>
            </div>
          </.link>
        </li>
      </ul>
    </div>
    """
  end

  defp vital_sign(%{critical: 0, findings: 0}), do: "tudo certo"
  defp vital_sign(%{critical: 0, findings: n}), do: "#{n} #{pluralise(n, "aviso", "avisos")}"
  defp vital_sign(%{critical: n}), do: "#{n} #{pluralise(n, "crítico", "críticos")}"

  defp pluralise(1, singular, _plural), do: singular
  defp pluralise(_n, _singular, plural), do: plural
end
