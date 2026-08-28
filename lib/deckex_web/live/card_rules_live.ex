defmodule DeckexWeb.CardRulesLive do
  @moduledoc """
  What the owner has decided about individual cards in one deck.

  This screen exists because of one afternoon. A stage read Sam, Loyal
  Attendant on her own, found her unremarkable, and cut her — and in his list
  she is half of an infinite combo with Prize Pig, which makes Food free to
  use. He noticed, because he was watching. Nothing in the app would have.

  The launch modal already had a "cartas protegidas" box, and that is exactly
  the wrong place for this: it is empty every time, so protecting a card means
  remembering it under pressure, and a combo piece is precisely the card you
  forget. What he decides here holds for **every** round of this deck, until he
  changes it.

  Three stances, and the ordering on the page is by how much they bind:
  obrigatória is enforced by the audit, pedida is carried into every briefing
  as his request, observação is the knowledge that stops a stage misreading a
  card twice.
  """
  use DeckexWeb, :live_view

  alias Deckex.Cards.Card
  alias Deckex.Cards.Name
  alias Deckex.Consults
  alias Deckex.Consults.Consult
  alias Deckex.Decks
  alias Deckex.Decks.CardNote
  alias Deckex.Decks.CardRules
  alias Deckex.Error
  alias Deckex.Events
  alias DeckexWeb.Clock

  @impl Phoenix.LiveView
  def mount(%{"id" => deck_id}, _session, socket) do
    case Decks.fetch_deck(deck_id) do
      {:ok, deck} ->
        if connected?(socket), do: Events.subscribe_consults(deck.id)

        {:ok,
         socket
         |> assign(
           stance: :locked,
           # The answer that cost money outlives the page: a `:pilares` consult
           # asked yesterday is still the sharpest thing this screen knows.
           consult: Consults.latest_for_lens(deck.id, :pilares),
           swept?: false,
           checked: MapSet.new()
         )
         |> load(deck)}

      {:error, %Error{} = error} ->
        {:ok, socket |> put_flash(:error, error.message) |> push_navigate(to: ~p"/")}
    end
  end

  defp load(socket, deck) do
    rules = Decks.card_notes(deck)
    present = card_names(deck)

    socket
    |> assign(
      deck: deck,
      groups: CardRules.split(rules),
      # Computed once for the whole page rather than per row: the answer is the
      # same for every row and the deck is ~100 cards.
      missing: CardRules.missing_from(Enum.map(rules, & &1.card_name), present),
      present: MapSet.new(present, &Name.normalize/1),
      locked_share: locked_share(deck, rules),
      page_title: "Cartas · #{deck.name}"
    )
    |> propose()
  end

  # Recomputed whenever the rules change, because locking a proposal has to make
  # it leave the list — otherwise the screen keeps offering him what he just did.
  defp propose(socket) do
    proposals =
      if socket.assigns.swept? or answered?(socket.assigns.consult) do
        Decks.pillar_proposals(socket.assigns.deck, pillar_rows(socket.assigns.consult))
      else
        []
      end

    assign(socket,
      proposals: proposals,
      # Everything ticked on arrival: he asked for the obvious ones, and
      # unticking the two he disagrees with is less work than ticking eight.
      checked: MapSet.new(proposals, & &1.name)
    )
  end

  defp answered?(%Consult{status: :done, response: %{}}), do: true
  defp answered?(_pending_or_absent), do: false

  defp asking?(%Consult{status: status}), do: status in [:pending, :running]
  defp asking?(_nothing_in_flight), do: false

  defp answered_at(%Consult{status: :done, updated_at: at}), do: Clock.moment(at)
  defp answered_at(_not_answered), do: nil

  defp pillar_rows(%Consult{status: :done, response: %{"pilares" => rows}}) when is_list(rows),
    do: rows

  defp pillar_rows(_nothing_yet), do: []

  # How much of the deck a pipeline is forbidden to touch. Worth a number on the
  # screen because it is invisible one row at a time: locking eight cards feels
  # like nothing, and three real decks reached 22%, 29% and 32% that way.
  #
  # Basic lands are out of the denominator — nobody optimises by cutting a
  # Forest, so counting them would flatter the number.
  defp locked_share(deck, rules) do
    locked = Enum.count(rules, &(&1.stance == :locked))

    case Enum.count(cuttable(deck)) do
      0 -> 0.0
      cuttable -> locked / cuttable
    end
  end

  defp cuttable(deck) do
    deck
    |> Decks.list_deck_cards()
    |> Enum.reject(&(&1.board == :commander or Card.basic_land?(&1.card)))
  end

  defp card_names(deck) do
    snapshot = Decks.snapshot(deck)

    Enum.map(snapshot.commanders ++ snapshot.main, & &1.card.name)
  end

  @impl Phoenix.LiveView
  def handle_info({:consult_updated, id}, socket) do
    if socket.assigns.consult && socket.assigns.consult.id == id do
      {:ok, consult} = Consults.fetch(id)

      {:noreply, socket |> assign(consult: consult) |> propose()}
    else
      {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("stance", %{"stance" => stance}, socket) do
    {:noreply, assign(socket, stance: String.to_existing_atom(stance))}
  end

  def handle_event("varrer", _params, socket) do
    socket = socket |> assign(swept?: true) |> propose()

    {:noreply, swept_message(socket)}
  end

  def handle_event("perguntar-ia", _params, socket) do
    {:ok, consult} = Consults.request(socket.assigns.deck, :pilares)

    {:noreply,
     socket
     |> assign(consult: consult)
     |> put_flash(:info, "Perguntei. A resposta aparece aqui quando chegar.")}
  end

  def handle_event("marcar-proposta", %{"card" => card}, socket) do
    checked = socket.assigns.checked

    toggled =
      if MapSet.member?(checked, card),
        do: MapSet.delete(checked, card),
        else: MapSet.put(checked, card)

    {:noreply, assign(socket, checked: toggled)}
  end

  def handle_event("trancar-marcadas", _params, socket) do
    chosen =
      Enum.filter(socket.assigns.proposals, &MapSet.member?(socket.assigns.checked, &1.name))

    Enum.each(chosen, fn proposal ->
      {:ok, _rule} =
        Decks.put_card_rule(socket.assigns.deck, proposal.name,
          stance: proposal.stance,
          note: proposal.reason,
          source: :sweep
        )
    end)

    {:noreply,
     socket
     |> load(socket.assigns.deck)
     |> put_flash(:info, saved_proposals_message(chosen))}
  end

  def handle_event("colar", %{"lote" => %{"texto" => text}}, socket) do
    stance = socket.assigns.stance

    case Decks.put_card_rules(socket.assigns.deck, text, stance) do
      {:ok, []} ->
        {:noreply, put_flash(socket, :error, "Não achei nenhum nome de carta nesse texto.")}

      {:ok, saved} ->
        {:noreply,
         socket
         |> load(socket.assigns.deck)
         |> put_flash(:info, saved_message(saved, stance))}
    end
  end

  def handle_event("mudar", %{"card" => card, "stance" => stance}, socket) do
    stance = String.to_existing_atom(stance)

    case Decks.put_card_rule(socket.assigns.deck, card, stance: stance) do
      {:ok, _rule} ->
        {:noreply,
         socket
         |> load(socket.assigns.deck)
         |> put_flash(:info, "#{card} agora é #{stance_label(stance)}.")}

      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("motivo", %{"card" => card, "motivo" => motivo}, socket) do
    case Decks.put_card_rule(socket.assigns.deck, card, note: motivo) do
      {:ok, _saved_or_removed} -> {:noreply, load(socket, socket.assigns.deck)}
      {:error, %Error{} = error} -> {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("esquecer", %{"card" => card}, socket) do
    {:ok, :removed} = Decks.delete_card_note(socket.assigns.deck, card)

    {:noreply,
     socket
     |> load(socket.assigns.deck)
     |> put_flash(:info, "#{card} saiu das suas decisões.")}
  end

  # The empty sweep is the useful message, not a failure: it says which of the
  # two sources came up dry, and the paid one is right there.
  defp swept_message(%{assigns: %{proposals: []}} = socket) do
    put_flash(socket, :error, empty_sweep(socket.assigns.deck))
  end

  defp swept_message(socket), do: socket

  defp empty_sweep(%{dossier: nil}) do
    "Não achei nada: este deck ainda não tem dossiê, que é de onde eu leio as sinergias. Gere um na página do deck, ou pergunte para a IA aqui embaixo."
  end

  defp empty_sweep(_has_dossier) do
    "Não achei nada novo — o dossiê não cita nenhuma carta que já não esteja decidida. A IA lê as cartas uma a uma e acha o que o texto não diz."
  end

  defp saved_proposals_message([]), do: "Nenhuma marcada, nada guardado."

  defp saved_proposals_message(chosen) do
    {orders, notes} = Enum.split_with(chosen, &(&1.stance == :locked))

    [count_phrase(length(orders), "obrigatória"), count_phrase(length(notes), "observação")]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", e ")
    |> Kernel.<>(".")
  end

  defp count_phrase(0, _word), do: nil
  defp count_phrase(1, word), do: "1 #{word}"
  defp count_phrase(count, "obrigatória"), do: "#{count} obrigatórias"
  defp count_phrase(count, word), do: "#{count} #{word}s"

  defp source_label(:ia), do: "a IA leu as cartas"
  defp source_label(:dossier), do: "está no dossiê"
  defp source_label(:review), do: "você disse numa revisão"

  defp saved_message([one], stance) do
    "#{one.card_name} guardada como #{stance_label(stance)}."
  end

  defp saved_message(saved, stance) do
    "#{length(saved)} cartas guardadas como #{stance_label(stance)}s."
  end

  # What each stance actually causes, said on the screen that sets it. A rule
  # whose effect you have to infer is a rule you will not trust.
  defp stance_effect(:locked) do
    "O motor recusa qualquer corte dessas cartas, em toda rodada deste deck. É o único que ele obriga."
  end

  defp stance_effect(:wanted) do
    "Toda rodada recebe essas cartas como pedido seu. A IA pode recusar, mas tem que dizer por quê, pelo nome."
  end

  defp stance_effect(:note) do
    "Vira contexto em toda consulta sobre este deck: quando a leitura dela discorda da sua, a sua vale."
  end

  # Written in the strongest-first order the page reads in, minus the one you
  # are already looking at.
  defp filled(groups) do
    [{:locked, groups.locked}, {:wanted, groups.wanted}, {:note, groups.notes}]
    |> Enum.reject(fn {_stance, rules} -> rules == [] end)
  end

  defp other_stances(stance), do: Enum.reject(CardNote.stances(), &(&1 == stance))

  defp groups_columns([_only_one]), do: nil

  defp groups_columns([_one, _two]),
    do: "2xl:grid 2xl:grid-cols-2 2xl:items-start 2xl:gap-6 2xl:space-y-0"

  defp groups_columns(_all_three),
    do: "2xl:grid 2xl:grid-cols-2 2xl:items-start 2xl:gap-6 2xl:space-y-0 3xl:grid-cols-3"

  defp motivo_placeholder(:locked), do: "por que ela não pode sair"
  defp motivo_placeholder(:wanted), do: "por que você quer ela"
  defp motivo_placeholder(:note), do: "o que ela faz de verdade neste deck"

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

      <.deck_nav deck={@deck} current={:cards} class="mt-2" />

      <%!-- Invisível uma linha por vez: trancar oito cartas não parece nada, e
            foi assim que três decks reais chegaram a 22%, 29% e 32%. Um
            pipeline que não pode cortar um terço do deck não pode melhorar
            o deck. --%>
      <p
        :if={@locked_share >= 0.15}
        class="mt-4 rounded-lg border border-sev-warning/40 bg-sev-warning/10 px-4 py-3 text-caption text-ink"
      >
        <span class="font-semibold">{percent(@locked_share)} do deck está obrigatório.</span>
        Uma otimização só pode trabalhar no que sobra — acima de mais ou menos 15% ela começa a
        ficar sem espaço para melhorar alguma coisa. Vale rebaixar para observação o que não for
        mesmo intocável: a IA continua lendo o motivo, só para de ser proibida de mexer.
      </p>

      <header class="mt-4 mb-8">
        <h1 class="text-display font-semibold text-ink">Suas cartas</h1>
        <p class="mt-1 max-w-[62ch] text-body text-ink-muted">
          Obrigar, pedir ou corrigir. O que você decide aqui vale em toda rodada deste deck — não
          só na próxima.
        </p>
      </header>

      <%!-- Mapear carta por carta é trabalho, e trabalho que ninguém faz é
            proteção que ninguém tem. Metade da resposta já está escrita: o
            dossiê nomeia as sinergias, e as revisões passadas nomearam as
            cartas que uma etapa leu errado. --%>
      <section class="mb-10 rounded-xl border border-hairline-soft bg-surface p-6">
        <div class="flex flex-wrap items-baseline justify-between gap-3">
          <h2 class="text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
            Achar as óbvias
          </h2>
          <span class="font-mono text-micro text-ink-faint">de graça, na hora</span>
        </div>

        <p class="mt-2 mb-4 max-w-[72ch] text-caption text-ink-secondary">
          Leio o dossiê e o que você já disse em revisões, e proponho o que trancar. Nada é
          trancado sem você marcar.
        </p>

        <div class="flex flex-wrap items-center gap-3">
          <.button type="button" phx-click="varrer" phx-disable-with="Lendo…">
            Ler o que o app já sabe
          </.button>

          <%!-- Um combo que ninguém escreveu ainda não deixa rastro em prosa
                nenhuma. Achar isso é ler as cartas, e ler as cartas custa. --%>
          <%!-- Some enquanto uma pergunta está no ar, e volta quando a resposta
                chega: o deck muda, a lista muda, e uma resposta de ontem sobre
                uma lista que não existe mais não pode ser a última palavra
                para sempre. --%>
          <.button
            :if={not asking?(@consult)}
            type="button"
            phx-click="perguntar-ia"
            phx-disable-with="Perguntando…"
          >
            {if @consult,
              do: "Perguntar de novo (1 consulta)",
              else: "Perguntar para a IA (1 consulta)"}
          </.button>

          <span :if={answered_at(@consult)} class="text-micro text-ink-faint">
            última resposta {answered_at(@consult)}
          </span>

          <span
            :if={@consult && @consult.status in [:pending, :running]}
            class="inline-flex items-center gap-2 text-caption text-ink-muted"
          >
            <span class="hero-arrow-path size-3 motion-safe:animate-spin" aria-hidden="true" />
            A IA está lendo as cartas — 2 a 5 min.
          </span>

          <span :if={@consult && @consult.status == :failed} class="text-caption text-sev-critical">
            A consulta falhou. A varredura de graça continua valendo.
          </span>
        </div>

        <div :if={@proposals != []} class="mt-5 border-t border-hairline-soft pt-4">
          <h3 class="mb-3 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
            Proponho guardar ({MapSet.size(@checked)} de {length(@proposals)})
          </h3>

          <ul class="space-y-2">
            <li :for={proposal <- @proposals} class="rounded-lg bg-inlay/60 px-3 py-2">
              <label class="flex cursor-pointer items-start gap-3">
                <input
                  type="checkbox"
                  checked={MapSet.member?(@checked, proposal.name)}
                  phx-click="marcar-proposta"
                  phx-value-card={proposal.name}
                  class="mt-1 size-4 shrink-0 rounded border-hairline-strong bg-inlay text-ink"
                />
                <span class="min-w-0">
                  <span class="text-body font-semibold text-ink">{proposal.name}</span>
                  <.card_stance stance={proposal.stance} class="ml-2" />
                  <span class="ml-2 font-mono text-micro text-ink-faint">
                    {source_label(proposal.source)}
                  </span>
                  <span :if={proposal.reason != ""} class="mt-0.5 block text-caption text-ink-muted">
                    {proposal.reason}
                  </span>
                </span>
              </label>
            </li>
          </ul>

          <div class="mt-4 flex justify-end">
            <.button
              type="button"
              phx-click="trancar-marcadas"
              variant="primary"
              disabled={MapSet.size(@checked) == 0}
              phx-disable-with="Guardando…"
            >
              Guardar as marcadas
            </.button>
          </div>
        </div>
      </section>

      <section class="mb-10 rounded-xl border border-hairline-soft bg-surface p-6">
        <h2 class="mb-3 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
          Colar cartas
        </h2>

        <div class="mb-4 flex flex-wrap gap-1" role="group" aria-label="O que fazer com essas cartas">
          <button
            :for={stance <- CardNote.stances()}
            type="button"
            phx-click="stance"
            phx-value-stance={stance}
            aria-pressed={to_string(stance == @stance)}
            class={[
              "min-h-touch rounded-md border px-4 text-caption transition-colors motion-reduce:transition-none",
              stance == @stance && "border-hairline-strong bg-inlay text-ink",
              stance != @stance && "border-hairline-soft text-ink-faint hover:text-ink"
            ]}
          >
            {stance_heading(stance)}
          </button>
        </div>

        <p class="mb-4 max-w-[70ch] text-caption text-ink-secondary">{stance_effect(@stance)}</p>

        <.form for={%{}} id="colar" phx-submit="colar">
          <.field
            id="lote-texto"
            name="lote[texto]"
            label="Uma carta por linha"
            rows={5}
            numeric
            placeholder={lote_placeholder()}
            hint={lote_hint()}
          />

          <div class="mt-3 flex justify-end">
            <.button type="submit" variant="primary" phx-disable-with="Guardando…">
              Guardar como {stance_heading(@stance) |> String.downcase()}
            </.button>
          </div>
        </.form>
      </section>

      <div
        :if={@groups.locked == [] and @groups.wanted == [] and @groups.notes == []}
        class="rounded-xl border border-hairline-soft bg-surface p-10 text-center"
      >
        <p class="text-body text-ink-secondary">Você ainda não mandou nada sobre carta nenhuma.</p>
        <p class="mx-auto mt-2 max-w-[52ch] text-caption text-ink-muted">
          Comece pelas que uma otimização não pode cortar: peças de combo, cartas que o deck todo
          depende, o que você já viu uma rodada errar.
        </p>
      </div>

      <%!-- The groups are read against each other — "o que é obrigatório"
            only means something next to "o que é só pedido" — so on a wide
            screen they sit side by side. The column count follows how many
            groups actually have something in them: one group alone at a third
            of a 2560px screen is a narrow strip beside two empty thirds, and
            a deck with only locked cards is the common case. `items-start`
            because they are never the same height. --%>
      <div class={["space-y-8", groups_columns(filled(@groups))]}>
        <.group
          :for={{stance, rules} <- filled(@groups)}
          stance={stance}
          rules={rules}
          missing={@missing}
          present={@present}
        />
      </div>
    </div>
    """
  end

  attr :stance, :atom, required: true
  attr :rules, :list, required: true
  attr :missing, :any, required: true
  attr :present, :any, required: true

  defp group(assigns) do
    ~H"""
    <section>
      <div class="mb-1 flex flex-wrap items-baseline gap-x-3">
        <h2 class="text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
          {stance_heading(@stance)} ({length(@rules)})
        </h2>
      </div>
      <p class="mb-3 max-w-[70ch] text-caption text-ink-muted">{stance_effect(@stance)}</p>

      <ul class="space-y-3">
        <li
          :for={rule <- @rules}
          class="rounded-xl border border-hairline-soft bg-surface p-4"
        >
          <div class="flex flex-wrap items-baseline gap-x-3 gap-y-1">
            <span class="text-body font-semibold text-ink">{rule.card_name}</span>

            <%!-- The single most useful line on this screen: an order about a
                  card the deck does not have is the one still waiting to be
                  acted on, and nothing else would tell him. --%>
            <span
              :if={@stance == :locked and MapSet.member?(@missing, rule.card_name)}
              class="inline-flex items-center rounded-md bg-sev-warning/15 px-1.5 py-0.5 text-micro font-semibold uppercase tracking-[0.08em] text-sev-warning"
            >
              fora do deck
            </span>

            <span
              :if={
                @stance == :wanted and
                  MapSet.member?(@present, Name.normalize(rule.card_name))
              }
              class="inline-flex items-center rounded-md bg-sev-healthy/15 px-1.5 py-0.5 text-micro font-semibold uppercase tracking-[0.08em] text-sev-healthy"
            >
              já entrou
            </span>

            <span :if={rule.source == :review} class="font-mono text-micro text-ink-faint">
              da sua revisão
            </span>

            <div class="ml-auto flex flex-wrap items-center gap-1">
              <button
                :for={other <- other_stances(@stance)}
                type="button"
                phx-click="mudar"
                phx-value-card={rule.card_name}
                phx-value-stance={other}
                title={stance_effect(other)}
                class="-my-2 inline-flex min-h-touch items-center px-2 py-2 text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink motion-reduce:transition-none"
              >
                → {stance_label(other)}
              </button>

              <button
                type="button"
                phx-click="esquecer"
                phx-value-card={rule.card_name}
                data-confirm={"Esquecer o que você decidiu sobre #{rule.card_name}?"}
                class="-my-2 inline-flex min-h-touch items-center px-2 py-2 text-caption text-sev-critical underline decoration-hairline-strong underline-offset-2 transition-colors hover:decoration-sev-critical motion-reduce:transition-none"
              >
                esquecer
              </button>
            </div>
          </div>

          <.form for={%{}} id={"motivo-#{rule.id}"} phx-submit="motivo" class="mt-2">
            <input type="hidden" name="card" value={rule.card_name} />
            <label for={"motivo-input-#{rule.id}"} class="sr-only">
              Motivo para {rule.card_name}
            </label>
            <div class="flex flex-wrap items-center gap-2">
              <input
                id={"motivo-input-#{rule.id}"}
                type="text"
                name="motivo"
                value={rule.note}
                placeholder={motivo_placeholder(@stance)}
                class={[control_class(), "min-h-touch min-w-0 flex-1"]}
              />
              <.button type="submit" phx-disable-with="…">Guardar</.button>
            </div>
          </.form>
        </li>
      </ul>
    </section>
    """
  end

  # A function, not an inline string: the formatter mangles multi-line
  # attribute literals (the placeholder law from the import screen).
  defp lote_hint do
    "O motivo vem depois de uma barra vertical, e é opcional — mas é ele que ensina a IA. " <>
      "\"1x\" na frente do nome é ignorado, então dá para colar linhas de decklist direto."
  end

  defp lote_placeholder do
    "Sam, Loyal Attendant | combo infinito com o Prize Pig: comida sai de graça\nPrize Pig"
  end
end
