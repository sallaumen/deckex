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

  alias Deckex.Analysis
  alias Deckex.Consults
  alias Deckex.Decks
  alias Deckex.Error
  alias Deckex.Events

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
    if connected?(socket), do: Events.subscribe_consults(deck.id)

    snapshot = Decks.snapshot(deck)

    assign(socket,
      deck: deck,
      snapshot: snapshot,
      report: Analysis.report(snapshot),
      consults: Consults.list_for_deck(deck),
      page_title: deck.name
    )
  end

  @impl Phoenix.LiveView
  def handle_event("consult-finding", %{"code" => code}, socket) do
    {:noreply, start_consult(socket, :finding, finding_code: code)}
  end

  def handle_event("consult-full", _params, socket) do
    {:noreply, start_consult(socket, :full)}
  end

  @impl Phoenix.LiveView
  def handle_info({:consult_updated, _id}, socket) do
    {:noreply, assign(socket, consults: Consults.list_for_deck(socket.assigns.deck))}
  end

  # Consults.request/3 raises rather than returning a tagged error — every
  # field it writes is built here, so a failure is a bug, not a user problem.
  defp start_consult(socket, lens, opts \\ []) do
    {:ok, _consult} = Consults.request(socket.assigns.deck, lens, opts)

    socket
    |> put_flash(:info, "Consulta enviada. A resposta aparece aqui quando chegar.")
    |> assign(consults: Consults.list_for_deck(socket.assigns.deck))
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-[1800px] px-6 py-10 lg:px-10 lg:py-14">
      <.link navigate={~p"/"} class="text-caption text-ink-faint transition-colors hover:text-ink">
        ← A Mesa
      </.link>

      <header class="mt-3 mb-10 flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 class="text-hero font-semibold text-ink">{@deck.name}</h1>
          <p :for={commander <- @snapshot.commanders} class="mt-1 flex items-center gap-2">
            <span class="text-body text-ink-secondary">{commander.card.name}</span>
            <.mana_cost cost={commander.card.mana_cost} size={14} />
          </p>
        </div>
        <.color_identity colors={@deck.color_identity} full size={20} />
      </header>

      <div class="grid gap-10 xl:grid-cols-[minmax(340px,26rem)_1fr] xl:items-start">
        <aside class="xl:sticky xl:top-8 xl:max-h-[calc(100vh-4rem)] xl:overflow-y-auto">
          <div class="mb-3 flex items-center justify-between gap-3">
            <h2 class="text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
              Achados
            </h2>

            <button
              type="button"
              phx-click="consult-full"
              class="text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
            >
              Consultar o deck inteiro
            </button>
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
            >
              <:detail>{finding.detail}</:detail>
              <:actions>
                <button
                  type="button"
                  phx-click="consult-finding"
                  phx-value-code={finding.code}
                  class="text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
                >
                  Pedir diagnóstico
                </button>
              </:actions>
            </.finding>
          </div>

          <section :if={@consults != []} class="mt-8">
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

                <p :if={consult.error} class="text-body-sm text-ink-secondary">{consult.error}</p>

                <div :if={consult.response} class="space-y-3">
                  <p class="text-body-sm text-ink">{consult.response["diagnosis"]}</p>

                  <div :if={consult.response["cuts"] not in [nil, []]}>
                    <p class="mb-1 text-label uppercase tracking-[0.1em] text-ink-faint">Cortar</p>
                    <ul class="space-y-1">
                      <li :for={cut <- consult.response["cuts"]} class="text-caption">
                        <span class="text-ink">{cut["card"]}</span>
                        <span class="text-ink-muted">— {cut["reason"]}</span>
                      </li>
                    </ul>
                  </div>

                  <div :if={consult.response["adds"] not in [nil, []]}>
                    <p class="mb-1 text-label uppercase tracking-[0.1em] text-ink-faint">Colocar</p>
                    <ul class="space-y-1">
                      <li :for={add <- consult.response["adds"]} class="text-caption">
                        <span class="text-ink">{add["card"]}</span>
                        <span class="text-ink-muted">— {add["reason"]}</span>
                      </li>
                    </ul>
                  </div>
                </div>

                <details class="mt-3">
                  <summary class="cursor-pointer text-caption text-ink-faint hover:text-ink">
                    Ver o prompt
                  </summary>
                  <pre class="mt-2 max-h-64 overflow-auto rounded-md bg-inlay p-3 font-mono text-micro text-ink-muted">{consult.briefing}</pre>
                </details>
              </article>
            </div>
          </section>
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

              <div class="mt-6 grid grid-cols-2 gap-5 border-t border-hairline-subtle pt-5 sm:grid-cols-4">
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
                  <.stat label="Entram virados" value={to_string(@report.mana.taplands)} />
                </div>

                <div class="mt-6 grid grid-cols-[auto_1fr_auto] items-center gap-x-4 gap-y-3 border-t border-hairline-subtle pt-5">
                  <%= for {colour, measured} <- Enum.sort(@report.mana.colors) do %>
                    <.mana_pip symbol={pip(colour)} size={20} />

                    <span class="font-mono text-body-sm">
                      <span class="text-ink">{measured.sources}</span><span class="text-ink-faint">/{measured.target}</span>
                      <span class="text-ink-faint">fontes</span>
                      <span class="hidden text-ink-disabled sm:inline">
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
        </div>
      </div>

      <section class="mt-12">
        <h2 class="mb-3 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
          As cartas ({Enum.sum(Enum.map(@snapshot.main, & &1.quantity))})
        </h2>

        <ul class="grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-6 2xl:grid-cols-8">
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

  # Cheapest first, then alphabetical — the order a player reads their own list.
  defp sorted_cards(snapshot) do
    Enum.sort_by(snapshot.main, &{Decimal.to_float(&1.card.cmc), &1.card.name})
  end
end
