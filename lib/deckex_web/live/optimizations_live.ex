defmodule DeckexWeb.OptimizationsLive do
  @moduledoc """
  One deck's optimization history, and the launcher.

  The launch modal is the moment of consent: it shows the recipe, the
  contract, and the honest price of the button — N stages, one consult of
  2–5 minutes each — before anything spends. One click authorizes the whole
  declared batch; the sandbox keeps the real deck out of reach.
  """
  use DeckexWeb, :live_view

  alias Deckex.Analysis
  alias Deckex.Analysis.Report
  alias Deckex.Consults
  alias Deckex.Decks
  alias Deckex.Decks.DeckVersion
  alias Deckex.Decks.Versions
  alias Deckex.Error
  alias Deckex.Events
  alias Deckex.Optimizations
  alias Deckex.Optimizations.Salt
  alias Deckex.Settings
  alias DeckexWeb.Clock

  @impl Phoenix.LiveView
  def mount(%{"id" => deck_id}, _session, socket) do
    case Decks.fetch_deck(deck_id) do
      {:ok, deck} ->
        runs = Optimizations.list_for_deck(deck.id)

        if connected?(socket), do: subscribe_to_live_runs(runs)

        {:ok,
         assign(socket,
           deck: deck,
           runs: runs,
           applied: Versions.applied_runs(deck),
           versions: Versions.list(deck),
           drifted?: Versions.drifted?(deck),
           deck_size: deck_size(deck),
           contract: Optimizations.default_contract(deck),
           recipe: Optimizations.recipe(deck, :refine),
           mode: :refine,
           salt: Salt.preset("sem_freio"),
           launching: false,
           page_title: "Otimizações · #{deck.name}"
         )}

      {:error, %Error{} = error} ->
        {:ok, socket |> put_flash(:error, error.message) |> push_navigate(to: ~p"/")}
    end
  end

  # Commanders included: 100 is the number the rule is about, and the picker
  # sits next to versions that count themselves the same way.
  defp deck_size(deck) do
    deck
    |> Decks.snapshot()
    |> Analysis.report(Settings.baselines())
    |> Map.fetch!(:legality)
    |> Map.fetch!(:size)
  end

  # Computed, not stored: reports are arithmetic over ~100 structs and the app
  # never caches one. A run that changed nothing yet has nothing to say, so it
  # says nothing rather than printing "0→0" as if that were a result.
  defp criticals_delta(run, deck) do
    changed = Enum.any?(run.steps, &(&1.applied != []))

    if changed do
      commanders = Optimizations.current_commanders(run)
      baselines = Settings.baselines()

      before = report_for(run.list_original, commanders, deck, baselines)
      now = report_for(Optimizations.current_list(run), commanders, deck, baselines)

      {before, now}
    end
  end

  defp report_for(list, commanders, deck, baselines) do
    list
    |> Optimizations.snapshot_for(commanders, deck)
    |> Analysis.report(baselines)
    |> Report.critical_count()
  end

  defp delta_tone({before, now}) when now < before, do: "text-sev-healthy"
  defp delta_tone({before, now}) when now > before, do: "text-sev-critical"
  defp delta_tone(_unchanged), do: "text-ink-faint"

  @impl Phoenix.LiveView
  def handle_info({:optimization_updated, _id}, socket) do
    {:noreply,
     assign(socket,
       runs: Optimizations.list_for_deck(socket.assigns.deck.id),
       applied: Versions.applied_runs(socket.assigns.deck)
     )}
  end

  @impl Phoenix.LiveView
  def handle_event("abrir-lancador", _params, socket) do
    {:noreply, assign(socket, launching: true)}
  end

  def handle_event("fechar-lancador", _params, socket) do
    {:noreply, assign(socket, launching: false)}
  end

  def handle_event("modo", %{"modo" => modo}, socket) do
    mode = String.to_existing_atom(modo)

    {:noreply,
     assign(socket, mode: mode, recipe: Optimizations.recipe(socket.assigns.deck, mode))}
  end

  def handle_event("preset-salt", %{"preset" => preset}, socket) do
    {:noreply, assign(socket, salt: Salt.preset(preset))}
  end

  def handle_event("salt", %{"tatica" => key, "valor" => value}, socket) do
    {:noreply, assign(socket, salt: Map.put(socket.assigns.salt, key, value))}
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
      "model" => params["model"],
      "salt" => salt_for(socket),
      "from_version" => parse_int(params["from_version"])
    }

    # Refused here rather than mid-run: every add the contract contradicts
    # would be rejected by the bracket guard anyway, one paid consult at a time.
    case Salt.contradiction(contract) do
      nil -> launch(socket, Map.put(contract, "mode", socket.assigns.mode))
      reason -> {:noreply, put_flash(socket, :error, reason)}
    end
  end

  defp salt_for(%{assigns: %{mode: :reimagine, salt: salt}}), do: salt
  defp salt_for(_refine), do: %{}

  defp launch(socket, contract) do
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
  defp status_label(:awaiting_choice), do: "esperando escolha"
  defp status_label(:paused), do: "pausada"
  defp status_label(:done), do: "concluída"
  defp status_label(:failed), do: "falhou"
  defp status_label(:cancelled), do: "cancelada"

  # Mount-only, the duplicate-subscription law. Runs born after this mount
  # are the owner's own launches — those navigate away anyway.
  defp subscribe_to_live_runs(runs) do
    runs
    |> Enum.filter(&(&1.status in [:running, :paused]))
    |> Enum.each(&Events.subscribe_optimization(&1.id))
  end

  defp done_count(run), do: Enum.count(run.steps, &(&1.status in [:done, :skipped]))

  defp current_stage(run), do: Enum.find(run.steps, &(&1.status == :running))

  defp mode_label(:reimagine), do: "reimaginar"
  defp mode_label(_refine), do: "refinar"

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-[1100px] px-6 py-10 lg:px-10 lg:py-14">
      <%!-- Inside the LiveView's own tree, not the root layout: the layout is
            static after mount, so a flash put during an event would never
            reach the screen from there. --%>
      <DeckexWeb.Layouts.flash_group flash={@flash} />
      <.live_component module={DeckexWeb.SettingsPanel} id="settings-panel" />

      <.link
        navigate={~p"/decks/#{@deck.id}"}
        class="-my-2 inline-flex min-h-touch items-center py-2 text-caption text-ink-faint transition-colors hover:text-ink"
      >
        ← {@deck.name}
      </.link>

      <header class="mt-3 mb-10 flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 class="text-display font-semibold text-ink">Otimizações</h1>
          <p class="mt-1 text-body text-ink-muted">
            O pipeline mexe numa cópia. O deck de verdade só muda quando você aplicar.
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
              <span class="flex items-center gap-2">
                <span class="font-mono text-caption text-ink">
                  {Clock.moment(run.inserted_at)}
                </span>
                <span class="rounded-md border border-hairline-soft px-2 py-0.5 font-mono text-micro text-ink-faint">
                  {mode_label(run.mode)}
                </span>
                <span :if={run.contract["visao"]} class="text-caption text-ink-secondary">
                  {run.contract["visao"]["nome"]}
                </span>
              </span>
              <%!-- Without this the history cannot answer the one question it
                    is opened with: which of these did I already put in the
                    deck? Applying the same run twice is a real click away. --%>
              <span
                :if={version = @applied[run.id]}
                class="rounded-full bg-inlay px-2 py-0.5 font-mono text-micro text-ink-secondary"
              >
                aplicada · v{version.number}
              </span>
              <span class={[
                "font-mono text-caption",
                run.status == :done && "text-sev-healthy",
                run.status in [:failed, :cancelled] && "text-sev-critical",
                run.status in [:running, :awaiting_choice, :paused] && "text-sev-warning"
              ]}>
                {status_label(run.status)}{if run.outcome, do: " · #{run.outcome}"}
              </span>
            </div>
            <p class="mt-2 flex flex-wrap items-center gap-x-2 text-caption text-ink-muted">
              <span>
                {done_count(run)}/{length(run.steps)} etapas · {Enum.sum(
                  Enum.map(run.steps, &length(&1.applied))
                )} mudanças aplicadas{if stage = current_stage(run),
                  do: " · agora: #{stage.label}"}
              </span>

              <%!-- The two facts that separate a run worth reading from one
                    worth ignoring, and neither was on the row: which model
                    answered, and whether the criticals actually moved. Without
                    them the history is a list of timestamps. --%>
              <span aria-hidden="true">·</span>
              <span class="font-mono text-ink-faint">{run.contract["model"]}</span>

              <span :if={delta = criticals_delta(run, @deck)}>
                <span aria-hidden="true" class="text-ink-faint">·</span>
                <span class={["font-mono", delta_tone(delta)]}>
                  críticos {elem(delta, 0)}→{elem(delta, 1)}
                </span>
              </span>
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
            <%!-- The total, not just the per-stage cost: ten stages at "2–5
                  min cada" is half an hour of the afternoon, and that is the
                  number someone decides with. --%>
            <p class="text-caption text-ink-muted">
              {length(@recipe)} etapas · {length(@recipe) * 2}–{length(@recipe) * 5} min no total,
              rodando sozinho. O pipeline aplica só o que o motor aprovar — e só na cópia.
            </p>
          </header>

          <.form
            for={%{}}
            as={:contract}
            id="launch-form"
            phx-submit="comecar"
            class="space-y-4 px-6 py-5"
          >
            <div class="flex gap-2">
              <button
                :for={{mode, label} <- [{:refine, "Refinar"}, {:reimagine, "Reimaginar"}]}
                type="button"
                phx-click="modo"
                phx-value-modo={mode}
                class={[
                  "min-h-touch flex-1 rounded-md border px-3 py-2 text-caption transition-colors",
                  @mode == mode && "border-hairline-strong bg-inlay text-ink",
                  @mode != mode && "border-hairline-soft text-ink-faint hover:text-ink"
                ]}
              >
                {label}
              </button>
            </div>

            <p class="text-micro text-ink-muted">
              {if @mode == :refine,
                do: "Melhora o deck dentro do plano que ele já tem.",
                else:
                  "A IA propõe três direções novas, você escolhe uma, e o pipeline reconstrói o deck em cima dela."}
            </p>

            <div :if={@mode == :reimagine} class="space-y-2 border-t border-hairline-soft pt-4">
              <div class="flex flex-wrap items-center justify-between gap-2">
                <span class="text-caption font-semibold text-ink-secondary">
                  O que você não quer na mesa
                </span>
                <div class="flex gap-2">
                  <button
                    :for={
                      {preset, label} <- [
                        {"mesa_tranquila", "mesa tranquila"},
                        {"sem_freio", "sem freio"}
                      ]
                    }
                    type="button"
                    phx-click="preset-salt"
                    phx-value-preset={preset}
                    class="-my-2 inline-flex min-h-touch items-center px-1 py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
                  >
                    {label}
                  </button>
                </div>
              </div>

              <div
                :for={tactic <- Salt.tactics()}
                class="flex flex-wrap items-center justify-between gap-2"
              >
                <span class="text-caption text-ink-secondary">{tactic.label}</span>
                <div class="flex gap-1">
                  <button
                    :for={
                      {value, label} <- [
                        {"evitar", "evitar"},
                        {"tanto_faz", "tanto faz"},
                        {"quero", "quero"}
                      ]
                    }
                    type="button"
                    phx-click="salt"
                    phx-value-tatica={tactic.key}
                    phx-value-valor={value}
                    class={[
                      "inline-flex min-h-touch items-center rounded-md border px-2 text-micro transition-colors",
                      Map.get(@salt, tactic.key, "tanto_faz") == value &&
                        "border-hairline-strong bg-inlay text-ink",
                      Map.get(@salt, tactic.key, "tanto_faz") != value &&
                        "border-hairline-soft text-ink-faint hover:text-ink"
                    ]}
                  >
                    {label}
                  </button>
                </div>
              </div>

              <p class="text-micro text-ink-muted">
                O motor recusa entradas que violem o que você marcou como evitar. "Quero" é convite —
                nenhum motor obriga um modelo a ter ideia.
              </p>
            </div>

            <%!-- A run is an argument about a list, so which list it argues
                  about is the first thing to decide — and the answer is almost
                  always "a mais nova", which is why it is already chosen. --%>
            <div :if={@versions != []}>
              <label
                for="launch-from"
                class="mb-1 block text-caption font-semibold text-ink-secondary"
              >
                A partir de qual versão
              </label>
              <select
                id="launch-from"
                name="contract[from_version]"
                class="min-h-touch w-full rounded-md border border-hairline-soft bg-inlay px-2 py-2 text-caption text-ink"
              >
                <option :if={@drifted?} value="" selected>
                  Como está agora — {@deck_size} cartas, com mudanças não marcadas
                </option>
                <option
                  :for={{version, index} <- Enum.with_index(@versions)}
                  value={version.number}
                  selected={not @drifted? and index == 0}
                >
                  v{version.number} · {DeckVersion.size(version)} cartas{if version.label,
                    do: " · #{version.label}"}{if index == 0, do: " · mais recente"}
                </option>
              </select>
              <p class="mt-1 text-micro text-ink-muted">
                {if @drifted?,
                  do:
                    "O deck mudou desde a última versão, então a lista de agora é a mais nova — é ela que vai ser otimizada.",
                  else: "O pipeline copia essa lista e mexe só na cópia."}
              </p>
            </div>

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
                  class="min-h-touch w-full rounded-md border border-hairline-soft bg-inlay px-2 py-2 text-caption text-ink"
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
                  class="min-h-touch w-full rounded-md border border-hairline-soft bg-inlay px-2 py-2 font-mono text-caption text-ink"
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
                  class="min-h-touch w-full rounded-md border border-hairline-soft bg-inlay px-2 py-2 font-mono text-caption text-ink"
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
                  class="min-h-touch w-full rounded-md border border-hairline-soft bg-inlay px-3 py-2 text-caption text-ink placeholder:text-ink-faint"
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
                  class="min-h-touch w-full rounded-md border border-hairline-soft bg-inlay px-2 py-2 font-mono text-caption text-ink"
                >
                  <option
                    :for={model <- Consults.models_at_or_above(Settings.model_floor())}
                    value={model}
                    selected={model == @contract["model"]}
                  >
                    {model}
                  </option>
                </select>
                <%!-- The floor filters this list, and when it filtered it down
                      to one nothing on screen said why — the picker just looked
                      like the app only had one model. Now it names the rule and
                      where to change it. --%>
                <p class="mt-1 text-micro text-ink-muted">
                  Piso: <span class="font-mono">{Settings.model_floor()}</span>. Modelos abaixo dele
                  não podem propor mudança de carta — muda nos Ajustes.
                </p>
              </div>
            </div>

            <div class="flex items-center justify-end gap-3 border-t border-hairline-soft pt-4">
              <button
                type="button"
                phx-click="fechar-lancador"
                class="-my-2 inline-flex min-h-touch items-center px-1 py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
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
