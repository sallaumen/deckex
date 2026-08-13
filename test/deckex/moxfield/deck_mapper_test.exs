defmodule Deckex.Moxfield.DeckMapperTest do
  use ExUnit.Case, async: true

  alias Deckex.Decks.DecklistParser
  alias Deckex.Error
  alias Deckex.Moxfield.DeckMapper

  defp fixture do
    "test/support/fixtures/moxfield/deck.json" |> File.read!() |> Jason.decode!()
  end

  describe "to_decklist/1" do
    test "reads the deck name" do
      assert {:ok, %{name: "Iroh das Lontra"}} = DeckMapper.to_decklist(fixture())
    end

    test "emits a decklist the parser can read back" do
      assert {:ok, %{decklist: decklist}} = DeckMapper.to_decklist(fixture())
      assert {:ok, entries} = DecklistParser.parse(decklist)

      by_name = Map.new(entries, &{&1.name, &1})

      assert %{quantity: 1, board: :commander} = by_name["Iroh, Grand Lotus"]
      assert %{quantity: 4, board: :main} = by_name["Forest"]
      assert %{quantity: 1, board: :maybe} = by_name["Cultivate"]
    end

    test "falls back to a placeholder name" do
      payload = %{"boards" => %{"mainboard" => %{"cards" => %{}}}}

      assert {:ok, %{name: "Deck sem nome"}} = DeckMapper.to_decklist(payload)
    end

    test "rejects a payload with no boards" do
      assert {:error, %Error{code: :moxfield_not_found}} =
               DeckMapper.to_decklist(%{"name" => "x"})
    end
  end
end
