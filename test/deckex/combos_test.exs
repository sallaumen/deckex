defmodule Deckex.CombosTest do
  @moduledoc """
  What this deck's cards do *together*.

  Every measurement in this app reads one card at a time, and that is exactly
  how a stage cut Sam, Loyal Attendant: alone she is a 2/4 nobody plays, and
  the line she makes with Prize Pig lives in neither card's text nor either
  card's rank. Commander Spellbook is the one source that answers "what do
  these do together" as a fact rather than as an inference — and unlike the
  site the EDHREC law is about, it publishes an API for exactly this.
  """
  use Deckex.DataCase, async: true

  import Mox

  alias Deckex.Analysis
  alias Deckex.AnalysisFixture
  alias Deckex.CatalogueFixture
  alias Deckex.Combos
  alias Deckex.Consults.Briefing
  alias Deckex.Decks
  alias Deckex.Error

  setup :verify_on_exit!

  defp deck do
    CatalogueFixture.seed!(~w(sol_ring forest cultivate))

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n1 Cultivate\n4 Forest", %{
        name: "Deck dos Combos",
        source: :paste
      })

    deck
  end

  defp combo(cards, produces, opts \\ []) do
    %{
      "id" => Keyword.get(opts, :id, "1"),
      "uses" => Enum.map(cards, &%{"card" => %{"name" => &1}}),
      "produces" => Enum.map(produces, &%{"feature" => %{"name" => &1}}),
      "description" => "Faça isso, depois aquilo.",
      "notablePrerequisites" => Keyword.get(opts, :needs, [])
    }
  end

  describe "asking what this list does" do
    test "stores the combos the deck already assembles" do
      deck = deck()

      expect(Deckex.Spellbook.Mock, :find_combos, fn _main, _commanders ->
        {:ok, %{included: [combo(["Sol Ring", "Cultivate"], ["Mana infinita"])], almost: []}}
      end)

      {:ok, saved} = Combos.refresh(deck)

      assert [%{"cards" => ["Sol Ring", "Cultivate"], "produces" => ["Mana infinita"]}] =
               Combos.for_deck(saved)["assembled"]

      assert saved.combos_updated_at != nil
      refute saved.combos_stale
    end

    # The endpoint says "one card away" without saying which card, so the app
    # works it out. A suggestion the owner has to reverse-engineer is one he
    # will not use.
    test "names the missing card on an almost-combo" do
      deck = deck()

      expect(Deckex.Spellbook.Mock, :find_combos, fn _main, _commanders ->
        {:ok,
         %{
           included: [],
           almost: [combo(["Sol Ring", "Basalt Monolith"], ["Mana infinita"])]
         }}
      end)

      {:ok, saved} = Combos.refresh(deck)

      assert [%{"missing" => "Basalt Monolith"}] = Combos.for_deck(saved)["one_card_away"]
    end

    test "drops an almost-combo the deck is two cards from" do
      deck = deck()

      expect(Deckex.Spellbook.Mock, :find_combos, fn _main, _commanders ->
        {:ok,
         %{
           included: [],
           almost: [combo(["Sol Ring", "Basalt Monolith", "Rings of Brighthearth"], ["X"])]
         }}
      end)

      {:ok, saved} = Combos.refresh(deck)

      assert Combos.for_deck(saved)["one_card_away"] == []
    end

    # A combo list from yesterday describes the deck better than an empty one.
    test "a failed request keeps what the deck already had" do
      deck = deck()

      expect(Deckex.Spellbook.Mock, :find_combos, fn _main, _commanders ->
        {:ok, %{included: [combo(["Sol Ring", "Cultivate"], ["Mana infinita"])], almost: []}}
      end)

      {:ok, saved} = Combos.refresh(deck)

      expect(Deckex.Spellbook.Mock, :find_combos, fn _main, _commanders ->
        {:error, Error.new(:spellbook_unavailable, "caiu")}
      end)

      assert {:error, %Error{code: :spellbook_unavailable}} = Combos.refresh(saved)

      {:ok, untouched} = Decks.fetch_deck(saved.id)
      assert length(Combos.for_deck(untouched)["assembled"]) == 1
    end

    # Twelve of his cards produced twenty-four almost-combos, several of them
    # the same missing card twice. He buys a card, not a combo.
    test "one line per card to add, keeping the line that produces the most" do
      deck = deck()

      expect(Deckex.Spellbook.Mock, :find_combos, fn _main, _commanders ->
        {:ok,
         %{
           included: [],
           almost: [
             combo(["Sol Ring", "Basalt Monolith"], ["Mana infinita"], id: "1"),
             combo(["Cultivate", "Basalt Monolith"], ["Mana infinita", "Saque infinito"], id: "2")
           ]
         }}
      end)

      {:ok, saved} = Combos.refresh(deck)

      assert [%{"missing" => "Basalt Monolith", "produces" => produces}] =
               Combos.for_deck(saved)["one_card_away"]

      assert length(produces) == 2
    end

    # An app that trims a list and does not say so has told the reader there
    # were twenty when there were ninety.
    test "a trimmed list carries the number it was trimmed from" do
      deck = deck()

      many =
        for i <- 1..25 do
          combo(["Sol Ring", "Peça #{i}"], ["Mana infinita"], id: to_string(i))
        end

      expect(Deckex.Spellbook.Mock, :find_combos, fn _main, _commanders ->
        {:ok, %{included: [], almost: many}}
      end)

      {:ok, saved} = Combos.refresh(deck)
      combos = Combos.for_deck(saved)

      assert length(combos["one_card_away"]) == 20
      assert combos["one_card_away_total"] == 25
    end

    # The live API answers `notablePrerequisites` as a prose string while the
    # schema page reads like a list. The first real request crashed on it, and
    # the mock had been lying with a list this whole time.
    test "prerequisites survive arriving as prose instead of a list" do
      deck = deck()

      prose =
        combo(["Sol Ring", "Cultivate"], ["Mana infinita"])
        |> Map.put("notablePrerequisites", "Sol Ring não está enjoado.\nVocê tem 3 de vida.")

      expect(Deckex.Spellbook.Mock, :find_combos, fn _main, _commanders ->
        {:ok, %{included: [prose], almost: []}}
      end)

      {:ok, saved} = Combos.refresh(deck)

      assert [%{"prerequisites" => ["Sol Ring não está enjoado.", "Você tem 3 de vida."]}] =
               Combos.for_deck(saved)["assembled"]
    end

    test "a combo with no prerequisites at all is still stored" do
      deck = deck()

      bare = Map.delete(combo(["Sol Ring", "Cultivate"], ["X"]), "notablePrerequisites")

      expect(Deckex.Spellbook.Mock, :find_combos, fn _main, _commanders ->
        {:ok, %{included: [bare], almost: []}}
      end)

      {:ok, saved} = Combos.refresh(deck)

      assert [%{"prerequisites" => []}] = Combos.for_deck(saved)["assembled"]
    end

    test "a deck nobody has asked about reads as empty, never as nil" do
      assert Combos.for_deck(deck()) == %{"assembled" => [], "one_card_away" => []}
      refute Combos.asked?(deck())
    end
  end

  describe "the list changing" do
    # Editing five cards in a row must not fire five requests at a public API
    # that owes this app nothing.
    test "an edit schedules one refresh and flags the combos" do
      deck = deck()

      expect(Deckex.Spellbook.Mock, :find_combos, fn _main, _commanders ->
        {:ok, %{included: [combo(["Sol Ring", "Cultivate"], ["Mana infinita"])], almost: []}}
      end)

      {:ok, saved} = Combos.refresh(deck)

      {:ok, _card} = Decks.add_card(saved, "Forest")
      {:ok, edited} = Decks.fetch_deck(saved.id)

      assert edited.combos_stale
      assert_enqueued(worker: Deckex.Workers.ComboWorker, args: %{deck_id: saved.id})
    end
  end

  describe "the briefing" do
    defp briefing_with(combos) do
      snapshot = AnalysisFixture.snapshot([])

      Briefing.build(Analysis.report(snapshot), snapshot, :full, combos: combos)
    end

    test "states an assembled combo as a thing the round must not break" do
      briefing =
        briefing_with(%{
          "assembled" => [
            %{
              "cards" => ["Sam, Loyal Attendant", "Prize Pig"],
              "produces" => ["Mana infinita"],
              "prerequisites" => []
            }
          ],
          "one_card_away" => []
        })

      assert briefing =~ "Combos conhecidos nesta lista"
      assert briefing =~ "Sam, Loyal Attendant + Prize Pig"
      assert briefing =~ "Mana infinita"
      assert briefing =~ "loses the line"
    end

    # The sharpest answer available to "what should this deck add".
    test "an almost-combo is stated as one named card" do
      briefing =
        briefing_with(%{
          "assembled" => [],
          "one_card_away" => [
            %{
              "cards" => ["Sol Ring", "Basalt Monolith"],
              "missing" => "Basalt Monolith",
              "produces" => ["Mana infinita"],
              "prerequisites" => []
            }
          ]
        })

      assert briefing =~ "One card away (1)"
      assert briefing =~ "**add Basalt Monolith**"
      assert briefing =~ "with Sol Ring"
    end

    test "a deck with no combos carries no block at all" do
      refute briefing_with(%{"assembled" => [], "one_card_away" => []}) =~ "Combos conhecidos"
      refute briefing_with(nil) =~ "Combos conhecidos"
    end
  end
end
