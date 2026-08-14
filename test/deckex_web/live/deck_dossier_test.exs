defmodule DeckexWeb.DeckDossierTest do
  use DeckexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Deckex.CatalogueFixture
  alias Deckex.Consults
  alias Deckex.Decks

  @dossier %{
    "plano" => "Spellslinger Temur.",
    "sinergias" => "Iroh dá flashback às Lessons.",
    "linhas_de_vitoria" => "Storm Kiln Artist.",
    "fraquezas" => "Cemitério é tudo."
  }

  setup do
    CatalogueFixture.seed!(~w(sol_ring forest))

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n4 Forest", %{name: "Deck do Dossiê", source: :paste})

    %{deck: deck}
  end

  test "without a dossier, the card offers to generate one", %{conn: conn, deck: deck} do
    {:ok, live, html} = live(conn, ~p"/decks/#{deck.id}")

    assert html =~ "Dossiê"
    assert html =~ "Gerar dossiê"

    live |> element("button[phx-click='gerar-dossie']") |> render_click()

    assert Enum.any?(Consults.list_for_deck(deck), &(&1.lens == :scout))
  end

  test "with a dossier, the four fields render with their source", %{conn: conn, deck: deck} do
    {:ok, _deck} = Decks.put_dossier(deck, @dossier)

    {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

    assert html =~ "Iroh dá flashback às Lessons."
    assert html =~ "escrito pelo scout"
    refute html =~ "desatualizado"
  end

  test "a stale dossier wears the badge", %{conn: conn, deck: deck} do
    {:ok, deck} = Decks.put_dossier(deck, @dossier)
    {:ok, _card} = Decks.add_card(deck, "Forest")

    {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

    assert html =~ "desatualizado"
  end

  test "editing the dossier makes it the owner's", %{conn: conn, deck: deck} do
    {:ok, _deck} = Decks.put_dossier(deck, @dossier)

    {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

    html =
      live
      |> form("#dossier-form", dossier: %{@dossier | "plano" => "Plano meu."})
      |> render_submit()

    assert html =~ "editado por você"

    {:ok, fresh} = Decks.fetch_deck(deck.id)
    assert fresh.dossier["plano"] == "Plano meu."
    assert fresh.dossier_source == :manual
  end

  # Guards the PubSub round-trip: scout finishes → event → page re-reads →
  # dossier renders, no navigation. Deterministically fails if the final
  # broadcast in Consults.succeed/3 is ever removed. The *ordering* half of
  # the bug this came from — the event once fired before the dossier was
  # written — is a race no test can pin down; it is enforced structurally in
  # succeed/3 (persist first, broadcast last) with a comment saying why.
  test "a finished scout appears on the page without a reload", %{conn: conn, deck: deck} do
    {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

    live |> element("button[phx-click='gerar-dossie']") |> render_click()
    [consult] = Consults.list_for_deck(deck)

    Mox.expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts -> {:ok, @dossier} end)
    {:ok, _done} = Deckex.Consults.run(consult)

    # The LiveView processed the PubSub events; no navigation happened.
    html = render(live)

    assert html =~ "escrito pelo scout"
    assert html =~ "Spellslinger Temur."
  end

  test "re-running over a manual dossier asks first", %{conn: conn, deck: deck} do
    {:ok, deck} = Decks.put_dossier(deck, @dossier)
    {:ok, _deck} = Decks.edit_dossier(deck, @dossier)

    {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

    assert live
           |> element("button[phx-click='gerar-dossie'][data-confirm]")
           |> has_element?()
  end
end
