defmodule Deckex.Cards.ScryfallMapperTest do
  use ExUnit.Case, async: true

  alias Deckex.Cards.Card
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.ScryfallFixture

  describe "to_attrs/1 on a normal card" do
    setup do
      %{attrs: "sol_ring" |> ScryfallFixture.load!() |> ScryfallMapper.to_attrs()}
    end

    test "maps identity and cost", %{attrs: attrs} do
      assert attrs.name == "Sol Ring"
      assert attrs.name_normalized == "sol ring"
      assert attrs.mana_cost == "{1}"
      assert Decimal.equal?(attrs.cmc, Decimal.new("1"))
      assert attrs.type_line == "Artifact"
      assert attrs.layout == "normal"
    end

    test "maps the mana it produces", %{attrs: attrs} do
      assert attrs.produced_mana == ["C"]
    end

    test "maps commander legality and the EDHREC rank", %{attrs: attrs} do
      assert attrs.commander_legal == true
      assert is_integer(attrs.edhrec_rank)
    end

    test "maps images from the top level", %{attrs: attrs} do
      assert attrs.image_normal_url =~ "scryfall"
      assert attrs.image_art_crop_url =~ "scryfall"
    end

    test "produces attributes a Card changeset accepts", %{attrs: attrs} do
      assert %Ecto.Changeset{valid?: true} = Card.changeset(%Card{}, attrs)
    end
  end

  describe "to_attrs/1 on a land with an empty mana cost" do
    test "normalizes the empty string to nil" do
      attrs = "command_tower" |> ScryfallFixture.load!() |> ScryfallMapper.to_attrs()

      assert attrs.mana_cost == nil
      assert attrs.type_line == "Land"
      assert Enum.sort(attrs.produced_mana) == ["B", "G", "R", "U", "W"]
    end
  end

  describe "to_attrs/1 on a card whose ramp is invisible to produced_mana" do
    test "keeps the oracle text that is the only ramp signal" do
      attrs = "cultivate" |> ScryfallFixture.load!() |> ScryfallMapper.to_attrs()

      assert attrs.produced_mana == []
      assert attrs.oracle_text =~ "Search your library"
      assert attrs.oracle_text =~ "onto the battlefield"
    end
  end

  describe "to_attrs/1 on a modal double-faced card" do
    setup do
      %{attrs: "agadeems_awakening" |> ScryfallFixture.load!() |> ScryfallMapper.to_attrs()}
    end

    test "takes the mana cost from the front face, since the top level has none",
         %{attrs: attrs} do
      assert attrs.mana_cost == "{X}{B}{B}{B}"
    end

    test "takes colors from the front face, since the top level has none", %{attrs: attrs} do
      assert attrs.colors == ["B"]
    end

    test "takes images from the front face, since the top level has none", %{attrs: attrs} do
      assert attrs.image_normal_url =~ "scryfall"
      assert attrs.image_art_crop_url =~ "scryfall"
    end

    test "keeps cmc, type_line and produced_mana from the top level", %{attrs: attrs} do
      assert Decimal.equal?(attrs.cmc, Decimal.new("3"))
      assert attrs.type_line == "Sorcery // Land"
      assert attrs.produced_mana == ["B"]
    end

    test "normalizes the name to the front face only", %{attrs: attrs} do
      assert attrs.name_normalized == "agadeem's awakening"
    end

    test "retains both faces for later analysis", %{attrs: attrs} do
      assert [%{"name" => "Agadeem's Awakening"}, %{"name" => "Agadeem, the Undercrypt"}] =
               attrs.card_faces
    end

    test "produces attributes a Card changeset accepts", %{attrs: attrs} do
      assert %Ecto.Changeset{valid?: true} = Card.changeset(%Card{}, attrs)
    end
  end

  describe "to_attrs/1 price handling" do
    test "maps the USD price as a decimal and stamps when it was read" do
      attrs = "cultivate" |> ScryfallFixture.load!() |> ScryfallMapper.to_attrs()

      assert %Decimal{} = attrs.price_usd
      assert %DateTime{} = attrs.prices_updated_at
    end

    # The printing a name lookup answers with is often the newest one, which on
    # release day has no price in any currency. Four staples sat in this
    # catalogue with an em dash for exactly this reason.
    test "a printing Scryfall has not priced yet maps to no price, not to zero" do
      attrs = "steam_vents" |> ScryfallFixture.load!() |> ScryfallMapper.to_attrs()

      assert attrs.price_usd == nil
    end
  end

  describe "cheapest_usd/1" do
    test "picks the lowest priced printing" do
      printings = [priced("32.65"), priced("10.67"), priced("15.65")]

      assert Decimal.equal?(ScryfallMapper.cheapest_usd(printings), Decimal.new("10.67"))
    end

    test "skips unpriced printings instead of counting them as free" do
      printings = [unpriced(), priced("10.67"), unpriced()]

      assert Decimal.equal?(ScryfallMapper.cheapest_usd(printings), Decimal.new("10.67"))
    end

    test "no priced printing at all is nil, which the caller reads as leave it alone" do
      assert ScryfallMapper.cheapest_usd([unpriced(), unpriced()]) == nil
      assert ScryfallMapper.cheapest_usd([]) == nil
    end

    test "compares by value, not by how the number was written" do
      assert Decimal.equal?(
               ScryfallMapper.cheapest_usd([priced("9.90"), priced("10.00")]),
               Decimal.new("9.90")
             )
    end

    defp priced(usd), do: %{"prices" => %{"usd" => usd, "usd_foil" => "99.00"}}
    defp unpriced, do: %{"prices" => %{"usd" => nil, "usd_foil" => "99.00"}}
  end
end
