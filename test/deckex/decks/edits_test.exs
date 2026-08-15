defmodule Deckex.Decks.EditsTest do
  use Deckex.DataCase, async: true

  import Deckex.Factory

  alias Deckex.CatalogueFixture
  alias Deckex.Consults.Suggestion
  alias Deckex.Decks
  alias Deckex.Decks.DeckVersion
  alias Deckex.Decks.Edits
  alias Deckex.Decks.Versions

  defp deck do
    CatalogueFixture.seed!(~w(sol_ring forest natures_lore cultivate counterspell))

    {:ok, deck} =
      Decks.import_from_text("Commander:\n1 Nature's Lore\n\nDeck:\n1 Sol Ring\n4 Forest", %{
        name: "Deck Editado",
        source: :paste
      })

    deck
  end

  defp suggestion(action, name, reason) do
    %Suggestion{action: action, name: name, reason: reason, resolved?: true}
  end

  describe "what an edit records" do
    test "a hand edit is logged with no reason of its own" do
      deck = deck()
      {:ok, _} = Decks.add_card(deck, "Cultivate")

      assert [%{action: :add, card_name: "Cultivate", reason: nil}] = Edits.pending(deck)
    end

    test "an edit made for a reason keeps it" do
      deck = deck()
      {:ok, _} = Decks.remove_card(deck, "Sol Ring", reason: "lento demais")

      assert [%{action: :cut, reason: "lento demais"}] = Edits.pending(deck)
    end

    # The whole point of recording rather than diffing: a diff can say what
    # changed, never why.
    test "the version says why, not just what" do
      deck = deck()
      {:ok, _} = Decks.remove_card(deck, "Sol Ring", reason: "não faz nada aqui")
      {:ok, _} = Decks.add_card(deck, "Cultivate", reason: "rampa que fixa cor")

      {:ok, version} = Versions.mark(deck)

      assert Enum.map(DeckVersion.applied(version), &{&1["action"], &1["card"], &1["reason"]}) ==
               [
                 {"add", "Cultivate", "rampa que fixa cor"},
                 {"cut", "Sol Ring", "não faz nada aqui"}
               ]
    end

    test "an edit with no reason still reads as one" do
      deck = deck()
      {:ok, _} = Decks.add_card(deck, "Cultivate")

      {:ok, version} = Versions.mark(deck)

      assert [%{"reason" => "editado à mão"}] = DeckVersion.applied(version)
    end

    # A card put in and taken out again did not happen to the deck.
    test "the changelog is the net" do
      deck = deck()
      {:ok, _} = Decks.add_card(deck, "Cultivate")
      {:ok, _} = Decks.remove_card(deck, "Cultivate")

      {:ok, version} = Versions.mark(deck)

      assert DeckVersion.applied(version) == []
    end

    test "marking a version empties the pending list" do
      deck = deck()
      {:ok, _} = Decks.add_card(deck, "Cultivate")
      {:ok, _version} = Versions.mark(deck)

      assert Edits.pending(deck) == []
    end

    # Falling back is not a bug: the diff is always right about what changed,
    # which is what matters when nothing recorded the why.
    test "with nothing recorded, the version still says what changed" do
      deck = deck()
      {:ok, _} = Decks.add_card(deck, "Cultivate")
      :ok = Edits.clear(deck)

      {:ok, version} = Versions.mark(deck)

      assert [%{"action" => "add", "card" => "Cultivate"}] = DeckVersion.applied(version)
    end

    test "going back to a version forgets edits that described the old state" do
      deck = deck()
      {:ok, v1} = Versions.fetch(deck, 1)
      {:ok, _} = Decks.add_card(deck, "Cultivate")

      {:ok, restored} = Versions.restore(deck, v1)

      assert Edits.pending(restored) == []
    end
  end

  describe "apply_suggestions/3 — the punctual optimization" do
    test "applies the answer and marks one version for all of it" do
      deck = deck()
      consult = insert(:consult, deck: deck, status: :done)

      {:ok, result} =
        Decks.apply_suggestions(
          deck,
          [
            suggestion(:cut, "Sol Ring", "não faz nada aqui"),
            suggestion(:add, "Cultivate", "rampa que fixa cor")
          ],
          consult_id: consult.id,
          label: "Consulta: Só mana e aceleração"
        )

      assert result.applied == ["Sol Ring", "Cultivate"]
      assert result.failed == []

      names = result.deck |> Decks.list_deck_cards() |> Enum.map(& &1.card.name) |> Enum.sort()
      assert names == ["Cultivate", "Forest", "Nature's Lore"]

      assert result.version.origin == :consult
      assert result.version.consult_id == consult.id
      assert result.version.label == "Consulta: Só mana e aceleração"

      assert Enum.map(DeckVersion.applied(result.version), & &1["reason"]) == [
               "rampa que fixa cor",
               "não faz nada aqui"
             ]
    end

    # One wrong row is not a wrong answer, and refusing all twenty because of it
    # would be the app being pedantic with someone's money.
    test "a row that cannot be applied does not stop the others" do
      deck = deck()

      {:ok, result} =
        Decks.apply_suggestions(deck, [
          suggestion(:cut, "Counterspell", "nem está no deck"),
          suggestion(:add, "Cultivate", "rampa")
        ])

      assert result.applied == ["Cultivate"]
      assert [{"Counterspell", message}] = result.failed
      assert message =~ "Counterspell"
    end

    test "an unresolved suggestion is never applied" do
      deck = deck()

      {:ok, result} =
        Decks.apply_suggestions(deck, [
          %Suggestion{action: :add, name: "Carta Inventada", reason: "?", resolved?: false}
        ])

      assert result.applied == []
      assert result.version == nil
    end

    test "nothing applied means no version was invented" do
      deck = deck()
      before = length(Versions.list(deck))

      {:ok, result} = Decks.apply_suggestions(deck, [suggestion(:cut, "Counterspell", "não tem")])

      assert result.version == nil
      assert length(Versions.list(deck)) == before
    end
  end
end
