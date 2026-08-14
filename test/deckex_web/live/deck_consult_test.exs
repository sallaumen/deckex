defmodule DeckexWeb.DeckConsultTest do
  use DeckexWeb.ConnCase, async: true

  import Mox
  import Phoenix.LiveViewTest

  alias Deckex.CatalogueFixture
  alias Deckex.Consults
  alias Deckex.Decks

  setup :verify_on_exit!

  setup do
    CatalogueFixture.seed!(~w(sol_ring forest counterspell))

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n1 Counterspell\n4 Forest", %{
        name: "Deck da Consulta",
        source: :paste
      })

    %{deck: deck}
  end

  test "every finding offers a consult", %{conn: conn, deck: deck} do
    {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

    assert live
           |> element("button[phx-value-code='interaction.no_board_wipes']")
           |> has_element?()
  end

  test "asking about a finding creates a scoped consult", %{conn: conn, deck: deck} do
    {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

    live
    |> element("button[phx-value-code='interaction.no_board_wipes']")
    |> render_click()

    assert [%{lens: :finding, finding_code: "interaction.no_board_wipes"}] =
             Consults.list_for_deck(deck)
  end

  test "the whole deck can be consulted at once", %{conn: conn, deck: deck} do
    {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

    live
    |> form("form[phx-submit='consult-full']", consult: %{lens: "full", model: "sonnet"})
    |> render_submit()

    assert [%{lens: :full}] = Consults.list_for_deck(deck)
  end

  test "a finished consult renders its cuts and adds", %{conn: conn, deck: deck} do
    {:ok, consult} = Consults.request(deck, :full)

    # run/1 pulls the suggested cards into the catalogue; the page then only reads.
    stub(Deckex.Scryfall.Mock, :fetch_by_names, fn _names ->
      {:ok, %{found: [Deckex.ScryfallFixture.load!("cultivate")], not_found: []}}
    end)

    expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts ->
      {:ok,
       %{
         "diagnosis" => "Falta interação nesse deck.",
         "cuts" => [%{"card" => "Sol Ring", "reason" => "exemplo de corte"}],
         "adds" => [%{"card" => "Cultivate", "reason" => "remoção barata"}]
       }}
    end)

    {:ok, _done} = Consults.run(consult)

    {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

    assert html =~ "Falta interação nesse deck."
    assert html =~ "Cultivate"
    assert html =~ "remoção barata"
  end

  test "the exact prompt is available to copy", %{conn: conn, deck: deck} do
    {:ok, _consult} = Consults.request(deck, :full)

    {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

    assert html =~ "Ver o prompt"
  end

  test "a consult's leitura renders above the diagnosis", %{conn: conn, deck: deck} do
    {:ok, consult} = Consults.request(deck, :full)

    stub(Deckex.Scryfall.Mock, :fetch_by_names, fn names ->
      {:ok, %{found: [], not_found: names}}
    end)

    expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts ->
      {:ok,
       %{
         "leitura" => "Leio um deck de spellslinger com fecho fraco.",
         "diagnosis" => "Falta fecho.",
         "cuts" => [],
         "adds" => []
       }}
    end)

    {:ok, _done} = Consults.run(consult)

    {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

    assert html =~ "Leio um deck de spellslinger com fecho fraco."
  end

  test "an old answer without leitura still renders", %{conn: conn, deck: deck} do
    {:ok, consult} = Consults.request(deck, :full)

    {:ok, _old} =
      consult
      |> Ecto.Changeset.change(%{
        status: :done,
        response: %{"diagnosis" => "Sem leitura, era outra época.", "cuts" => [], "adds" => []}
      })
      |> Deckex.Repo.update()

    {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

    assert html =~ "Sem leitura, era outra época."
  end

  test "a finished scout renders as a consult without crashing", %{conn: conn, deck: deck} do
    {:ok, consult} = Consults.request(deck, :scout)

    expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts ->
      {:ok,
       %{
         "plano" => "Ramp e cartas.",
         "sinergias" => "Sol Ring com tudo.",
         "linhas_de_vitoria" => "Valor.",
         "fraquezas" => "Nenhuma visível."
       }}
    end)

    {:ok, _done} = Consults.run(consult)

    {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

    assert html =~ "scout"
  end
end
