defmodule DeckexWeb.OptimizationsLive do
  @moduledoc """
  One deck's optimization history, and the launcher.

  The launch modal is the moment of consent: it shows the recipe, the
  contract, and the honest price of the button — N stages, one consult of
  2–5 minutes each — before anything spends. One click authorizes the whole
  declared batch; the sandbox keeps the real deck out of reach.
  """
  use DeckexWeb, :live_view

  alias Deckex.Consults
  alias Deckex.Decks
  alias Deckex.Error
  alias Deckex.Optimizations

  @impl Phoenix.LiveView
  def mount(%{"id" => deck_id}, _session, socket) do
    case Decks.fetch_deck(deck_id) do
      {:ok, deck} ->
        {:ok,
         assign(socket,
           deck: deck,
           runs: Optimizations.list_for_deck(deck.id),
           contract: Optimizations.default_contract(deck),
           recipe: Optimizations.recipe(deck),
           launching: false,
           page_title: "Otimizações · #{deck.name}"
         )}

      {:error, %Error{} = error} ->
        {:ok, socket |> put_flash(:error, error.message) |> push_navigate(to: ~p"/")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("abrir-lancador", _params, socket) do
    {:noreply, assign(socket, launching: true)}
  end

  def handle_event("fechar-lancador", _params, socket) do
    {:noreply, assign(socket, launching: false)}
  end

  def handle_event("comecar", %{"contract" => params}, socket) do
    contract = %{
      "bracket_max" => String.to_integer(params["bracket_max"]),
      "ceilings" => %{
        "card" => parse_int(params["ceiling_card"]),
        "land" => parse_int(params["ceiling_land"])
      },
      "keep" => lines(params["keep"]),
      "matchups" => lines(params["matchups"]),
      "notes" => String.trim(params["notes"] || ""),
      "model" => params["model"]
    }

    case Optimizations.start(socket.assigns.deck, contract) do
      {:ok, optimization} ->
        {:noreply, push_navigate(socket, to: ~p"/otimizacoes/#{optimization.id}")}

      {:error, %Error{} = error} ->
        {:noreply, socket |> assign(launching: false) |> put_flash(:error, error.message)}
    end
  end

  defp parse_int(value) do
    case Integer.parse(value || "") do
      {int, _rest} when int > 0 -> int
      _zero_or_junk -> nil
    end
  end

  defp lines(nil), do: []

  defp lines(text) do
    text |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp status_label(:running), do: "rodando"
  defp status_label(:paused), do: "pausada"
  defp status_label(:done), do: "concluída"
  defp status_label(:failed), do: "falhou"
  defp status_label(:cancelled), do: "cancelada"

  defp done_count(run), do: Enum.count(run.steps, &(&1.status in [:done, :skipped]))

  defp current_stage(run), do: Enum.find(run.steps, &(&1.status == :running))

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-[1100px] px-6 py-10 lg:px-10 lg:py-14">
      <.live_component module={DeckexWeb.SettingsPanel} id="settings-panel" />

      <.link
        navigate={~p"/decks/#{@deck.id}"}
        class="-my-2 inline-flex min-h-11 items-center py-2 text-caption text-ink-faint transition-colors hover:text-ink"
      >
        ← {@deck.name}
      </.link>

      <header class="mt-3 mb-10 flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 class="text-display font-semibold text-ink">Otimizações</h1>
          <p class="mt-1 text-body text-ink-muted">
            O pipeline mexe numa cópia. O deck de verdade só muda quando você salvar.
          </p>
        </div>

        <.button type="button" phx-click="abrir-lancador" variant="primary">
          Nova otimização
        </.button>
      </header>

      <div
        :if={@runs == []}
        class="rounded-xl border border-hairline-soft bg-surface p-10 text-center"
      >
        <p class="text-body text-ink-secondary">Nenhuma otimização ainda.</p>
        <p class="mt-1 text-caption text-ink-faint">
          {length(@recipe)} etapas de IA, cada uma auditada pelo motor, numa cópia do deck.
        </p>
      </div>

      <ul class="space-y-4">
        <li :for={run <- @runs}>
          <.link
            navigate={~p"/otimizacoes/#{run.id}"}
            class="block rounded-xl border border-hairline-soft bg-surface p-5 transition-colors hover:border-hairline-strong"
          >
            <div class="flex flex-wrap items-center justify-between gap-3">
              <span class="font-mono text-caption text-ink">
                {Calendar.strftime(run.inserted_at, "%d/%m %H:%M")}
              </span>
              <span class={[
                "font-mono text-caption",
                run.status == :done && "text-sev-healthy",
                run.status in [:failed, :cancelled] && "text-sev-critical",
                run.status in [:running, :paused] && "text-sev-warning"
              ]}>
                {status_label(run.status)}{if run.outcome, do: " · #{run.outcome}"}
              </span>
            </div>
            <p class="mt-2 text-caption text-ink-muted">
              {done_count(run)}/{length(run.steps)} etapas · {Enum.sum(
                Enum.map(run.steps, &length(&1.applied))
              )} mudanças aplicadas{if stage = current_stage(run),
                do: " · agora: #{stage.label}"}
            </p>
          </.link>
        </li>
      </ul>

      <div
        :if={@launching}
        class="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-felt/70 p-4 backdrop-blur-sm sm:p-8"
        phx-window-keydown="fechar-lancador"
        phx-key="escape"
      >
        <div
          role="dialog"
          aria-modal="true"
          aria-label="Nova otimização"
          class="w-full max-w-2xl rounded-xl border border-hairline-soft bg-surface shadow-lifted"
        >
          <header class="border-b border-hairline-soft px-6 py-4">
            <h2 class="text-heading font-semibold text-ink">Nova otimização</h2>
            <p class="text-caption text-ink-muted">
              {length(@recipe)} etapas, uma consulta de 2–5 min cada. O pipeline aplica só o que o
              motor aprovar — e só na cópia.
            </p>
          </header>

          <.form
            for={%{}}
            as={:contract}
            id="launch-form"
            phx-submit="comecar"
            class="space-y-4 px-6 py-5"
          >
            <div class="grid gap-4 sm:grid-cols-3">
              <div>
                <label
                  for="launch-bracket"
                  class="mb-1 block text-caption font-semibold text-ink-secondary"
                >
                  Bracket máximo
                </label>
                <select
                  id="launch-bracket"
                  name="contract[bracket_max]"
                  class="min-h-11 w-full rounded-md border border-hairline-soft bg-inlay px-2 py-2 text-caption text-ink"
                >
                  <option
                    :for={bracket <- [1, 2, 3, 4]}
                    value={bracket}
                    selected={bracket == @contract["bracket_max"]}
                  >
                    {bracket}
                  </option>
                </select>
                <p class="mt-1 text-micro text-ink-muted">O piso medido hoje é o padrão.</p>
              </div>

              <div>
                <label
                  for="launch-ceiling-card"
                  class="mb-1 block text-caption font-semibold text-ink-secondary"
                >
                  Teto por carta (R$)
                </label>
                <input
                  id="launch-ceiling-card"
                  type="text"
                  inputmode="numeric"
                  name="contract[ceiling_card]"
                  value={@contract["ceilings"]["card"]}
                  class="min-h-11 w-full rounded-md border border-hairline-soft bg-inlay px-2 py-2 font-mono text-caption text-ink"
                />
              </div>

              <div>
                <label
                  for="launch-ceiling-land"
                  class="mb-1 block text-caption font-semibold text-ink-secondary"
                >
                  Teto por terreno (R$)
                </label>
                <input
                  id="launch-ceiling-land"
                  type="text"
                  inputmode="numeric"
                  name="contract[ceiling_land]"
                  value={@contract["ceilings"]["land"]}
                  class="min-h-11 w-full rounded-md border border-hairline-soft bg-inlay px-2 py-2 font-mono text-caption text-ink"
                />
              </div>
            </div>

            <div>
              <label
                for="launch-keep"
                class="mb-1 block text-caption font-semibold text-ink-secondary"
              >
                Cartas protegidas (uma por linha)
              </label>
              <textarea
                id="launch-keep"
                name="contract[keep]"
                rows="2"
                placeholder={keep_placeholder()}
                class="w-full rounded-md border border-hairline-soft bg-inlay px-3 py-2 font-mono text-caption text-ink placeholder:text-ink-faint"
              ></textarea>
              <p class="mt-1 text-micro text-ink-muted">
                O pipeline nunca corta essas. O comandante já é protegido.
              </p>
            </div>

            <div>
              <label
                for="launch-matchups"
                class="mb-1 block text-caption font-semibold text-ink-secondary"
              >
                Matchups para testar (um por linha)
              </label>
              <textarea
                id="launch-matchups"
                name="contract[matchups]"
                rows="2"
                class="w-full rounded-md border border-hairline-soft bg-inlay px-3 py-2 text-caption text-ink"
              >{Enum.join(@contract["matchups"], "\n")}</textarea>
            </div>

            <div class="grid gap-4 sm:grid-cols-[1fr_10rem]">
              <div>
                <label
                  for="launch-notes"
                  class="mb-1 block text-caption font-semibold text-ink-secondary"
                >
                  Notas para todas as etapas
                </label>
                <input
                  id="launch-notes"
                  type="text"
                  name="contract[notes]"
                  placeholder="ex.: mantenha o tema de lontras"
                  class="min-h-11 w-full rounded-md border border-hairline-soft bg-inlay px-3 py-2 text-caption text-ink placeholder:text-ink-faint"
                />
              </div>

              <div>
                <label
                  for="launch-model"
                  class="mb-1 block text-caption font-semibold text-ink-secondary"
                >
                  Modelo
                </label>
                <select
                  id="launch-model"
                  name="contract[model]"
                  class="min-h-11 w-full rounded-md border border-hairline-soft bg-inlay px-2 py-2 font-mono text-caption text-ink"
                >
                  <option
                    :for={model <- Consults.models()}
                    value={model}
                    selected={model == @contract["model"]}
                  >
                    {model}
                  </option>
                </select>
              </div>
            </div>

            <div class="flex items-center justify-end gap-3 border-t border-hairline-soft pt-4">
              <button
                type="button"
                phx-click="fechar-lancador"
                class="-my-2 inline-flex min-h-11 items-center px-1 py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
              >
                Cancelar
              </button>
              <.button type="submit" variant="primary" phx-disable-with="Começando…">
                Começar as {length(@recipe)} etapas
              </.button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  # A function, not an inline string: the formatter mangles multi-line
  # attribute literals (the placeholder law from the import screen).
  defp keep_placeholder, do: "Sol Ring"
end
