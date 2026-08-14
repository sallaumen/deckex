defmodule DeckexWeb.SettingsLive do
  @moduledoc """
  `/ajustes` — the settings panel as a page of its own.

  It renders the same `DeckexWeb.SettingsPanel` the gear button opens
  everywhere else, already open. Two implementations of one settings screen is
  how the two drift apart; this way the modal is the only implementation and
  the URL is just another way in — for a bookmark, or a link in a note.
  """
  use DeckexWeb, :live_view

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Ajustes")}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-[1100px] px-6 py-10 lg:px-10 lg:py-14">
      <%!-- Inside the LiveView's own tree, not the root layout: the layout is
            static after mount, so a flash put during an event would never
            reach the screen from there. --%>
      <DeckexWeb.Layouts.flash_group flash={@flash} />
      <.link
        navigate={~p"/"}
        class="-my-2 inline-flex min-h-11 items-center py-2 text-caption text-ink-faint transition-colors hover:text-ink"
      >
        ← A Mesa
      </.link>

      <header class="mt-3 mb-10">
        <h1 class="text-display font-semibold text-ink">Ajustes</h1>
        <p class="mt-1 text-body text-ink-muted">
          Os mesmos ajustes da engrenagem no canto — aqui em página inteira.
        </p>
      </header>

      <.live_component module={DeckexWeb.SettingsPanel} id="settings-page" open />
    </div>
    """
  end
end
