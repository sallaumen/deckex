defmodule DeckexWeb.DeckSpendingTest do
  @moduledoc """
  A consult costs real money and takes three to four minutes. Every control
  that starts one has to make a double click impossible — not merely unlikely.
  """
  use DeckexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Deckex.CatalogueFixture
  alias Deckex.Consults
  alias Deckex.Decks

  setup do
    CatalogueFixture.seed!(~w(sol_ring forest))

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n4 Forest", %{name: "Deck Caro", source: :paste})

    %{deck: deck}
  end

  # The scout is already safe by construction: once one is pending the button
  # is replaced by "scout lendo o deck…", so there is nothing left to click.
  test "the scout button leaves the page while a scout is running", %{conn: conn, deck: deck} do
    {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

    html = render_click(element(live, "button[phx-click='gerar-dossie']"))

    refute html =~ "phx-click=\"gerar-dossie\""
    assert html =~ "scout lendo o deck"
  end

  # Comparing is the most expensive click in the app — four consults at once.
  # Two layers guard it, and both are tested: the button goes disabled (below),
  # and the server refuses the event even when it arrives anyway — which is
  # what a stale tab or a replayed click actually does.
  test "a second comparison event is refused by the server, not just the button",
       %{conn: conn, deck: deck} do
    {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

    render_click(element(live, "button[phx-click='compare-models']"))
    render_click(live, "compare-models", %{})

    assert length(Consults.list_for_deck(deck)) == length(Consults.models())
  end

  # The control says it is unavailable for as long as it is unavailable —
  # a toast would have said it once and vanished.
  test "the compare button goes disabled while a consult runs", %{conn: conn, deck: deck} do
    {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

    html = render_click(element(live, "button[phx-click='compare-models']"))

    assert html =~ ~r/phx-click="compare-models"[^>]*disabled/s
    assert html =~ "Espere a consulta que já está rodando terminar."
  end

  test "asking a normal consult while one runs is still allowed", %{conn: conn, deck: deck} do
    {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

    form =
      form(live, "form[phx-submit='consult-full']", consult: %{lens: "full", model: "sonnet"})

    render_submit(form)
    render_submit(form)

    # Two different questions are the owner's business; only the four-at-once
    # comparison is guarded.
    assert length(Consults.list_for_deck(deck)) == 2
  end

  # The client-side half: LiveView swaps the label and disables the control
  # for the round trip, so the button cannot be hammered before the server
  # has answered.
  test "every control that spends money says so while it works", %{conn: conn, deck: deck} do
    {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

    for control <- ["gerar-dossie", "compare-models"] do
      assert html =~ ~r/phx-click="#{control}"[^>]*phx-disable-with/s or
               html =~ ~r/phx-disable-with[^>]*phx-click="#{control}"/s,
             "#{control} pode ser clicado duas vezes antes do servidor responder"
    end

    assert html =~ "phx-disable-with"
  end
end
