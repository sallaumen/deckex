defmodule DeckexWeb.SettingsLive do
  @moduledoc """
  Ajustes: the knobs, with their reasons.

  Each setting shows its hint, because most of these are only meaningful with
  context — "User-Agent do Moxfield" means nothing until you know that pasting
  an approved one is what turns URL sync from a 403 into a feature.
  """
  use DeckexWeb, :live_view

  alias Deckex.Analysis.Baselines
  alias Deckex.Settings
  alias Deckex.Settings.Registry

  @groups [{:ai, "Inteligência artificial"}, {:moxfield, "Moxfield"}, {:analysis, "Baselines"}]

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Ajustes", error: nil) |> load()}
  end

  defp load(socket) do
    assign(socket, values: Settings.all(), baselines: Settings.baselines())
  end

  @impl Phoenix.LiveView
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
      {:ok, _value} -> socket |> assign(error: nil) |> load() |> put_flash(:info, "Salvo.")
      {:error, error} -> assign(socket, error: error.message)
    end
  end

  # The form gives us strings; the registry says what the value must be.
  defp cast("consult_budget_usd", value), do: number(value)
  defp cast("usd_to_brl", value), do: number(value)
  defp cast(_key, value), do: value

  defp number(value) do
    case Float.parse(value) do
      {number, ""} -> if number == Float.round(number), do: trunc(number), else: number
      _not_a_number -> value
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-[1100px] px-6 py-10 lg:px-10 lg:py-14">
      <.link navigate={~p"/"} class="text-caption text-ink-faint transition-colors hover:text-ink">
        ← A Mesa
      </.link>

      <header class="mt-3 mb-10">
        <h1 class="text-display font-semibold text-ink">Ajustes</h1>
        <p class="mt-1 text-body text-ink-muted">
          Os números da análise são heurísticas, não leis. Mexa à vontade.
        </p>
      </header>

      <p
        :if={@error}
        class="mb-8 rounded-lg border bg-surface p-4 text-body text-ink"
        style={"border-color:color-mix(in srgb, #{Format.severity_var(:critical)} 30%, transparent)"}
      >
        {@error}
      </p>

      <div class="space-y-8">
        <section
          :for={{group, title} <- groups()}
          class="rounded-xl border border-hairline-soft bg-surface p-6"
        >
          <h2 class="mb-5 text-heading font-semibold text-ink">{title}</h2>

          <div class="space-y-6">
            <.form
              :for={entry <- Registry.group(group)}
              :if={entry.type != :baselines}
              for={%{}}
              as={:setting}
              id={"form-#{entry.key}"}
              phx-submit="save"
              class="flex flex-wrap items-end gap-3"
            >
              <input type="hidden" name="setting[key]" value={entry.key} />

              <div class="min-w-0 flex-1">
                <label
                  for={"setting-#{entry.key}"}
                  class="mb-1.5 block text-label font-semibold uppercase tracking-[0.1em] text-ink-faint"
                >
                  {entry.label}
                </label>

                <select
                  :if={entry.options}
                  id={"setting-#{entry.key}"}
                  name="setting[value]"
                  class="w-full rounded-md border border-hairline-soft bg-inlay px-3 py-2 text-body text-ink"
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
                  id={"setting-#{entry.key}"}
                  type="text"
                  name="setting[value]"
                  value={@values[entry.key]}
                  class="w-full rounded-md border border-hairline-soft bg-inlay px-3 py-2 font-mono text-caption text-ink"
                />

                <p :if={entry.hint} class="mt-1.5 text-caption text-ink-muted">{entry.hint}</p>
              </div>

              <.button type="submit">Salvar</.button>
            </.form>

            <div :if={group == :analysis}>
              <p class="mb-4 text-caption text-ink-muted">
                Heurísticas de Commander de 99 cartas.
              </p>

              <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
                <.form
                  :for={{field, value} <- baseline_fields(@baselines)}
                  for={%{}}
                  as={:baseline}
                  id={"form-baseline-#{field}"}
                  phx-submit="save-baseline"
                  class="flex items-end gap-2"
                >
                  <input type="hidden" name="baseline[field]" value={field} />

                  <div class="min-w-0 flex-1">
                    <label
                      for={"baseline-#{field}"}
                      class="mb-1 block font-mono text-micro text-ink-faint"
                    >
                      {field}
                    </label>
                    <input
                      id={"baseline-#{field}"}
                      type="text"
                      name="baseline[value]"
                      value={value}
                      class="w-full rounded-md border border-hairline-soft bg-inlay px-2 py-1 font-mono text-caption text-ink"
                    />
                  </div>

                  <.button type="submit">ok</.button>
                </.form>
              </div>
            </div>
          </div>
        </section>
      </div>
    </div>
    """
  end

  defp groups, do: @groups

  defp baseline_fields(%Baselines{} = baselines) do
    baselines |> Map.from_struct() |> Enum.sort_by(fn {field, _value} -> to_string(field) end)
  end
end
