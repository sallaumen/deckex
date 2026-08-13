defmodule Deckex.Cards.CardTest do
  use Deckex.DataCase, async: true

  alias Deckex.Cards.Card

  defp valid_attrs do
    %{
      oracle_id: Ecto.UUID.generate(),
      scryfall_id: Ecto.UUID.generate(),
      name: "Sol Ring",
      name_normalized: "sol ring",
      mana_cost: "{1}",
      cmc: Decimal.new("1.0"),
      type_line: "Artifact",
      oracle_text: "{T}: Add {C}{C}.",
      layout: "normal",
      produced_mana: ["C"],
      commander_legal: true,
      fetched_at: DateTime.utc_now(:second)
    }
  end

  describe "changeset/2" do
    test "accepts a complete card" do
      assert %Ecto.Changeset{valid?: true} = Card.changeset(%Card{}, valid_attrs())
    end

    test "requires the identifying and structural fields" do
      errors = %Card{} |> Card.changeset(%{}) |> errors_on()

      for field <- [
            :oracle_id,
            :scryfall_id,
            :name,
            :name_normalized,
            :cmc,
            :type_line,
            :layout,
            :fetched_at
          ] do
        assert %{^field => ["can't be blank"]} = errors
      end
    end

    test "rejects a second card with the same oracle_id" do
      attrs = valid_attrs()
      assert {:ok, _card} = %Card{} |> Card.changeset(attrs) |> Repo.insert()

      duplicate =
        attrs
        |> Map.put(:name, "Sol Ring (reprint)")
        |> Map.put(:name_normalized, "sol ring reprint")
        |> Map.put(:scryfall_id, Ecto.UUID.generate())

      assert {:error, changeset} = %Card{} |> Card.changeset(duplicate) |> Repo.insert()
      assert %{oracle_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "rejects a second card with the same normalized name" do
      assert {:ok, _card} = %Card{} |> Card.changeset(valid_attrs()) |> Repo.insert()

      duplicate =
        valid_attrs()
        |> Map.put(:oracle_id, Ecto.UUID.generate())
        |> Map.put(:scryfall_id, Ecto.UUID.generate())

      assert {:error, changeset} = %Card{} |> Card.changeset(duplicate) |> Repo.insert()
      assert %{name_normalized: ["has already been taken"]} = errors_on(changeset)
    end

    test "stores double-faced card faces as a list of maps" do
      attrs =
        valid_attrs()
        |> Map.put(:layout, "modal_dfc")
        |> Map.put(:card_faces, [
          %{"name" => "Agadeem's Awakening", "mana_cost" => "{X}{B}{B}{B}"},
          %{"name" => "Agadeem, the Undercrypt", "mana_cost" => ""}
        ])

      assert {:ok, card} = %Card{} |> Card.changeset(attrs) |> Repo.insert()
      assert [%{"name" => "Agadeem's Awakening"}, %{"name" => _back}] = card.card_faces
    end
  end

  describe "basic_land?/1" do
    test "a basic land is one" do
      assert Card.basic_land?(%Card{type_line: "Basic Land — Forest"})
    end

    test "a snow-covered basic is still one" do
      assert Card.basic_land?(%Card{type_line: "Basic Snow Land — Island"})
    end

    test "a nonbasic land is not" do
      refute Card.basic_land?(%Card{type_line: "Land — Forest Island"})
    end

    test "a card with no type line is not" do
      refute Card.basic_land?(%Card{type_line: nil})
    end
  end

  describe "any_number_allowed?/1" do
    # Read from the card's own text, so the next set that prints one of these
    # needs no code change.
    test "a card whose text lifts the singleton rule says so" do
      assert Card.any_number_allowed?(%Card{
               oracle_text: "A deck can have any number of cards named Relentless Rats."
             })
    end

    test "an ordinary card does not" do
      refute Card.any_number_allowed?(%Card{oracle_text: "Counter target spell."})
    end

    test "a card with no text does not" do
      refute Card.any_number_allowed?(%Card{oracle_text: nil})
    end
  end
end
