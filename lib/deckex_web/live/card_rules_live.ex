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

  alias Deckex.Cards.Name
  alias Deckex.Decks
  alias Deckex.Decks.CardNote
  alias Deckex.Decks.CardRules
  alias Deckex.Error

  @impl Phoenix.LiveView
  def mount(%{"id" => deck_id}, _session, socket) do
    case Decks.fetch_deck(deck_id) do
      {:ok, deck} ->
        {:ok, socket |> assign(stance: :locked) |> load(deck)}

      {:error, %Error{} = error} ->
        {:ok, socket |> put_flash(:error, error.message) |> push_navigate(to: ~p"/")}
    end
  end

  defp load(socket, deck) do
    rules = Decks.card_notes(deck)
    present = card_names(deck)

    assign(socket,
      deck: deck,
      groups: CardRules.split(rules),
      # Computed once for the whole page rather than per row: the answer is the
      # same for every row and the deck is ~100 cards.
      missing: CardRules.missing_from(Enum.map(rules, & &1.card_name), present),
      present: MapSet.new(present, &Name.normalize/1),
      page_title: "Cartas · #{deck.name}"
    )
  end

  defp card_names(deck) do
    snapshot = Decks.snapshot(deck)

    Enum.map(snapshot.commanders ++ snapshot.main, & &1.card.name)
  end

  @impl Phoenix.LiveView
  def handle_event("stance", %{"stance" => stance}, socket) do
    {:noreply, assign(socket, stance: String.to_existing_atom(stance))}
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

  defp motivo_placeholder(:locked), do: "por que ela não pode sair"
  defp motivo_placeholder(:wanted), do: "por que você quer ela"
  defp motivo_placeholder(:note), do: "o que ela faz de verdade neste deck"

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-[1100px] px-6 py-10 lg:px-10 lg:py-14">
      <DeckexWeb.Layouts.flash_group flash={@flash} />
      <.live_component module={DeckexWeb.SettingsPanel} id="settings-panel" />

      <.link
        navigate={~p"/decks/#{@deck.id}"}
        class="-my-2 inline-flex min-h-touch items-center py-2 text-caption text-ink-faint transition-colors hover:text-ink"
      >
        ← {@deck.name}
      </.link>

      <.deck_nav deck={@deck} current={:cards} class="mt-2" />

      <header class="mt-4 mb-8">
        <h1 class="text-display font-semibold text-ink">Suas cartas</h1>
        <p class="mt-1 max-w-[62ch] text-body text-ink-muted">
          Obrigar, pedir ou corrigir. O que você decide aqui vale em toda rodada deste deck — não
          só na próxima.
        </p>
      </header>

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
          <label for="lote-texto" class="mb-1 block text-caption font-semibold text-ink-secondary">
            Uma carta por linha
          </label>
          <textarea
            id="lote-texto"
            name="lote[texto]"
            rows="5"
            placeholder={lote_placeholder()}
            class="w-full rounded-md border border-hairline-soft bg-inlay px-3 py-2 font-mono text-caption text-ink placeholder:text-ink-faint"
          ></textarea>
          <p class="mt-1 text-micro text-ink-muted">
            O motivo vem depois de uma barra vertical, e é opcional — mas é ele que ensina a IA. "1x"
            na frente do nome é ignorado, então dá para colar linhas de decklist direto.
          </p>

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

      <div class="space-y-8">
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
                class="min-h-touch min-w-0 flex-1 rounded-md border border-hairline-soft bg-inlay px-3 py-2 text-caption text-ink placeholder:text-ink-faint"
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
  defp lote_placeholder do
    "Sam, Loyal Attendant | combo infinito com o Prize Pig: comida sai de graça\nPrize Pig"
  end
end
