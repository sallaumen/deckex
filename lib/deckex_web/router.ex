defmodule DeckexWeb.Router do
  use DeckexWeb, :router

  # Every origin the app actually uses, and nothing else. Each entry earns its
  # place:
  #
  #   * `img-src` allows cards.scryfall.io because that is where card art comes
  #     from, and `data:` because the mana pips are inline SVG data URIs.
  #   * `style-src` allows 'unsafe-inline' — not a concession but a consequence:
  #     the severity colours are computed with color-mix() in a `style`
  #     attribute, and an attribute is inline by definition. An inline style
  #     cannot execute code, which is why 'unsafe-inline' is granted here and
  #     never in `script-src`.
  #   * `connect-src` allows ws:/wss: for the LiveView socket.
  #   * Nothing here names another host except Scryfall's image CDN. The
  #     typefaces are self-hosted (see assets/css/fonts.css), so a page load
  #     talks to nobody but us.
  @csp "default-src 'self'; " <>
         "script-src 'self'; " <>
         "style-src 'self' 'unsafe-inline'; " <>
         "font-src 'self'; " <>
         "img-src 'self' data: https://cards.scryfall.io; " <>
         "connect-src 'self' ws: wss:; " <>
         "frame-ancestors 'none'; " <>
         "base-uri 'self'; " <>
         "form-action 'self'; " <>
         "object-src 'none'"

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DeckexWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"content-security-policy" => @csp}
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", DeckexWeb do
    pipe_through :browser

    live "/", MesaLive, :index
    live "/importar", ImportLive, :new
    live "/ajustes", SettingsLive, :edit
    live "/decks/:id", DeckLive, :show
    live "/decks/:id/otimizacoes", OptimizationsLive, :index
    live "/otimizacoes/:id", OptimizationLive, :show

    get "/consultas/:id/csv", ExportController, :consult_csv
    get "/decks/:id/lista.txt", ExportController, :deck_txt
    get "/otimizacoes/:id/compras.txt", ExportController, :optimization_shopping_txt
  end

  # Other scopes may use custom stacks.
  # scope "/api", DeckexWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:deckex, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: DeckexWeb.Telemetry
    end

    # The design-system preview: every component in `DeckexWeb.UI` on one page,
    # against real sample data. Dev only — it is a workbench, not a screen.
    scope "/dev", DeckexWeb do
      pipe_through :browser

      get "/ui", PageController, :ui
    end
  end
end
