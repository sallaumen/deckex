defmodule DeckexWeb.SettingsAndTableTest do
  use DeckexWeb.ConnCase, async: true
  # Repricing the catalogue is enqueued, not run in the click.
  use Oban.Testing, repo: Deckex.Repo

  import Phoenix.LiveViewTest

  alias Deckex.CatalogueFixture
  alias Deckex.Consults
  alias Deckex.Decks
  alias Deckex.Settings

  describe "Ajustes" do
    test "shows every declared setting, grouped", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/ajustes")

      assert html =~ "Modelo do Claude"
      assert html =~ "User-Agent do Moxfield"
      assert html =~ "Baselines"
      # The ceilings are the most-adjusted knobs, so they get their own group.
      assert html =~ "Tetos de preço"
      assert html =~ "Teto por terreno (R$)"
      # The hint is the point: the field means nothing without it.
      assert html =~ "support@moxfield.com"
    end

    test "saves the model", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/ajustes")

      live
      |> form("#panel-claude_model", setting: %{key: "claude_model", value: "opus"})
      |> render_submit()

      assert Settings.get(:claude_model) == "opus"
    end

    # The gear opens the same component the page renders — one implementation,
    # two ways in. Two settings screens is how two settings screens drift.
    test "the gear on a deck page opens the same panel", %{conn: conn} do
      CatalogueFixture.seed!(~w(sol_ring forest))

      {:ok, deck} =
        Decks.import_from_text("1 Sol Ring\n4 Forest", %{name: "Deck", source: :paste})

      {:ok, live, html} = live(conn, ~p"/decks/#{deck.id}")

      refute html =~ "Teto por terreno"

      opened = live |> element("button[phx-click='open']") |> render_click()

      assert opened =~ "Teto por terreno (R$)"
      assert opened =~ "Modelo do Claude"
    end

    test "the ceilings save as numbers", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/ajustes")

      live
      |> form("#panel-upgrade_land_max_brl",
        setting: %{key: "upgrade_land_max_brl", value: "150"}
      )
      |> render_submit()

      assert Settings.get(:upgrade_land_max_brl) == 150
      assert Settings.ceilings(:upgrade).land == 150
    end

    test "saves a baseline override", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/ajustes")

      live
      |> form("#panel-baseline-land_base", baseline: %{field: "land_base", value: "38"})
      |> render_submit()

      assert Settings.baselines().land_base == 38
    end

    # Repricing costs a request per card, so it queues rather than running in
    # the click. The panel says how many are in line, because a button that
    # appears to do nothing gets pressed again.
    test "repricing the catalogue queues the work instead of blocking", %{conn: conn} do
      CatalogueFixture.seed!(~w(sol_ring forest))

      {:ok, live, _html} = live(conn, ~p"/ajustes")

      html = live |> element("button[phx-click='reprice-catalogue']") |> render_click()

      assert html =~ "2 carta(s) na fila"
      assert_enqueued(worker: Deckex.Workers.RepriceWorker)
    end
  end

  describe "the suggestion table" do
    setup do
      # Counterspell is rank 145 and Humility past eleven thousand: one add
      # nearly everyone plays and one almost nobody does, which is the pair the
      # price column cannot tell apart.
      CatalogueFixture.seed!(~w(sol_ring forest counterspell humility))

      {:ok, deck} =
        Decks.import_from_text("1 Sol Ring\n4 Forest", %{name: "Deck da Tabela", source: :paste})

      {:ok, consult} = Consults.request(deck, :full)

      {:ok, answered} =
        consult
        |> Ecto.Changeset.change(%{
          status: :done,
          response: %{
            "diagnosis" => "Falta interação.",
            "cuts" => [%{"card" => "Sol Ring", "reason" => "abre espaço"}],
            "adds" => [
              %{
                "card" => "Counterspell",
                "reason" => "interação barata",
                "addresses" => "interaction.total_low"
              },
              %{"card" => "Humility", "reason" => "apaga o campo todo"}
            ]
          }
        })
        |> Deckex.Repo.update()

      %{deck: deck, consult: answered}
    end

    test "renders a row per suggestion with its price in both currencies",
         %{conn: conn, deck: deck} do
      {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

      assert html =~ "Counterspell"
      assert html =~ "interação barata"
      assert html =~ "interaction.total_low"
      assert html =~ "US$"
      assert html =~ "R$"
    end

    # The column exists because reais cannot answer "is this card any good".
    # Counterspell is rank 145 in the fixture: cheap and a staple, which is the
    # exact pairing that made the owner distrust the cheap suggestions.
    test "each suggestion carries how much of the format plays it",
         %{conn: conn, deck: deck} do
      {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

      assert html =~ "Preço e uso"
      assert html =~ "em uso no Commander"
      assert html =~ "carta de base do formato"
      assert html =~ "quase ninguém joga"
    end

    # The answer to "are these any good?" should arrive before twenty rows do.
    test "the footer counts the adds almost nobody plays", %{conn: conn, deck: deck} do
      {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

      assert html =~ "1 quase ninguém joga"
    end

    test "adding a suggested card puts it in the deck", %{conn: conn, deck: deck} do
      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

      live
      |> element("button[phx-click='apply-add'][phx-value-name='Counterspell']")
      |> render_click()

      assert "Counterspell" in Enum.map(Decks.list_deck_cards(deck), & &1.card.name)
    end

    # The message itself is asserted in Deckex.DeckEditingTest; what matters
    # here is that a double click cannot quietly produce an illegal decklist.
    test "clicking add twice does not add a second copy", %{conn: conn, deck: deck} do
      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

      add = element(live, "button[phx-click='apply-add'][phx-value-name='Counterspell']")

      render_click(add)
      render_click(add)

      counterspell = Enum.find(Decks.list_deck_cards(deck), &(&1.card.name == "Counterspell"))
      assert counterspell.quantity == 1
    end

    test "cutting a suggested card removes it", %{conn: conn, deck: deck} do
      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

      live
      |> element("button[phx-click='apply-cut'][phx-value-name='Sol Ring']")
      |> render_click()

      refute "Sol Ring" in Enum.map(Decks.list_deck_cards(deck), & &1.card.name)
    end

    # This deck has no commander, so its colour identity is empty — adding the
    # blue Counterspell is illegal, and the engine must say so on the row.
    test "the engine's verdict renders on an illegal suggestion", %{conn: conn, deck: deck} do
      {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

      assert html =~ "motor:"
      assert html =~ "fora da identidade de cor (U)"
    end

    test "the measured before→after renders under the table", %{conn: conn, deck: deck} do
      {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

      assert html =~ "Conferido pelo motor"
    end

    test "the table exports as CSV", %{conn: conn, deck: deck, consult: consult} do
      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

      assert live |> element("a[download][href*='#{consult.id}']") |> has_element?()

      csv = conn |> get(~p"/consultas/#{consult.id}/csv") |> response(200)

      assert csv =~ "acao,carta,motivo"
      assert csv =~ "colocar,Counterspell"
    end

    test "the model can be chosen and the lens picked", %{conn: conn, deck: deck} do
      {:ok, live, html} = live(conn, ~p"/decks/#{deck.id}")

      assert html =~ "opus"
      assert html =~ "Contra um deck específico"

      live
      |> form("form[phx-submit='consult-full']",
        consult: %{lens: "upgrade", model: "opus", against: ""}
      )
      |> render_submit()

      assert Enum.any?(
               Consults.list_for_deck(deck),
               &(&1.lens == :upgrade and &1.model == "opus")
             )
    end

    test "comparing runs one briefing across every model", %{conn: conn, deck: deck} do
      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

      live |> element("button[phx-click='compare-models']") |> render_click()

      compared = Enum.filter(Consults.list_for_deck(deck), &(&1.status == :pending))

      assert length(compared) >= length(Consults.models())
    end
  end
end
