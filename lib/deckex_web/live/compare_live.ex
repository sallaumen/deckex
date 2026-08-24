defmodule DeckexWeb.CompareLive do
  @moduledoc """
  Two decks side by side, and the price of turning one into the other.

  The screen exists because forking is cheap here and duplicates pile up: a
  deck, its optimized fork, last year's build. A month later nobody remembers
  what actually separates them, and the honest answer is a shopping list, not
  a feeling.

  It is the versions screen's comparison with the pickers pointed at decks
  instead of versions — deliberately the same arithmetic and the same reading,
  because they are the same question.
  """
  use DeckexWeb, :live_view

  alias Deckex.Decks
  alias Deckex.Money

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    decks = Decks.list_decks()

    {:ok,
     socket
     |> assign(decks: decks, page_title: "Comparar decks")
     |> choose(params["de"] || id_at(decks, 1), params["para"] || id_at(decks, 0))}
  end

  defp id_at(decks, index) do
    case Enum.at(decks, index) do
      nil -> nil
      deck -> deck.id
    end
  end

  defp choose(socket, from_id, to_id) do
    from = find(socket.assigns.decks, from_id)
    to = find(socket.assigns.decks, to_id)

    assign(socket,
      from: from,
      to: to,
      diff: from && to && from.id != to.id && Decks.compare(from, to)
    )
  end

  defp find(_decks, nil), do: nil
  defp find(decks, id), do: Enum.find(decks, &(&1.id == id))

  @impl Phoenix.LiveView
  def handle_event("comparar", %{"de" => from_id, "para" => to_id}, socket) do
    {:noreply, choose(socket, from_id, to_id)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-[1100px] px-6 py-10 lg:px-10 lg:py-14 2xl:max-w-[1400px]">
      <DeckexWeb.Layouts.flash_group flash={@flash} />
      <.live_component module={DeckexWeb.SettingsPanel} id="settings-panel" />

      <.link
        navigate={~p"/"}
        class="-my-2 inline-flex min-h-touch items-center py-2 text-caption text-ink-faint transition-colors hover:text-ink"
      >
        ← A Mesa
      </.link>

      <header class="mt-3 mb-8">
        <h1 class="text-display font-semibold text-ink">Comparar decks</h1>
        <p class="mt-1 text-body text-ink-muted">
          Tenho um, quero o outro — o que preciso comprar.
        </p>
      </header>

      <div
        :if={length(@decks) < 2}
        class="rounded-xl border border-hairline-soft bg-surface p-10 text-center"
      >
        <p class="text-body text-ink-secondary">Precisa de dois decks na mesa para comparar.</p>
      </div>

      <section :if={length(@decks) > 1} class="rounded-xl border border-hairline-soft bg-surface p-6">
        <%!-- Two pickers, not a banner: past 2xl they would each be 650px of
              select for a deck name that is never that long. --%>
        <.form
          for={%{}}
          id="comparar"
          phx-change="comparar"
          class="flex flex-wrap items-end gap-3 2xl:max-w-[54rem]"
        >
          <div class="min-w-0 flex-1">
            <label for="de" class="mb-1 block text-caption text-ink-secondary">Tenho</label>
            <select id="de" name="de" class={select_class()}>
              <option :for={deck <- @decks} value={deck.id} selected={@from && deck.id == @from.id}>
                {deck.name}
              </option>
            </select>
          </div>

          <div class="min-w-0 flex-1">
            <label for="para" class="mb-1 block text-caption text-ink-secondary">Quero</label>
            <select id="para" name="para" class={select_class()}>
              <option :for={deck <- @decks} value={deck.id} selected={@to && deck.id == @to.id}>
                {deck.name}
              </option>
            </select>
          </div>
        </.form>

        <p :if={@from && @to && @from.id == @to.id} class="mt-5 text-body text-ink-secondary">
          Esse é o mesmo deck dos dois lados.
        </p>

        <%!-- The shopping list and the list of cards that stay home are read
              together — "what this costs" and "what I give up" — and past 2xl
              they fit that way. The second column is narrower on purpose: one
              side is a priced table, the other a sentence of names. --%>
        <div
          :if={@diff}
          class={[
            "mt-6",
            (@diff.buy != [] and @diff.drop != []) &&
              "2xl:grid 2xl:grid-cols-[minmax(0,1fr)_minmax(0,22rem)] 2xl:items-start 2xl:gap-10"
          ]}
        >
          <p :if={@diff.buy == [] and @diff.drop == []} class="text-body text-ink-secondary">
            As duas listas são iguais, carta por carta.
          </p>

          <div :if={@diff.buy != []} class="mb-6 2xl:mb-0">
            <h2 class="mb-2 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
              Comprar ({length(@diff.buy)})
            </h2>
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
                href={~p"/comparar/#{@from.id}/para/#{@to.id}/compras.txt"}
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

          <%!-- Named, not just counted: "sai do deck" is the half that tells
                you the two lists are the same deck with a different idea, and
                the names are what you recognise. --%>
          <div :if={@diff.drop != []}>
            <h2 class="mb-2 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
              Fica de fora ({length(@diff.drop)})
            </h2>
            <p class="text-caption text-ink-muted">
              {Enum.map_join(@diff.drop, ", ", & &1.name)}
            </p>
          </div>
        </div>
      </section>
    </div>
    """
  end

  defp select_class do
    "min-h-touch w-full rounded-md border border-hairline-soft bg-inlay px-3 text-caption text-ink focus:border-ink-faint"
  end
end
