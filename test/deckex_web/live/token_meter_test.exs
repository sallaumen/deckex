defmodule DeckexWeb.TokenMeterTest do
  use DeckexWeb.ConnCase, async: true

  import Deckex.Factory
  import Phoenix.LiveViewTest

  alias Deckex.AI.Ledger
  alias Deckex.AI.Usage
  alias Deckex.CatalogueFixture
  alias Deckex.Decks

  defp deck(name \\ "Deck Medido") do
    CatalogueFixture.seed!(~w(sol_ring forest))

    {:ok, deck} = Decks.import_from_text("1 Sol Ring\n4 Forest", %{name: name, source: :paste})

    deck
  end

  defp usage do
    %Usage{
      input_tokens: 2,
      output_tokens: 4,
      cache_creation_tokens: 10_665,
      cache_read_tokens: 19_242,
      cost_usd: Decimal.new("0.116381"),
      duration_ms: 2885
    }
  end

  describe "the global meter" do
    test "A Mesa carries what the app has spent", %{conn: conn} do
      deck = deck()
      :ok = Ledger.record(usage(), kind: :consult, deck_id: deck.id)

      {:ok, _live, html} = live(conn, ~p"/")

      assert html =~ "Gasto com IA"
      assert html =~ "29,9 k tokens"
    end

    # A row of zeros looks exactly like a measurement.
    test "an app that has never asked anything shows no meter", %{conn: conn} do
      deck()

      {:ok, _live, html} = live(conn, ~p"/")

      refute html =~ "Gasto com IA"
    end

    test "each deck carries its own spend on the table", %{conn: conn} do
      deck = deck("Deck Caro")
      :ok = Ledger.record(usage(), kind: :consult, deck_id: deck.id)

      {:ok, _live, html} = live(conn, ~p"/")

      assert html =~ "em IA"
    end
  end

  describe "the per-deck meter" do
    test "the deck page counts only its own calls", %{conn: conn} do
      mine = deck("Meu")
      other = deck("Outro")

      :ok = Ledger.record(usage(), kind: :consult, deck_id: mine.id)
      :ok = Ledger.record(usage(), kind: :consult, deck_id: other.id)
      :ok = Ledger.record(usage(), kind: :consult, deck_id: other.id)

      {:ok, _live, html} = live(conn, ~p"/decks/#{mine.id}")

      assert html =~ "Gasto com IA"
      assert html =~ "1 chamada(s)"
    end

    test "a deck that never asked anything shows no meter", %{conn: conn} do
      deck = deck()

      {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

      refute html =~ "Gasto com IA"
    end

    test "an answer carries what that answer cost", %{conn: conn} do
      deck = deck()
      consult = insert(:consult, deck: deck, status: :done, response: %{"diagnosis" => "ok"})

      :ok = Ledger.record(usage(), kind: :consult, deck_id: deck.id, consult_id: consult.id)

      {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

      assert html =~ "R$"
      assert html =~ "29913 tokens"
    end
  end

  describe "reading a count" do
    test "at the scale a person reads" do
      assert DeckexWeb.UI.token_count(940) == "940"
      assert DeckexWeb.UI.token_count(29_913) == "29,9 k"
      assert DeckexWeb.UI.token_count(1_240_000) == "1,2 M"
    end
  end
end
