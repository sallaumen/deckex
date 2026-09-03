defmodule Deckex.LogTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Deckex.Log

  doctest Deckex.Log

  describe "fields/1" do
    test "a deck becomes its name and its id — the name is what a person reads" do
      fields = Log.fields(deck: %{id: "deck-1", name: "Rograkh"})

      assert fields[:deck] == "Rograkh"
      assert fields[:deck_id] == "deck-1"
    end

    test "a consult brings the lens and the model with it" do
      fields = Log.fields(consult: %{id: "c-1", lens: :plano, model: "opus"})

      assert fields == [consult_id: "c-1", lens: :plano, model: "opus"]
    end

    test "an optimization brings its mode" do
      assert Log.fields(optimization: %{id: "o-1", mode: :refine}) ==
               [optimization_id: "o-1", mode: :refine]
    end

    test "an unknown key passes through, so a one-off count needs no ceremony" do
      assert Log.fields(cards: 12) == [cards: 12]
    end

    test "an association nobody preloaded is dropped, not dumped" do
      # A permissive catch-all would put `%Ecto.Association.NotLoaded{}` on the
      # line — 60 characters of struct where a deck name should be.
      assert Log.fields(
               deck: %Ecto.Association.NotLoaded{
                 __field__: :deck,
                 __owner__: Deckex.Consults.Consult,
                 __cardinality__: :one
               }
             ) == []
    end

    test "a nil is dropped rather than printed as an empty value" do
      assert Log.fields(deck: nil, cards: 3) == [cards: 3]
    end
  end

  describe "context/1" do
    test "tags every later line in this process" do
      Log.context(deck: %{id: "deck-1", name: "Rograkh"})

      captured =
        capture_log([metadata: [:deck]], fn ->
          require Logger

          Logger.error("importou 100 cartas")
        end)

      assert captured =~ "deck=Rograkh"
      assert captured =~ "importou 100 cartas"
    end
  end

  describe "names/2" do
    test "a short list is just the list" do
      assert Log.names(["Sol Ring", "Cultivate"]) == "Sol Ring, Cultivate"
    end

    test "a long list is capped — a real import once printed 65 names on one line" do
      assert Log.names(Enum.map(1..65, &"Carta #{&1}")) ==
               "Carta 1, Carta 2, Carta 3, Carta 4, Carta 5 e mais 60"
    end

    test "an empty list says so instead of rendering as nothing" do
      assert Log.names([]) == "nenhuma"
    end
  end

  describe "duration/1" do
    test "reads at a glance across the ranges this app actually spans" do
      # A page render, a Scryfall round trip, and a pipeline stage.
      assert Log.duration(412) == "412ms"
      assert Log.duration(6231) == "6.2s"
      assert Log.duration(372_481) == "6m12s"
    end

    test "an unmeasured duration says so instead of claiming zero" do
      assert Log.duration(nil) == "?"
    end
  end
end
