defmodule DeckexWeb.DeckLive do
  @moduledoc """
  One deck, measured.

  The findings come first and the raw measurements second, deliberately: the
  numbers are evidence for the findings, not the point. A player opening this
  screen wants to know what is wrong before they want to know the average
  converted mana cost.
  """
  use DeckexWeb, :live_view

  alias Deckex.Analysis
  alias Deckex.Decks
  alias Deckex.Error

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    case Decks.fetch_deck(id) do
      {:ok, deck} ->
        {:ok, assign_deck(socket, deck)}

      {:error, %Error{} = error} ->
        {:ok, socket |> put_flash(:error, error.message) |> push_navigate(to: ~p"/")}
    end
  end

  defp assign_deck(socket, deck) do
    snapshot = Decks.snapshot(deck)

    assign(socket,
      deck: deck,
      snapshot: snapshot,
      report: Analysis.report(snapshot),
      page_title: deck.name
    )
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-5xl px-6 py-10">
      <.link navigate={~p"/"} class="text-caption text-ink-faint transition-colors hover:text-ink">
        ← A Mesa
      </.link>

      <header class="mt-3 mb-8 flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 class="text-hero font-semibold text-ink">{@deck.name}</h1>
          <p :for={commander <- @snapshot.commanders} class="mt-1 flex items-center gap-2">
            <span class="text-body text-ink-secondary">{commander.card.name}</span>
            <.mana_cost cost={commander.card.mana_cost} size={14} />
          </p>
        </div>
        <.color_identity colors={@deck.color_identity} full size={18} />
      </header>

      <section class="mb-10">
        <h2 class="mb-3 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
          Achados
        </h2>

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
          >
            <:detail>{finding.detail}</:detail>
          </.finding>
        </div>
      </section>

      <section class="mb-10">
        <h2 class="mb-3 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
          Curva de mana
        </h2>

        <div class="rounded-xl border border-hairline-soft bg-surface p-5">
          <div class="flex items-end gap-2">
            <.curve_bar
              :for={bucket <- 0..7}
              label={if bucket == 7, do: "7+", else: to_string(bucket)}
              count={Map.get(@report.curve.histogram, bucket, 0)}
              max={curve_max(@report.curve.histogram)}
            />
          </div>

          <div class="mt-5 grid grid-cols-2 gap-4 sm:grid-cols-4">
            <.stat label="Custo médio" value={Format.decimal(@report.curve.avg_cmc, 2)} />
            <.stat label="Até 3 de mana" value={to_string(@report.curve.early_plays)} unit="cartas" />
            <.stat label="De 5 pra cima" value={to_string(@report.curve.late_game)} unit="cartas" />
            <.stat label="Não-terrenos" value={to_string(@report.curve.nonland_count)} />
          </div>
        </div>
      </section>

      <section class="mb-10">
        <h2 class="mb-3 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
          Mana e aceleração
        </h2>

        <div class="rounded-xl border border-hairline-soft bg-surface p-5">
          <div class="grid grid-cols-2 gap-4 sm:grid-cols-4">
            <.stat
              label="Terrenos"
              value={Format.decimal(@report.mana.land_count, 1)}
              target={"alvo #{@report.mana.land_target}"}
              tone={land_tone(@report.mana)}
            />
            <.stat label="Ramp" value={to_string(@report.mana.ramp_total)} unit="peças" />
            <.stat label="Ramp barato" value={to_string(@report.mana.ramp_cheap)} unit="até 2" />
            <.stat label="Entram virados" value={to_string(@report.mana.taplands)} />
          </div>

          <div class="mt-5 grid grid-cols-[auto_1fr_auto] items-center gap-x-3 gap-y-2.5 border-t border-hairline-subtle pt-4">
            <%= for {colour, measured} <- Enum.sort(@report.mana.colors) do %>
              <.mana_pip symbol={pip(colour)} size={18} />

              <span class="font-mono text-body-sm">
                <span class="text-ink">{measured.sources}</span><span class="text-ink-faint">/{measured.target}</span>
                <span class="text-ink-faint">fontes</span>
                <span class="hidden text-ink-disabled sm:inline">· pip máx {measured.max_pips}</span>
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

      <section class="mb-10 grid gap-4 md:grid-cols-2">
        <div>
          <h2 class="mb-3 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
            Interação
          </h2>
          <div class="grid grid-cols-2 gap-4 rounded-xl border border-hairline-soft bg-surface p-5">
            <.stat
              label="Respostas reais"
              value={to_string(@report.interaction.answers)}
              tone={:neutral}
            >
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
        </div>

        <div>
          <h2 class="mb-3 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
            Consistência
          </h2>
          <div class="grid grid-cols-2 gap-4 rounded-xl border border-hairline-soft bg-surface p-5">
            <.stat label="Compra" value={to_string(@report.consistency.draw)} unit="peças" />
            <.stat label="Tutores" value={to_string(@report.consistency.tutors)} />
            <.stat label="Recursão" value={to_string(@report.consistency.recursion)} />
            <.stat
              label="Win conditions"
              value={to_string(@report.consistency.wincons)}
              tone={if @report.consistency.wincons == 0, do: :critical, else: :neutral}
            />
          </div>
        </div>
      </section>

      <section>
        <h2 class="mb-3 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
          As cartas ({Enum.sum(Enum.map(@snapshot.main, & &1.quantity))})
        </h2>

        <ul class="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4">
          <li :for={entry <- sorted_cards(@snapshot)}>
            <.card_tile
              name={entry.card.name}
              art={entry.card.image_art_crop_url}
              mana_cost={entry.card.mana_cost}
              type_line={entry.card.type_line}
              quantity={entry.quantity}
            />
          </li>
        </ul>
      </section>
    </div>
    """
  end

  # Format speaks in mana costs, so a bare colour code becomes a one-symbol cost.
  defp pip(colour), do: "{#{colour}}" |> Format.mana_symbols() |> hd()

  defp curve_max(histogram) do
    histogram |> Map.values() |> Enum.max(fn -> 1 end) |> max(1)
  end

  defp land_tone(%{land_count: count, land_target: target}) when count < target - 1, do: :critical
  defp land_tone(%{land_count: count, land_target: target}) when count > target + 2, do: :warning
  defp land_tone(_mana), do: :healthy

  # Cheapest first, then alphabetical — the order a player reads their own list.
  defp sorted_cards(snapshot) do
    Enum.sort_by(snapshot.main, &{Decimal.to_float(&1.card.cmc), &1.card.name})
  end
end
