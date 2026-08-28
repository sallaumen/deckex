defmodule DeckexWeb.VersionsLive do
  @moduledoc """
  One deck's line of versions: what each one did, going back to one, and what
  it costs to get from one to another.

  The comparison is the reason this screen exists rather than a list on the
  deck page. "Which cards do I have to buy, holding v1, to end up at v7" is the
  question an owner asks with a shop open in the next tab, and it needs two
  pickers and a total — not a footnote.
  """
  use DeckexWeb, :live_view

  alias Deckex.Decks
  alias Deckex.Decks.DeckVersion
  alias Deckex.Decks.Versions
  alias Deckex.Error
  alias Deckex.Money
  alias DeckexWeb.Clock

  @impl Phoenix.LiveView
  def mount(%{"id" => deck_id}, _session, socket) do
    case Decks.fetch_deck(deck_id) do
      {:ok, deck} ->
        {:ok, load(socket, deck)}

      {:error, %Error{} = error} ->
        {:ok, socket |> put_flash(:error, error.message) |> push_navigate(to: ~p"/")}
    end
  end

  defp load(socket, deck) do
    versions = Versions.list(deck)

    socket
    |> assign(
      deck: deck,
      versions: versions,
      drifted?: Versions.drifted?(deck),
      page_title: "Versões · #{deck.name}"
    )
    # The default comparison is the one the owner almost always wants: the
    # oldest against the newest, which is "everything that happened". A choice
    # already made survives a reload; a number that no longer exists does not.
    |> assign(
      from: kept_or(socket.assigns[:from], versions, &List.last/1),
      to: kept_or(socket.assigns[:to], versions, &List.first/1)
    )
    |> compare()
  end

  defp kept_or(chosen, versions, fallback) do
    numbers = Enum.map(versions, & &1.number)

    if chosen in numbers, do: chosen, else: versions |> fallback.() |> number_of()
  end

  defp number_of(nil), do: nil
  defp number_of(%DeckVersion{number: number}), do: number

  defp compare(socket) do
    %{deck: deck, from: from, to: to} = socket.assigns

    with true <- not is_nil(from) and not is_nil(to),
         {:ok, from_version} <- Versions.fetch(deck, from),
         {:ok, to_version} <- Versions.fetch(deck, to) do
      assign(socket, diff: Versions.diff(from_version, to_version))
    else
      _nothing_to_compare -> assign(socket, diff: nil)
    end
  end

  @impl Phoenix.LiveView
  def handle_event("comparar", %{"from" => from, "to" => to}, socket) do
    {:noreply,
     socket
     |> assign(from: String.to_integer(from), to: String.to_integer(to))
     |> compare()}
  end

  def handle_event("marcar", _params, socket) do
    {:ok, version} = Versions.mark(socket.assigns.deck)

    {:noreply,
     socket
     # The version just made is what the owner wants to look at, so the
     # comparison moves to it rather than staying on whatever it held before.
     |> assign(to: version.number)
     |> load(socket.assigns.deck)
     |> put_flash(:info, "Versão v#{version.number} marcada.")}
  end

  def handle_event("restaurar", %{"number" => number}, socket) do
    deck = socket.assigns.deck

    with {:ok, version} <- Versions.fetch(deck, String.to_integer(number)),
         {:ok, restored} <- Versions.restore(deck, version) do
      {:noreply,
       socket
       |> load(restored)
       |> put_flash(:info, "Deck voltou para a v#{version.number}. As versões seguintes ficam.")}
    else
      {:error, %Error{} = error} -> {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  defp origin_label(:import), do: "importado"
  defp origin_label(:optimization), do: "otimização"
  defp origin_label(:consult), do: "consulta"
  defp origin_label(:manual), do: "marcada por você"

  # A version that changed nothing is worth saying so out loud: it means the
  # owner marked the same list twice, which is a fact, not an error.
  defp change_summary(version) do
    applied = DeckVersion.applied(version)
    adds = Enum.count(applied, &(&1["action"] == "add"))
    cuts = Enum.count(applied, &(&1["action"] == "cut"))

    if applied == [], do: "sem mudanças", else: "+#{adds} / −#{cuts}"
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-[1100px] px-6 py-10 lg:px-10 lg:py-14 2xl:max-w-[1440px] 3xl:max-w-[1700px]">
      <DeckexWeb.Layouts.flash_group flash={@flash} />
      <.live_component module={DeckexWeb.SettingsPanel} id="settings-panel" />

      <.link
        navigate={~p"/decks/#{@deck.id}"}
        class="-my-2 inline-flex min-h-touch items-center py-2 text-caption text-ink-faint transition-colors hover:text-ink"
      >
        ← {@deck.name}
      </.link>

      <.deck_nav deck={@deck} current={:versions} />

      <header class="mt-3 mb-8 flex flex-col items-start gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h1 class="text-display font-semibold text-ink">Versões</h1>
          <p class="mt-1 text-body text-ink-muted">
            Cada versão é uma foto do deck. Voltar para uma não apaga as outras.
          </p>
        </div>

        <%!-- A version identical to the one before it is a row that says
              nothing happened. The button says why it is off instead of
              quietly making one. --%>
        <.button
          type="button"
          phx-click="marcar"
          variant={if @drifted?, do: "primary", else: nil}
          disabled={not @drifted?}
          title={
            if @drifted?,
              do: "Guarda a lista como ela está agora",
              else: "Nada mudou desde a última versão"
          }
        >
          Marcar versão agora
        </.button>
      </header>

      <%!-- Said before it is discovered: an owner who edited five cards and
            never marked a version should not learn that from a diff. --%>
      <p
        :if={@drifted?}
        class="mb-6 rounded-lg border border-sev-warning/40 bg-sev-warning/10 px-4 py-3 text-caption text-ink"
      >
        O deck mudou desde a última versão. Marque uma para guardar onde ele está agora.
      </p>

      <div
        :if={@versions == []}
        class="rounded-xl border border-hairline-soft bg-surface p-10 text-center"
      >
        <p class="text-body text-ink-secondary">Nenhuma versão ainda.</p>
      </div>

      <%!-- Two panes past 2xl: picking two versions and reading the history are
            the same act, and stacked they were a tool you scrolled away from
            the moment you used it. The comparison keeps its own column and
            stays on screen — it is a control, and the timeline beside it is
            what the control is aimed at. --%>
      <div class={[
        "2xl:gap-8",
        length(@versions) > 1 &&
          "2xl:grid 2xl:grid-cols-[minmax(0,26rem)_minmax(0,1fr)] 2xl:items-start"
      ]}>
        <section
          :if={length(@versions) > 1}
          class="mb-8 rounded-xl border border-hairline-soft bg-surface p-6 2xl:sticky 2xl:top-8 2xl:mb-0 2xl:max-h-[calc(100vh-4rem)] 2xl:overflow-y-auto"
        >
          <h2 class="mb-3 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
            Comparar
          </h2>

          <.form for={%{}} id="comparar" phx-change="comparar" class="flex flex-wrap items-end gap-3">
            <div>
              <label for="from" class="mb-1 block text-caption text-ink-secondary">Tenho a</label>
              <select id="from" name="from" class={select_class()}>
                <option
                  :for={version <- @versions}
                  value={version.number}
                  selected={version.number == @from}
                >
                  v{version.number} · {origin_label(version.origin)}
                </option>
              </select>
            </div>

            <div>
              <label for="to" class="mb-1 block text-caption text-ink-secondary">Quero a</label>
              <select id="to" name="to" class={select_class()}>
                <option
                  :for={version <- @versions}
                  value={version.number}
                  selected={version.number == @to}
                >
                  v{version.number} · {origin_label(version.origin)}
                </option>
              </select>
            </div>
          </.form>

          <div :if={@diff} class="mt-5">
            <p :if={@diff.buy == [] and @diff.drop == []} class="text-body text-ink-secondary">
              Nada muda entre essas duas — as listas são iguais.
            </p>

            <div :if={@diff.buy != []} class="mb-4">
              <h3 class="mb-2 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
                Comprar ({length(@diff.buy)})
              </h3>
              <ul class="divide-y divide-hairline-soft">
                <li
                  :for={item <- @diff.buy}
                  class="flex flex-wrap items-baseline gap-x-2 py-1.5 first:pt-0"
                >
                  <span class="font-mono text-micro text-ink-faint">{item.quantity}×</span>
                  <.card_link
                    name={item.name}
                    uri={item.card && item.card.scryfall_uri}
                    class="text-ink"
                  />
                  <.play_rate card={item.card} />
                  <span class="ml-auto font-mono text-caption text-ink-secondary">
                    {Money.brl(item.price_usd)}
                  </span>
                </li>
              </ul>

              <div class="mt-3 flex flex-wrap items-baseline justify-between gap-3 border-t border-hairline-soft pt-3">
                <p class="font-mono text-numeral-sm leading-none text-ink">
                  {Money.brl(@diff.total_usd)}
                </p>
                <a
                  href={~p"/decks/#{@deck.id}/versoes/#{@from}/para/#{@to}/compras.txt"}
                  download
                  class="-my-2 inline-flex min-h-touch items-center px-1 py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
                >
                  Baixar a lista de compra
                </a>
              </div>

              <p :if={@diff.unpriced > 0} class="mt-2 text-micro text-ink-faint">
                {@diff.unpriced} carta(s) sem preço conhecido não entram no total.
              </p>
            </div>

            <div :if={@diff.drop != []}>
              <h3 class="mb-2 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
                Sai do deck ({length(@diff.drop)})
              </h3>
              <p class="text-caption text-ink-muted">
                {Enum.map_join(@diff.drop, ", ", & &1.name)}
              </p>
            </div>
          </div>
        </section>

        <ol class="space-y-3">
          <li
            :for={version <- @versions}
            class="rounded-xl border border-hairline-soft bg-surface p-5"
          >
            <div class="flex flex-wrap items-baseline justify-between gap-3">
              <h2 class="text-heading font-semibold text-ink">
                v{version.number}
                <span :if={version.label} class="text-body font-normal text-ink-secondary">
                  — {version.label}
                </span>
              </h2>

              <span class="font-mono text-caption text-ink-faint">
                {origin_label(version.origin)} · {Clock.moment(version.inserted_at)} · {DeckVersion.size(
                  version
                )} cartas · {change_summary(version)}
              </span>
            </div>

            <%!-- The three screens are one loop: deck → versões → a rodada que
                fez esta. Without the way back, the label "otimização" names a
                thing you cannot open. --%>
            <.link
              :if={version.optimization_id}
              navigate={~p"/otimizacoes/#{version.optimization_id}"}
              class="-my-2 mt-1 inline-flex min-h-touch items-center py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
            >
              ver a rodada →
            </.link>

            <ul :if={DeckVersion.applied(version) != []} class="mt-3 max-w-[78ch] space-y-1">
              <li
                :for={change <- DeckVersion.applied(version)}
                class="text-caption text-ink-secondary"
              >
                <span class={[
                  "font-mono",
                  change["action"] == "add" && "text-sev-healthy",
                  change["action"] == "cut" && "text-sev-critical"
                ]}>
                  {if change["action"] == "add", do: "+", else: "−"}
                </span>
                {change["card"]}
                <span :if={change["reason"]} class="text-ink-muted">— {change["reason"]}</span>
              </li>
            </ul>

            <div class="mt-4 border-t border-hairline-soft pt-3">
              <button
                type="button"
                phx-click="restaurar"
                phx-value-number={version.number}
                data-confirm={"Voltar o deck para a v#{version.number}? As versões seguintes continuam guardadas."}
                class="-my-2 inline-flex min-h-touch items-center px-1 py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
              >
                Voltar para esta versão
              </button>
            </div>
          </li>
        </ol>
      </div>
    </div>
    """
  end

  # The app has one control style; this screen does not get its own.
  defp select_class, do: [control_class(), "min-h-touch"]
end
