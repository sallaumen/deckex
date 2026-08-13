defmodule DeckexWeb.ImportLive do
  @moduledoc """
  Bringing a deck to the table.

  Two panels, side by side, and the honest one is on the left: pasting a
  decklist always works, works for private decks, and cannot break. The
  Moxfield URL panel is beside it with its own warning rather than hidden
  behind a "try this first" flow — the user should be able to see why it
  usually fails before they spend a click on it.
  """
  use DeckexWeb, :live_view

  alias Deckex.Decks
  alias Deckex.Error

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Importar",
       paste_form: to_form(%{"name" => "", "decklist" => ""}, as: :paste),
       url_form: to_form(%{"url" => ""}, as: :url),
       importing: nil,
       error: nil
     )}
  end

  @impl Phoenix.LiveView
  def handle_event("paste", %{"paste" => %{"name" => name, "decklist" => decklist}}, socket) do
    socket
    |> assign(importing: :paste, error: nil)
    |> finish(Decks.import_from_text(decklist, %{name: blank_to_default(name), source: :paste}))
  end

  def handle_event("sync", %{"url" => %{"url" => url}}, socket) do
    socket
    |> assign(importing: :url, error: nil)
    |> finish(Decks.import_from_url(url))
  end

  defp finish(socket, {:ok, deck}) do
    {:noreply,
     socket
     |> put_flash(:info, "#{deck.name} está na mesa.")
     |> push_navigate(to: ~p"/decks/#{deck.id}")}
  end

  defp finish(socket, {:error, %Error{} = error}) do
    {:noreply, assign(socket, importing: nil, error: error)}
  end

  defp blank_to_default(""), do: "Deck sem nome"
  defp blank_to_default(name), do: name

  # A function, not an inline string: the HEEx formatter rewrites
  # `placeholder={"a\nb"}` into a literal HTML attribute, which turns the
  # escapes into visible backslashes.
  defp decklist_example do
    """
    Commander
    1 Iroh, Grand Lotus (TLA) 227

    ----
    1 Sol Ring (M3C) 305
    4 Forest (DMU) 276\
    """
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-[1400px] px-6 py-10 lg:px-10 lg:py-14">
      <.link navigate={~p"/"} class="text-caption text-ink-faint transition-colors hover:text-ink">
        ← A Mesa
      </.link>

      <header class="mt-3 mb-10">
        <h1 class="text-hero font-semibold text-ink">Trazer um deck</h1>
        <p class="mt-1 text-body text-ink-muted">
          Cole a lista exportada ou tente o link do Moxfield.
        </p>
      </header>

      <div
        :if={@error}
        class="mb-8 rounded-lg border bg-surface p-4"
        style={"border-color:color-mix(in srgb, #{Format.severity_var(:critical)} 30%, transparent)"}
      >
        <p class="text-body text-ink">{@error.message}</p>
        <p class="mt-1 font-mono text-caption text-ink-faint">{@error.code}</p>
      </div>

      <div class="grid gap-8 lg:grid-cols-[1.4fr_1fr] lg:items-start">
        <section class="rounded-xl border border-hairline-soft bg-surface p-6">
          <h2 class="text-heading font-semibold text-ink">Colar a lista</h2>
          <p class="mt-1 mb-5 text-caption text-ink-muted">
            No Moxfield: abra o deck → <span class="text-ink-secondary">Export</span>
            → copie tudo. Funciona com deck privado.
          </p>

          <.form for={@paste_form} phx-submit="paste" class="space-y-4">
            <.input field={@paste_form[:name]} label="Nome do deck" placeholder="Iroh das Lontra" />

            <div>
              <label
                for="paste_decklist"
                class="mb-1.5 block text-label font-semibold uppercase tracking-[0.1em] text-ink-faint"
              >
                A lista
              </label>
              <textarea
                id="paste_decklist"
                name="paste[decklist]"
                rows="16"
                required
                placeholder={decklist_example()}
                class="w-full rounded-md border border-hairline-soft bg-inlay px-3 py-2 font-mono text-body-sm text-ink placeholder:text-ink-disabled focus:border-ink-faint"
              >{@paste_form[:decklist].value}</textarea>
            </div>

            <.button type="submit" variant="primary" disabled={@importing == :paste}>
              {if @importing == :paste, do: "Importando…", else: "Importar"}
            </.button>
          </.form>
        </section>

        <section class="rounded-xl border border-hairline-soft bg-surface p-6">
          <h2 class="text-heading font-semibold text-ink">Link do Moxfield</h2>

          <p class="mt-1 mb-5 text-caption text-ink-muted">
            O Moxfield não tem API pública e bloqueia clientes não aprovados —
            normalmente responde <span class="font-mono text-ink-secondary">403</span>. Está aqui
            porque funciona no dia em que eles liberarem um User-Agent pra você.
          </p>

          <.form for={@url_form} phx-submit="sync" class="space-y-4">
            <.input
              field={@url_form[:url]}
              label="URL do deck"
              placeholder="https://moxfield.com/decks/…"
            />

            <.button type="submit" disabled={@importing == :url}>
              {if @importing == :url, do: "Buscando…", else: "Tentar sincronizar"}
            </.button>
          </.form>
        </section>
      </div>
    </div>
    """
  end
end
