defmodule Deckex.Optimizations.SandboxTest do
  use Deckex.DataCase, async: true

  alias Deckex.CatalogueFixture
  alias Deckex.Decks
  alias Deckex.Decks.DecklistParser
  alias Deckex.Optimizations
  alias Deckex.Optimizations.Optimization

  defp deck do
    CatalogueFixture.seed!(~w(sol_ring forest counterspell cultivate))

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n4 Forest", %{name: "Sandbox", source: :paste})

    deck
  end

  describe "list_from_deck/1" do
    test "reads the main board with quantities" do
      %{list: list, commanders: commanders} = Optimizations.list_from_deck(deck())

      assert Enum.sort_by(list, & &1["name"]) == [
               %{"name" => "Forest", "quantity" => 4},
               %{"name" => "Sol Ring", "quantity" => 1}
             ]

      assert commanders == []
    end
  end

  describe "apply_changes_to_list/2" do
    @list [%{"name" => "Sol Ring", "quantity" => 1}, %{"name" => "Forest", "quantity" => 4}]

    test "an add inserts a new card at quantity 1" do
      result =
        Optimizations.apply_changes_to_list(@list, [%{"action" => "add", "card" => "Cultivate"}])

      assert %{"name" => "Cultivate", "quantity" => 1} in result
    end

    test "an add of a present card bumps its quantity" do
      result =
        Optimizations.apply_changes_to_list(@list, [%{"action" => "add", "card" => "Forest"}])

      assert %{"name" => "Forest", "quantity" => 5} in result
    end

    test "a cut decrements, removing at zero" do
      changes = [
        %{"action" => "cut", "card" => "Forest"},
        %{"action" => "cut", "card" => "Sol Ring"}
      ]

      result = Optimizations.apply_changes_to_list(@list, changes)

      assert %{"name" => "Forest", "quantity" => 3} in result
      refute Enum.any?(result, &(&1["name"] == "Sol Ring"))
    end
  end

  describe "snapshot_for/3" do
    test "builds entries with quantities and roles from the catalogue" do
      deck = deck()

      # In the real pipeline an added card is classified when the consult's
      # answer is catalogued; mirror that here so the roles exist to read.
      {:ok, _roles} = Deckex.Cards.classify_card(Deckex.Cards.get_by_name("Counterspell"))

      list = [
        %{"name" => "Sol Ring", "quantity" => 1},
        %{"name" => "Counterspell", "quantity" => 1}
      ]

      snapshot = Optimizations.snapshot_for(list, [], deck)

      names = Enum.map(snapshot.main, & &1.card.name) |> Enum.sort()
      assert names == ["Counterspell", "Sol Ring"]

      counterspell = Enum.find(snapshot.main, &(&1.card.name == "Counterspell"))
      assert MapSet.member?(counterspell.roles, :counter)
    end

    test "a card missing from the catalogue is skipped, like import does" do
      snapshot =
        Optimizations.snapshot_for([%{"name" => "Carta Ignota", "quantity" => 1}], [], deck())

      assert snapshot.main == []
    end
  end

  describe "list_to_text/2" do
    # The whole point: any sandbox state must become a real deck on demand.
    test "round-trips through the importer" do
      deck = deck()
      list = [%{"name" => "Sol Ring", "quantity" => 1}, %{"name" => "Forest", "quantity" => 3}]

      text = Optimizations.list_to_text(list, [])
      {:ok, imported} = Decks.import_from_text(text, %{name: "Fork", source: :paste})
      snapshot = Decks.snapshot(imported)

      counts = snapshot.main |> Enum.map(&{&1.card.name, &1.quantity}) |> Enum.sort()
      assert counts == [{"Forest", 3}, {"Sol Ring", 1}]
      assert deck.id != imported.id
    end

    test "commanders come first, in the section the parser reads" do
      text =
        Optimizations.list_to_text([%{"name" => "Forest", "quantity" => 2}], ["Iroh, Grand Lotus"])

      assert text =~ "Commander:\n1 Iroh, Grand Lotus"

      {:ok, entries} = DecklistParser.parse(text)

      assert %{board: :commander, name: "Iroh, Grand Lotus"} =
               Enum.find(entries, &(&1.board == :commander))
    end
  end

  describe "sandbox_size/2" do
    # The bug this exists to not have: the sandbox list is the main board and
    # commanders live in their own field, so every "Cartas 100/100" the run
    # page printed meant a deck of 101. The reference deck finished a whole
    # eight-stage run one card over legal, and nothing anywhere said so.
    test "counts the commanders, because the hundred-card rule does" do
      run = %Optimization{commanders: ["Iroh, Grand Lotus"], contract: %{}}
      list = [%{"name" => "Forest", "quantity" => 99}]

      assert Optimizations.card_count(list) == 99
      assert Optimizations.sandbox_size(run, list) == 100
    end

    test "a partner pair counts as two" do
      run = %Optimization{commanders: ["Frodo, Adventurous Hobbit", "Sam"], contract: %{}}
      list = [%{"name" => "Forest", "quantity" => 98}]

      assert Optimizations.sandbox_size(run, list) == 100
    end

    test "a list with no commander is its own size" do
      run = %Optimization{commanders: [], contract: %{}}

      assert Optimizations.sandbox_size(run, [%{"name" => "Forest", "quantity" => 100}]) == 100
    end
  end
end
