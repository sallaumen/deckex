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
  alias Deckex.Consults.Suggestions
  alias Deckex.Decks
  alias Deckex.Error
  alias Deckex.Events
  alias Deckex.Money
  alias Deckex.Settings

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

    socket
    |> assign(
      deck: deck,
      snapshot: snapshot,
      report: Analysis.report(snapshot, Settings.baselines()),
      model: Settings.model(),
      page_title: deck.name
    )
    |> refresh_consults()
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

  def handle_event("apply-add", %{"name" => name}, socket) do
    {:noreply, apply_edit(socket, Decks.add_card(socket.assigns.deck, name), "#{name} entrou.")}
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

  defp refresh_consults(socket) do
    consults = Consults.list_for_deck(socket.assigns.deck)
    suggestions = Map.new(consults, &{&1.id, Suggestions.for_consult(&1)})

    assign(socket,
      consults: consults,
      suggestions: suggestions,
      audits: audits(socket.assigns.snapshot, suggestions),
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
  defp audits(snapshot, suggestions) do
    suggestions
    |> Enum.reject(fn {_id, rows} -> rows == [] end)
    |> Map.new(fn {id, rows} -> {id, Consults.audit(snapshot, rows)} end)
  end

  defp problems_for(nil, _action, _name), do: []
  defp problems_for(audit, action, name), do: Map.get(audit.problems, {action, name}, [])

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
      <.link
        navigate={~p"/"}
        class="-my-2 inline-flex min-h-11 items-center py-2 text-caption text-ink-faint transition-colors hover:text-ink"
      >
        ← A Mesa
      </.link>

      <header class="mt-3 mb-10 flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 class="text-display font-semibold text-ink">{@deck.name}</h1>
          <p :for={commander <- @snapshot.commanders} class="mt-1 flex items-center gap-2">
            <span class="text-body text-ink-secondary">{commander.card.name}</span>
            <.mana_cost cost={commander.card.mana_cost} size={14} />
          </p>
        </div>
        <.color_identity colors={@deck.color_identity} full size={20} />
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
                class="-my-2 inline-flex min-h-11 items-center px-1 py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink disabled:cursor-not-allowed disabled:text-ink-disabled disabled:no-underline"
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
                  class="min-h-11 w-full rounded-md border border-hairline-soft bg-inlay px-2 py-2 text-caption text-ink"
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
                  class="min-h-11 w-full rounded-md border border-hairline-soft bg-inlay px-2 py-2 font-mono text-caption text-ink"
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
                  class="min-h-11 w-full rounded-md border border-hairline-soft bg-inlay px-2 py-2 text-caption text-ink placeholder:text-ink-faint"
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
            >
              <:detail>{finding.detail}</:detail>
              <:actions>
                <button
                  type="button"
                  phx-click="consult-finding"
                  phx-disable-with="enviando…"
                  phx-value-code={finding.code}
                  class="-my-2 inline-flex min-h-11 items-center px-1 py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
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
                  <.stat label="Entram virados" value={to_string(@report.mana.taplands)} />
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
                    {dossier_source_label(@deck.dossier_source)} · {Calendar.strftime(
                      @deck.dossier_updated_at,
                      "%d/%m %H:%M"
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
                    class="-my-2 inline-flex min-h-11 items-center px-1 py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
                  >
                    Rerodar o scout
                  </button>
                </div>

                <details>
                  <summary class="cursor-pointer text-caption text-ink-faint hover:text-ink">
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

                  <div :if={@suggestions[consult.id] not in [nil, []]} class="overflow-x-auto">
                    <table class="w-full text-caption">
                      <thead>
                        <tr class="border-b border-hairline-soft text-left text-label uppercase tracking-[0.1em] text-ink-faint">
                          <th class="py-1.5 pr-2 font-semibold">Carta</th>
                          <th class="py-1.5 pr-2 text-right font-semibold">Preço</th>
                          <th class="py-1.5 font-semibold"></th>
                        </tr>
                      </thead>
                      <tbody>
                        <tr
                          :for={row <- @suggestions[consult.id]}
                          class="border-b border-hairline-soft align-top last:border-0"
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
                              <span class="text-ink">{row.name}</span>
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
                          </td>

                          <td class="py-2 pr-2 text-right font-mono text-micro whitespace-nowrap">
                            <div class="text-ink-secondary">{Money.brl(row.price_usd)}</div>
                            <div class="text-ink-muted">{Money.usd(row.price_usd)}</div>
                          </td>

                          <td class="py-2 text-right">
                            <button
                              :if={row.resolved?}
                              type="button"
                              phx-click={if row.action == :cut, do: "apply-cut", else: "apply-add"}
                              phx-value-name={row.name}
                              class="-my-2 inline-flex min-h-11 items-center whitespace-nowrap px-1 py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
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

                    <div class="mt-2 flex items-center justify-between gap-3">
                      <span class="font-mono text-micro text-ink-faint">
                        entradas: {Money.brl(Suggestions.total_usd(@suggestions[consult.id]))}
                      </span>

                      <a
                        href={~p"/consultas/#{consult.id}/csv"}
                        download
                        class="-my-2 inline-flex min-h-11 items-center px-1 py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
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
                  <summary class="cursor-pointer text-caption text-ink-faint hover:text-ink">
                    Ver o prompt
                  </summary>
                  <pre class="mt-2 max-h-64 overflow-auto rounded-md bg-inlay p-3 font-mono text-micro text-ink-muted">{consult.briefing}</pre>
                </details>
              </article>
            </div>
          </section>
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
