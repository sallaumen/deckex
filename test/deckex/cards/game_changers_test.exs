defmodule Deckex.Cards.GameChangersTest do
  @moduledoc """
  The Game Changers list is the Commander Format Panel's, revised a few times
  a year. deckex asks for it; it never writes it down.
  """
  use Deckex.DataCase, async: true

  import Mox

  alias Deckex.Cards
  alias Deckex.CatalogueFixture

  setup :verify_on_exit!

  defp scryfall_card(card), do: %{"oracle_id" => card.oracle_id}

  test "marks the cards the panel currently lists" do
    cards = CatalogueFixture.seed!(~w(sol_ring rhystic_study))
    # The committed fixture for Rhystic Study already carries the flag, since
    # Scryfall puts it on the card object — so the interesting card here is
    # Sol Ring, which must stay unmarked through a refresh that omits it.
    refute Cards.get_by_name("Sol Ring").game_changer

    expect(Deckex.Scryfall.Mock, :search, fn "is:gamechanger" ->
      {:ok, [scryfall_card(Enum.find(cards, &(&1.name == "Rhystic Study")))]}
    end)

    assert {:ok, %{marked: 1}} = Cards.refresh_game_changers()

    assert Cards.get_by_name("Rhystic Study").game_changer
    refute Cards.get_by_name("Sol Ring").game_changer
  end

  # A restriction that outlives its own list is worse than no restriction,
  # because it still looks authoritative.
  test "unmarks a card the panel dropped" do
    cards = CatalogueFixture.seed!(~w(sol_ring rhystic_study))
    rhystic = Enum.find(cards, &(&1.name == "Rhystic Study"))

    expect(Deckex.Scryfall.Mock, :search, fn _query -> {:ok, [scryfall_card(rhystic)]} end)
    {:ok, _} = Cards.refresh_game_changers()
    assert Cards.get_by_name("Rhystic Study").game_changer

    expect(Deckex.Scryfall.Mock, :search, fn _query -> {:ok, []} end)
    assert {:ok, %{marked: 0}} = Cards.refresh_game_changers()

    refute Cards.get_by_name("Rhystic Study").game_changer
  end

  test "a Scryfall failure leaves the catalogue as it was" do
    CatalogueFixture.seed!(~w(sol_ring))

    expect(Deckex.Scryfall.Mock, :search, fn _query ->
      {:error, Deckex.Error.new(:scryfall_unavailable, "caiu")}
    end)

    assert {:error, %Deckex.Error{code: :scryfall_unavailable}} = Cards.refresh_game_changers()
    refute Cards.get_by_name("Sol Ring").game_changer
  end
end
