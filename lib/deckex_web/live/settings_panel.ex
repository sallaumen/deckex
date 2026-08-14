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
     |> load()}
  end

  defp load(socket) do
    assign(socket,
      values: Settings.all(),
      baselines: Settings.baselines(),
      error: nil
    )
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

  def handle_event("save", %{"setting" => %{"key" => key, "value" => value}}, socket) do
    {:noreply, save(socket, String.to_existing_atom(key), cast(key, value))}
  end

  def handle_event(
        "save-baseline",
        %{"baseline" => %{"field" => field, "value" => value}},
        socket
      ) do
    override = socket.assigns.values |> Map.fetch!(:baselines) |> Map.put(field, number(value))

    {:noreply, save(socket, :baselines, override)}
  end

  defp save(socket, key, value) do
    case Settings.put(key, value) do
      {:ok, _value} -> load(socket)
      {:error, error} -> assign(socket, error: error.message)
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
        class="fixed right-4 top-4 z-40 inline-flex size-11 items-center justify-center rounded-full border border-hairline-soft bg-surface text-ink-faint shadow-contact transition-colors hover:text-ink"
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
          class="w-full max-w-2xl rounded-xl border border-hairline-soft bg-surface shadow-lifted"
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
              class="inline-flex size-11 items-center justify-center rounded-md text-ink-faint transition-colors hover:text-ink"
            >
              <.icon name="hero-x-mark" class="size-5" />
            </button>
          </header>

          <div class="max-h-[70vh] space-y-6 overflow-y-auto px-6 py-5">
            <p :if={@error} class="rounded-md bg-inlay p-3 text-caption text-sev-critical">
              {@error}
            </p>

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
                phx-submit="save"
                phx-target={@myself}
                class="flex flex-wrap items-end gap-3"
              >
                <input type="hidden" name="setting[key]" value={entry.key} />

                <div class="min-w-0 flex-1">
                  <label
                    for={"panel-field-#{entry.key}"}
                    class="mb-1 block text-caption font-semibold text-ink-secondary"
                  >
                    {entry.label}
                  </label>

                  <select
                    :if={entry.options}
                    id={"panel-field-#{entry.key}"}
                    name="setting[value]"
                    class="min-h-11 w-full rounded-md border border-hairline-soft bg-inlay px-3 py-2 text-body text-ink"
                  >
                    <option
                      :for={option <- entry.options}
                      value={option}
                      selected={to_string(@values[entry.key]) == to_string(option)}
                    >
                      {option}
                    </option>
                  </select>

                  <input
                    :if={is_nil(entry.options)}
                    id={"panel-field-#{entry.key}"}
                    type="text"
                    inputmode={if entry.type in [:integer, :number], do: "decimal"}
                    name="setting[value]"
                    value={@values[entry.key]}
                    class="min-h-11 w-full rounded-md border border-hairline-soft bg-inlay px-3 py-2 font-mono text-body-lg text-ink"
                  />

                  <p :if={entry.hint} class="mt-1 text-micro text-ink-muted">{entry.hint}</p>
                </div>

                <.button type="submit">Salvar</.button>
              </.form>
            </section>

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

            <details class="border-t border-hairline-soft pt-4">
              <summary class="cursor-pointer text-caption text-ink-faint hover:text-ink">
                Baselines da análise ({length(baseline_fields(@baselines))} números)
              </summary>

              <p class="mt-3 text-micro text-ink-muted">
                Heurísticas de Commander de 99 cartas. São chutes calibrados, não leis.
              </p>

              <div class="mt-3 grid gap-3 sm:grid-cols-2">
                <.form
                  :for={{field, value} <- baseline_fields(@baselines)}
                  for={%{}}
                  as={:baseline}
                  id={"panel-baseline-#{field}"}
                  phx-submit="save-baseline"
                  phx-target={@myself}
                  class="flex items-end gap-2"
                >
                  <input type="hidden" name="baseline[field]" value={field} />

                  <div class="min-w-0 flex-1">
                    <label
                      for={"panel-baseline-field-#{field}"}
                      class="mb-1 block font-mono text-micro text-ink-faint"
                    >
                      {field}
                    </label>
                    <input
                      id={"panel-baseline-field-#{field}"}
                      type="text"
                      inputmode="decimal"
                      name="baseline[value]"
                      value={value}
                      class="min-h-11 w-full rounded-md border border-hairline-soft bg-inlay px-2 py-2 font-mono text-caption text-ink"
                    />
                  </div>

                  <.button type="submit">ok</.button>
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
