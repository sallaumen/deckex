defmodule DeckexWeb.LaunchFormTest do
  @moduledoc """
  The form that authorises spending.

  A blank ceiling means "no ceiling" and always has. A *typo* used to mean
  exactly the same thing: `Integer.parse("abc")` fails, the parser answered
  `nil`, and the screen that commits twenty reais of model time quietly removed
  its own price limit — with nothing on screen to say it had.
  """
  use DeckexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Deckex.CatalogueFixture
  alias Deckex.Decks
  alias Deckex.Optimizations

  setup do
    CatalogueFixture.seed!(~w(sol_ring forest))

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n4 Forest", %{name: "Deck do Lançador", source: :paste})

    %{deck: deck}
  end

  defp open(conn, deck) do
    {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}/otimizacoes")
    live |> element("button[phx-click='abrir-lancador']") |> render_click()

    live
  end

  defp contract(overrides) do
    Map.merge(
      %{
        "bracket_max" => "3",
        "ceiling_card" => "",
        "ceiling_land" => "",
        "keep" => "",
        "matchups" => "",
        "notes" => "",
        "model" => "fable"
      },
      overrides
    )
  end

  describe "a ceiling that is not a number" do
    test "refuses the launch and says so under the field", %{conn: conn, deck: deck} do
      live = open(conn, deck)

      html =
        live
        |> form("#launch-form", contract: contract(%{"ceiling_card" => "abc"}))
        |> render_submit()

      assert html =~ "não é um valor em reais"
      assert html =~ ~s(id="launch-ceiling-card-error")
      # And nothing was spent.
      assert Optimizations.list_for_deck(deck.id) == []
    end

    test "names the field that is wrong, not the other one", %{conn: conn, deck: deck} do
      live = open(conn, deck)

      live
      |> form("#launch-form", contract: contract(%{"ceiling_land" => "duzentos"}))
      |> render_submit()

      assert has_element?(live, "#launch-ceiling-land[aria-invalid='true']")
      refute has_element?(live, "#launch-ceiling-card[aria-invalid='true']")
    end
  end

  describe "a blank ceiling" do
    # Blank has always meant "no ceiling". That must keep working, and must not
    # be confusable with the typo above.
    test "means no ceiling, and launches", %{conn: conn, deck: deck} do
      live = open(conn, deck)

      assert {:error, {:live_redirect, _to}} =
               live |> form("#launch-form", contract: contract(%{})) |> render_submit()

      assert [run] = Optimizations.list_for_deck(deck.id)
      assert run.contract["ceilings"]["card"] == nil
    end

    test "a real number is kept", %{conn: conn, deck: deck} do
      live = open(conn, deck)

      live
      |> form("#launch-form", contract: contract(%{"ceiling_card" => "400"}))
      |> render_submit()

      assert [run] = Optimizations.list_for_deck(deck.id)
      assert run.contract["ceilings"]["card"] == 400
    end
  end
end
