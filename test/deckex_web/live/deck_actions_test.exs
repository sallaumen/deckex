defmodule DeckexWeb.DeckActionsTest do
  use DeckexWeb.ConnCase, async: true

  import Deckex.Factory
  import Phoenix.LiveViewTest

  alias Deckex.CatalogueFixture
  alias Deckex.Decks

  defp deck(name \\ "Nome do Import") do
    CatalogueFixture.seed!(~w(sol_ring natures_lore forest))

    {:ok, deck} =
      Decks.import_from_text("Commander:\n1 Nature's Lore\n\nDeck:\n1 Sol Ring\n4 Forest", %{
        name: name,
        source: :paste
      })

    deck
  end

  describe "renaming" do
    test "the name is the owner's, not the import's", %{conn: conn} do
      deck = deck()

      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

      live |> element("button[phx-click='start-rename']") |> render_click()

      html =
        live
        |> form("form[phx-submit='rename']", deck: %{name: "Iroh das Lontra"})
        |> render_submit()

      assert html =~ "Iroh das Lontra"
      assert Decks.get_deck(deck.id).name == "Iroh das Lontra"
    end

    test "blank is refused — a nameless deck is unfindable", %{conn: conn} do
      deck = deck("Tem Nome")

      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

      live |> element("button[phx-click='start-rename']") |> render_click()

      html = live |> form("form[phx-submit='rename']", deck: %{name: "   "}) |> render_submit()

      assert html =~ "O deck precisa de um nome"
      assert Decks.get_deck(deck.id).name == "Tem Nome"
    end

    test "cancelling leaves the name alone", %{conn: conn} do
      deck = deck("Intocado")

      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

      live |> element("button[phx-click='start-rename']") |> render_click()
      html = live |> element("button[phx-click='cancel-rename']") |> render_click()

      assert html =~ "Intocado"
      refute has_element?(live, "form[phx-submit='rename']")
    end
  end

  describe "duplicating" do
    test "copies the list as it stands, not as it was imported", %{conn: conn} do
      deck = deck("Original")
      # An edit after the import: `raw_decklist` still says otherwise.
      {:ok, _} = Decks.remove_card(deck, "Sol Ring")

      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

      live |> element("button[phx-click='duplicate']") |> render_click()

      assert copy = Enum.find(Decks.list_decks(), &(&1.name == "Original — cópia"))

      names = copy |> Decks.list_deck_cards() |> Enum.map(& &1.card.name)
      refute "Sol Ring" in names
      assert "Nature's Lore" in names
    end

    test "the commander stays a commander in the copy", %{conn: conn} do
      deck = deck("Com Comandante")

      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")
      live |> element("button[phx-click='duplicate']") |> render_click()

      copy = Enum.find(Decks.list_decks(), &(&1.name == "Com Comandante — cópia"))

      assert [%{card: %{name: "Nature's Lore"}}] =
               copy |> Decks.list_deck_cards() |> Enum.filter(&(&1.board == :commander))
    end

    # The dossier is the one thing on a deck that cost money — a scout consult
    # wrote it. Dropping it would charge the owner again for a reading he
    # already bought, and silently.
    test "the dossier rides along instead of being bought twice", %{conn: conn} do
      deck = deck("Com Dossiê")

      {:ok, deck} =
        Decks.edit_dossier(deck, %{
          "plano" => "Lontras e feitiços.",
          "sinergias" => "Iroh dá flashback.",
          "linhas_de_vitoria" => "Storm.",
          "fraquezas" => "Cemitério."
        })

      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")
      live |> element("button[phx-click='duplicate']") |> render_click()

      copy = Enum.find(Decks.list_decks(), &(&1.name == "Com Dossiê — cópia"))

      assert copy.dossier["plano"] == "Lontras e feitiços."
      assert copy.dossier_source == deck.dossier_source
      # The copy holds the same cards, so the reading is exactly as current as
      # it was a moment ago: marking it stale would be a lie the owner pays a
      # consult to clear.
      assert copy.dossier_stale == deck.dossier_stale
    end

    test "a deck with no dossier copies cleanly", %{conn: conn} do
      deck = deck("Sem Dossiê")

      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")
      live |> element("button[phx-click='duplicate']") |> render_click()

      copy = Enum.find(Decks.list_decks(), &(&1.name == "Sem Dossiê — cópia"))

      assert copy.dossier == nil
    end

    test "the original is untouched", %{conn: conn} do
      deck = deck("Original")

      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")
      live |> element("button[phx-click='duplicate']") |> render_click()

      assert Decks.get_deck(deck.id).name == "Original"
      assert length(Decks.list_decks()) == 2
    end
  end

  describe "deleting from the deck's own page" do
    test "goes back to the table with the deck gone", %{conn: conn} do
      deck = deck("Para Apagar")

      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

      assert {:error, {:live_redirect, %{to: "/"}}} =
               live |> element("button[phx-click='delete']") |> render_click()

      assert Decks.list_decks() == []
    end

    test "the confirmation names what goes along", %{conn: conn} do
      deck = deck()
      insert(:consult, deck: deck)

      {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

      assert html =~ "1 consulta(s)"
    end
  end

  describe "downloading the list" do
    # The deck goes back out the door it came in through: the same format the
    # app imports, and the one a shop's bulk-add box reads.
    test "serves the current cards as decklist text", %{conn: conn} do
      deck = deck("Iroh das Lontra")
      {:ok, _} = Decks.remove_card(deck, "Sol Ring")

      response = conn |> get(~p"/decks/#{deck.id}/lista.txt") |> response(200)

      assert response =~ "Commander:\n1 Nature's Lore"
      assert response =~ "4 Forest"
      refute response =~ "Sol Ring"
    end

    test "the filename is a filename, not the deck's name with spaces in it", %{conn: conn} do
      deck = deck("Iroh das Lontra — otimizado")

      conn = get(conn, ~p"/decks/#{deck.id}/lista.txt")

      assert [disposition] = Plug.Conn.get_resp_header(conn, "content-disposition")
      assert disposition == ~s(attachment; filename="iroh-das-lontra-otimizado.txt")
    end

    test "round-trips: what it serves, the importer reads back", %{conn: conn} do
      deck = deck("Ida e Volta")

      text = conn |> get(~p"/decks/#{deck.id}/lista.txt") |> response(200)

      {:ok, reimported} = Decks.import_from_text(text, %{name: "De Volta", source: :paste})

      assert Enum.sort(Enum.map(Decks.list_deck_cards(reimported), &{&1.card.name, &1.board})) ==
               Enum.sort(Enum.map(Decks.list_deck_cards(deck), &{&1.card.name, &1.board}))
    end
  end

  describe "the card count" do
    # Shown always, not only when it is wrong: a number that appears only when
    # broken cannot be used to check that things are fine.
    test "is on the header with its target", %{conn: conn} do
      deck = deck()

      {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

      assert html =~ "Cartas"
      assert html =~ "de 100"
    end

    test "an off-100 deck raises the legality finding too", %{conn: conn} do
      deck = deck()

      {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

      # The fixture deck is 6 cards, so the finding must be there.
      assert html =~ "O deck não tem 100 cartas"
      assert html =~ "legality.deck_size"
    end
  end

  describe "importing" do
    # Caught at the door, instead of after the round trip of importing,
    # reading the finding, and coming back to fix the paste.
    test "a paste that does not total 100 says so on arrival", %{conn: conn} do
      CatalogueFixture.seed!(~w(sol_ring forest))

      {:ok, live, _html} = live(conn, ~p"/importar")

      live
      |> form("form[phx-submit='paste']", paste: %{name: "Curto", decklist: "1 Sol Ring"})
      |> render_submit()

      assert {_path, flash} = assert_redirect(live)
      assert flash["info"] =~ "1 cartas em vez de 100"
    end
  end

  describe "editing the list" do
    # The list is where a deck gets fixed. Told it holds 105 cards, an owner
    # had no way to cut one without re-importing the whole thing.
    test "a card can be taken out from its own tile", %{conn: conn} do
      deck = deck()

      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

      live
      |> element("li button[phx-click='apply-cut'][phx-value-name='Sol Ring']")
      |> render_click()

      names = deck |> Decks.list_deck_cards() |> Enum.map(& &1.card.name)
      refute "Sol Ring" in names
    end

    test "a card can be typed in by name", %{conn: conn} do
      deck = deck()
      {:ok, _} = Decks.remove_card(deck, "Sol Ring")

      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

      live
      |> form("form[phx-submit='add-card']", card: %{name: "Sol Ring"})
      |> render_submit()

      names = deck |> Decks.list_deck_cards() |> Enum.map(& &1.card.name)
      assert "Sol Ring" in names
    end

    test "a blank name does nothing rather than erroring", %{conn: conn} do
      deck = deck()
      before = length(Decks.list_deck_cards(deck))

      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

      live |> form("form[phx-submit='add-card']", card: %{name: "   "}) |> render_submit()

      assert length(Decks.list_deck_cards(deck)) == before
    end

    # The section header is where the count is fixed, so it says the gap there.
    test "the list header names the gap to 100", %{conn: conn} do
      deck = deck()

      {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

      assert html =~ "As cartas"
      assert html =~ "de 100"
      assert html =~ "a menos"
    end
  end

  describe "what a legality finding offers" do
    # Legality is arithmetic against the rules, not a judgement call. Nothing a
    # model could say would change what has to happen, so offering to buy an
    # opinion on "your deck has 105 cards" spends money on a fact.
    test "the size finding points at the list instead of selling a consult", %{conn: conn} do
      deck = deck()

      {:ok, live, html} = live(conn, ~p"/decks/#{deck.id}")

      assert html =~ "Ajustar a lista"
      refute has_element?(live, "button[phx-value-code='legality.deck_size']")
    end

    test "an ordinary finding still offers the consult", %{conn: conn} do
      deck = deck()

      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

      assert has_element?(live, "button[phx-click='consult-finding']")
    end

    # Named as illegal and one click from gone: the finding says which cards
    # make it true, so each of them gets a button.
    test "an illegal card is removable from the finding that names it", %{conn: conn} do
      CatalogueFixture.seed!(~w(sol_ring natures_lore forest counterspell))

      {:ok, deck} =
        Decks.import_from_text(
          "Commander:\n1 Nature's Lore\n\nDeck:\n1 Sol Ring\n1 Counterspell\n4 Forest",
          %{name: "Fora da Identidade", source: :paste}
        )

      {:ok, live, html} = live(conn, ~p"/decks/#{deck.id}")

      assert html =~ "Cartas fora da identidade de cor"

      # Scoped to the finding: the card's own tile offers the same cut, and
      # both are legitimate ways to get rid of it.
      live
      |> element("button[phx-value-name='Counterspell']", "Tirar Counterspell")
      |> render_click()

      refute "Counterspell" in Enum.map(Decks.list_deck_cards(deck), & &1.card.name)
    end
  end
end
