defmodule DeckexWeb.FlashVisibilityTest do
  @moduledoc """
  A guard for a whole class of silent failure.

  `flash_group/1` lived in `Layouts.app`, which nothing in this app renders —
  so for weeks every `put_flash` in the codebase went nowhere: refusals,
  confirmations and errors alike. A message the user cannot see is the same as
  no message, and nothing failed loudly enough to notice it.

  The fix lives in the ROOT layout, which every page goes through. This test
  fails if it ever leaves again.
  """
  use DeckexWeb.ConnCase, async: true

  import Mox
  import Phoenix.LiveViewTest

  alias Deckex.CatalogueFixture
  alias Deckex.Decks
  alias Deckex.Optimizations

  setup :verify_on_exit!

  defp deck do
    CatalogueFixture.seed!(~w(sol_ring forest))

    stub(Deckex.Scryfall.Mock, :fetch_by_names, fn names ->
      {:ok, %{found: [], not_found: names}}
    end)

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n4 Forest", %{name: "Deck do Flash", source: :paste})

    deck
  end

  test "the flash container is on every page", %{conn: conn} do
    deck = deck()

    for path <- ["/", "/importar", "/ajustes", "/decks/#{deck.id}"] do
      {:ok, _live, html} = live(conn, path)

      assert html =~ ~s(id="flash-group"), "sem container de flash em #{path}"
    end
  end

  test "a refusal a LiveView puts in the flash reaches the screen", %{conn: conn} do
    deck = deck()

    {:ok, _running} =
      Optimizations.start(deck, %{}, [
        %{"kind" => "execucao", "lens" => "execucao", "label" => "Mana"}
      ])

    {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}/otimizacoes")
    live |> element("button[phx-click='abrir-lancador']") |> render_click()

    html =
      live
      |> form("#launch-form",
        contract: %{
          "bracket_max" => "3",
          "ceiling_card" => "",
          "ceiling_land" => "",
          "keep" => "",
          "matchups" => "",
          "notes" => "",
          "model" => "fable"
        }
      )
      |> render_submit()

    assert html =~ "Já tem uma otimização em andamento"
  end
end
