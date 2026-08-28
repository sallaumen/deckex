defmodule DeckexWeb.SettingsPanel do
  @moduledoc """
  Every knob in the app, one click away from every screen.

  A `live_component` rather than a page because settings are something you
  adjust *while looking at the thing they affect* — the price ceiling means
  something next to the suggestion it just rejected, and nothing on a separate
  screen you had to navigate to and back from.

  It owns its own open state and its own saves (`phx-target={@myself}`), so a
  LiveView adopts it with one line and no event handlers of its own.

  The baselines live behind a `<details>`: nineteen thresholds are the least
  frequently changed thing here, and the two ceilings are the most.
  """
  use DeckexWeb, :live_component

  alias Deckex.Analysis.Baselines
  alias Deckex.Cards
  alias Deckex.Settings
  alias Deckex.Settings.Registry
  alias Deckex.Workers.CatalogueWorker
  alias Deckex.Workers.RepriceWorker

  @groups [
    {:ai, "Inteligência artificial"},
    {:budget, "Tetos de preço"},
    {:moxfield, "Moxfield"},
    {:analysis, "Conversão e baselines"}
  ]

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:open, fn -> false end)
     |> assign_new(:refreshed, fn -> nil end)
     |> assign_new(:refetching, fn -> nil end)
     |> assign_new(:repricing, fn -> nil end)
     |> assign_new(:saved, fn -> nil end)
     |> assign_new(:errors, fn -> %{} end)
     # The action buttons keep one page-level message; the fields have their own.
     |> assign_new(:error, fn -> nil end)
     |> load()}
  end

  # `error: nil` used to live here, which meant any re-render from the parent
  # wiped the message before it could be read. Errors are per field now and
  # survive until that field saves.
  defp load(socket) do
    assign(socket, values: Settings.all(), baselines: Settings.baselines())
  end

  @impl Phoenix.LiveComponent
  def handle_event("open", _params, socket), do: {:noreply, assign(socket, open: true)}

  def handle_event("close", _params, socket), do: {:noreply, assign(socket, open: false)}

  # The Panel revises the Game Changers list a few times a year. Re-reading it
  # is a click rather than a schedule: this is a single-user app that is not
  # always running, and a stale restriction is visible on the deck page anyway.
  def handle_event("refresh-game-changers", _params, socket) do
    case Cards.refresh_game_changers() do
      {:ok, %{marked: marked}} -> {:noreply, assign(socket, error: nil, refreshed: marked)}
      {:error, error} -> {:noreply, assign(socket, error: error.message)}
    end
  end

  # A price is the one card fact that goes stale on its own, and the catalogue
  # holds the price of whichever printing a name lookup returned — a number
  # that can be double what the card actually costs, or missing entirely. This
  # queues the correction; the work happens on the scryfall queue, one job at a
  # time, because it costs a request per card.
  def handle_event("reprice-catalogue", _params, socket) do
    case RepriceWorker.enqueue_all() do
      {:ok, queued} -> {:noreply, assign(socket, error: nil, repricing: queued)}
      {:error, _reason} -> {:noreply, assign(socket, error: "Não consegui enfileirar.")}
    end
  end

  # The cheap half of the same button: after one full sweep almost nothing is
  # stale, so this is usually a handful of requests instead of one per card.
  def handle_event("reprice-stale", _params, socket) do
    case RepriceWorker.enqueue_stale() do
      {:ok, _job} ->
        {:noreply, assign(socket, error: nil, repricing: length(Cards.stale_prices()))}

      {:error, _reason} ->
        {:noreply, assign(socket, error: "Não consegui enfileirar.")}
    end
  end

  # The repair for an answer that lost cards to a Scryfall outage. Nothing on
  # the deck page can tell that story: the suggestion just says "não achei essa
  # carta na Scryfall", and the audit and the optimizer quietly drop it from
  # every count they make. This asks again, for every consult still short.
  def handle_event("refetch-missing", _params, socket) do
    case CatalogueWorker.enqueue_all() do
      {:ok, queued} -> {:noreply, assign(socket, error: nil, refetching: queued)}
      {:error, _reason} -> {:noreply, assign(socket, error: "Não consegui enfileirar.")}
    end
  end

  def handle_event("save", %{"setting" => %{"key" => key, "value" => value}}, socket) do
    setting = String.to_existing_atom(key)

    {:noreply, save(socket, setting, cast(key, value), setting)}
  end

  def handle_event(
        "save-baseline",
        %{"baseline" => %{"field" => field, "value" => value}},
        socket
      ) do
    override = socket.assigns.values |> Map.fetch!(:baselines) |> Map.put(field, number(value))

    # Keyed by the baseline field, not by `:baselines` — one bad box must not
    # print its message under all nineteen of them.
    {:noreply, save(socket, :baselines, override, field)}
  end

  # One field's failure must not clear another field's message, and a field
  # that saves must clear its own — a stale error under a box the owner has
  # already fixed is worse than none.
  defp save(socket, key, value, shown_under) do
    case Settings.put(key, value) do
      {:ok, _value} ->
        socket
        |> load()
        |> assign(saved: shown_under, errors: Map.delete(socket.assigns.errors, shown_under))

      {:error, error} ->
        assign(socket, errors: Map.put(socket.assigns.errors, shown_under, error.message))
    end
  end

  # The form hands back strings; the registry says what the value must be.
  defp cast(key, value) do
    case Registry.fetch(String.to_existing_atom(key)) do
      {:ok, %{type: type}} when type in [:integer, :number] -> number(value)
      _string_or_unknown -> value
    end
  end

  defp number(value) do
    case Float.parse(value) do
      {number, ""} -> if number == Float.round(number), do: trunc(number), else: number
      _not_a_number -> value
    end
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div>
      <button
        type="button"
        phx-click="open"
        phx-target={@myself}
        aria-label="Abrir ajustes"
        title="Ajustes"
        class="fixed right-4 top-4 z-40 inline-flex size-touch items-center justify-center rounded-full border border-hairline-soft bg-surface text-ink-faint shadow-contact transition-colors hover:text-ink"
      >
        <.icon name="hero-cog-6-tooth" class="size-5" />
      </button>

      <div
        :if={@open}
        id={"#{@id}-overlay"}
        class="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-felt/70 p-4 backdrop-blur-sm sm:p-8"
        phx-click="close"
        phx-target={@myself}
        phx-window-keydown="close"
        phx-key="escape"
      >
        <%!-- The click-outside handler is on the backdrop; this stops a click
              inside the dialog from bubbling up and closing it. --%>
        <div
          role="dialog"
          aria-modal="true"
          aria-label="Ajustes"
          phx-click-away="close"
          class="w-full max-w-2xl rounded-xl border border-hairline-soft bg-surface shadow-lifted 2xl:max-w-5xl"
          onclick="event.stopPropagation()"
        >
          <header class="flex items-center justify-between gap-4 border-b border-hairline-soft px-6 py-4">
            <div>
              <h2 class="text-heading font-semibold text-ink">Ajustes</h2>
              <p class="text-caption text-ink-muted">Salva sozinho ao confirmar cada campo.</p>
            </div>

            <button
              type="button"
              phx-click="close"
              phx-target={@myself}
              aria-label="Fechar ajustes"
              class="inline-flex size-touch items-center justify-center rounded-md text-ink-faint transition-colors hover:text-ink"
            >
              <.icon name="hero-x-mark" class="size-5" />
            </button>
          </header>

          <div class="max-h-[70vh] space-y-6 overflow-y-auto px-6 py-5 2xl:max-h-[78vh]">
            <p :if={@error} class="rounded-md bg-inlay p-3 text-caption text-sev-critical">
              {@error}
            </p>

            <%!-- Four groups of two or three fields each: one column of them is
                  a dialog you scroll past the knob you came for. Past 2xl the
                  dialog is wide enough to stand them side by side, and every
                  setting is on screen at once — which is how you notice that
                  the ceiling and the model floor argue with each other. --%>
            <div class="space-y-6 2xl:grid 2xl:grid-cols-2 2xl:items-start 2xl:gap-x-10 2xl:gap-y-6 2xl:space-y-0">
              <section :for={{group, title} <- groups()} class="space-y-4">
                <h3 class="text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
                  {title}
                </h3>

                <.form
                  :for={entry <- Registry.group(group)}
                  :if={entry.type != :baselines}
                  for={%{}}
                  as={:setting}
                  id={"panel-#{entry.key}"}
                  phx-change="save"
                  phx-submit="save"
                  phx-target={@myself}
                  class="flex flex-wrap items-end gap-3"
                >
                  <input type="hidden" name="setting[key]" value={entry.key} />

                  <.field
                    id={"panel-field-#{entry.key}"}
                    name="setting[value]"
                    label={entry.label}
                    value={@values[entry.key]}
                    options={entry.options}
                    hint={entry.hint}
                    numeric={entry.type in [:integer, :number]}
                    error={@errors[entry.key]}
                    saved={@saved == entry.key}
                    class="flex-1"
                  />
                </.form>
              </section>
            </div>

            <section class="space-y-2 border-t border-hairline-soft pt-4">
              <h3 class="text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
                Game Changers
              </h3>
              <p class="text-micro text-ink-muted">
                A lista oficial muda algumas vezes por ano. O deckex a lê da Scryfall —
                nunca a guarda escrita.
              </p>
              <div class="flex items-center gap-3">
                <.button type="button" phx-click="refresh-game-changers" phx-target={@myself}>
                  Reler a lista
                </.button>
                <span :if={@refreshed} class="font-mono text-micro text-ink-faint">
                  {@refreshed} carta(s) do catálogo estão na lista
                </span>
              </div>
            </section>

            <section class="space-y-2 border-t border-hairline-soft pt-4">
              <h3 class="text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
                Preços do catálogo
              </h3>
              <p class="text-micro text-ink-muted">
                O preço de uma carta é o da edição mais barata, não o da edição que a busca
                por nome devolveu. Reprecificar custa uma consulta por carta e roda em
                segundo plano. Todo dia às 6h o app relê sozinho o que passou de {Cards.price_max_age_days()} dias.
              </p>
              <div class="flex flex-wrap items-center gap-3">
                <.button type="button" phx-click="reprice-stale" phx-target={@myself}>
                  Reler os vencidos ({length(Cards.stale_prices())})
                </.button>
                <.button type="button" phx-click="reprice-catalogue" phx-target={@myself}>
                  Reprecificar tudo
                </.button>
                <span :if={@repricing} class="font-mono text-micro text-ink-faint">
                  {@repricing} carta(s) na fila
                </span>
              </div>
            </section>

            <section class="space-y-2 border-t border-hairline-soft pt-4">
              <h3 class="text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
                Cartas que faltaram
              </h3>
              <p class="text-micro text-ink-muted">
                Quando a Scryfall falha no momento da resposta, a carta sugerida nunca chega
                ao catálogo e a linha passa a dizer "não achei essa carta na Scryfall" para
                sempre — o motor e o otimizador param de contá-la. Isto pergunta de novo,
                só para as consultas que ainda estão faltando carta.
              </p>
              <div class="flex flex-wrap items-center gap-3">
                <%!-- No count on the label: finding it means reading every
                      answer, and this panel opens from every page. The click
                      says how many, which is when the number is worth its
                      cost. --%>
                <.button type="button" phx-click="refetch-missing" phx-target={@myself}>
                  Buscar de novo
                </.button>
                <span :if={@refetching} class="font-mono text-micro text-ink-faint">
                  {@refetching} consulta(s) na fila
                </span>
              </div>
            </section>

            <details class="border-t border-hairline-soft pt-4">
              <summary class="-my-2 inline-flex min-h-touch cursor-pointer items-center py-2 text-caption text-ink-faint transition-colors hover:text-ink motion-reduce:transition-none">
                Baselines da análise ({length(baseline_fields(@baselines))} números)
              </summary>

              <p class="mt-3 text-micro text-ink-muted">
                Heurísticas de Commander de 99 cartas. São chutes calibrados, não leis —
                e agora dizem de quem são: <span class="text-ink-secondary">{Baselines.source()}</span>.
                Discorde à vontade; é para isso que os campos são editáveis.
              </p>

              <div class="mt-3 grid gap-3 sm:grid-cols-2 2xl:grid-cols-4">
                <.form
                  :for={{field, value} <- baseline_fields(@baselines)}
                  for={%{}}
                  as={:baseline}
                  id={"panel-baseline-#{field}"}
                  phx-change="save-baseline"
                  phx-submit="save-baseline"
                  phx-target={@myself}
                  class="flex items-end gap-2"
                >
                  <input type="hidden" name="baseline[field]" value={field} />

                  <.field
                    id={"panel-baseline-field-#{field}"}
                    name="baseline[value]"
                    label={field}
                    value={value}
                    numeric
                    error={@errors[to_string(field)]}
                    saved={@saved == to_string(field)}
                    class="flex-1"
                  />
                </.form>
              </div>
            </details>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp groups, do: @groups

  defp baseline_fields(%Baselines{} = baselines) do
    baselines |> Map.from_struct() |> Enum.sort_by(fn {field, _value} -> to_string(field) end)
  end
end
