defmodule Deckex.Decks.DeckTest do
  use Deckex.DataCase, async: true

  alias Deckex.Decks.Deck
  alias Deckex.Decks.DeckCard
  alias Deckex.Decks.DeckQuery
  alias Deckex.Error

  describe "Deck.changeset/2" do
    test "accepts a minimal deck" do
      changeset = Deck.changeset(%Deck{}, %{name: "Iroh", source: :paste, status: :ready})

      assert %Ecto.Changeset{valid?: true} = changeset
    end

    test "requires a name, a source and a status" do
      errors = %Deck{} |> Deck.changeset(%{}) |> errors_on()

      for field <- [:name, :source, :status] do
        assert %{^field => ["can't be blank"]} = errors
      end
    end

    test "rejects a source outside the vocabulary" do
      changeset = Deck.changeset(%Deck{}, %{name: "x", source: :carrier_pigeon, status: :ready})

      assert %{source: ["is invalid"]} = errors_on(changeset)
    end

    test "rejects two decks sharing a Moxfield id" do
      attrs = %{name: "a", source: :moxfield, status: :ready, moxfield_public_id: "abc123"}
      assert {:ok, _deck} = %Deck{} |> Deck.changeset(attrs) |> Repo.insert()

      assert {:error, changeset} =
               %Deck{} |> Deck.changeset(%{attrs | name: "b"}) |> Repo.insert()

      assert %{moxfield_public_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "allows many decks without a Moxfield id" do
      attrs = %{name: "a", source: :paste, status: :ready}

      assert {:ok, _first} = %Deck{} |> Deck.changeset(attrs) |> Repo.insert()
      assert {:ok, _second} = %Deck{} |> Deck.changeset(%{attrs | name: "b"}) |> Repo.insert()
    end
  end

  describe "DeckCard.changeset/2" do
    test "accepts a card on a board" do
      deck = insert(:deck)
      card = insert(:card)

      attrs = %{deck_id: deck.id, card_id: card.id, quantity: 1, board: :main}

      assert {:ok, _deck_card} = %DeckCard{} |> DeckCard.changeset(attrs) |> Repo.insert()
    end

    test "rejects the same card twice on the same board" do
      deck = insert(:deck)
      card = insert(:card)
      attrs = %{deck_id: deck.id, card_id: card.id, quantity: 1, board: :main}

      assert {:ok, _first} = %DeckCard{} |> DeckCard.changeset(attrs) |> Repo.insert()
      assert {:error, changeset} = %DeckCard{} |> DeckCard.changeset(attrs) |> Repo.insert()

      assert errors_on(changeset) != %{}
    end

    test "allows the same card on two different boards" do
      deck = insert(:deck)
      card = insert(:card)

      assert {:ok, _main} =
               %DeckCard{}
               |> DeckCard.changeset(%{
                 deck_id: deck.id,
                 card_id: card.id,
                 quantity: 1,
                 board: :main
               })
               |> Repo.insert()

      assert {:ok, _maybe} =
               %DeckCard{}
               |> DeckCard.changeset(%{
                 deck_id: deck.id,
                 card_id: card.id,
                 quantity: 1,
                 board: :maybe
               })
               |> Repo.insert()
    end

    test "rejects a quantity below one" do
      deck = insert(:deck)
      card = insert(:card)

      changeset =
        DeckCard.changeset(%DeckCard{}, %{
          deck_id: deck.id,
          card_id: card.id,
          quantity: 0,
          board: :main
        })

      assert %{quantity: ["must be greater than 0"]} = errors_on(changeset)
    end
  end

  describe "DeckQuery" do
    test "lists decks newest first, excluding archived ones" do
      _archived = insert(:deck, name: "velho", archived_at: DateTime.utc_now(:second))
      live = insert(:deck, name: "novo")

      assert [%{id: id}] = DeckQuery.list_decks()
      assert id == live.id
    end

    test "fetch_deck/1 returns a tagged tuple" do
      deck = insert(:deck)

      assert {:ok, %{id: id}} = DeckQuery.fetch_deck(deck.id)
      assert id == deck.id

      assert {:error, %Error{code: :deck_not_found}} =
               DeckQuery.fetch_deck(Ecto.UUID.generate())
    end

    test "lists a deck's cards with the card preloaded" do
      deck = insert(:deck)
      card = insert(:card, name: "Sol Ring")
      insert(:deck_card, deck: deck, card: card, quantity: 1, board: :main)

      assert [%{quantity: 1, card: %{name: "Sol Ring"}}] = DeckQuery.list_deck_cards(deck)
    end

    test "finds a deck by its Moxfield id" do
      deck = insert(:deck, moxfield_public_id: "kq9g4t81")

      assert %{id: id} = DeckQuery.get_by_public_id("kq9g4t81")
      assert id == deck.id
      assert DeckQuery.get_by_public_id("nao-existe") == nil
    end
  end

  describe "dossier fields" do
    test "a new deck has no dossier and is not stale" do
      deck = insert(:deck)

      assert deck.dossier == nil
      assert deck.dossier_source == nil
      assert deck.dossier_stale == false
      assert deck.dossier_updated_at == nil
    end

    test "changeset accepts the dossier fields" do
      dossier = %{
        "plano" => "Spellslinger Temur.",
        "sinergias" => "Iroh dá flashback às Lessons.",
        "linhas_de_vitoria" => "Storm Kiln Artist + magias baratas.",
        "fraquezas" => "Depende inteiramente do cemitério."
      }

      deck =
        :deck
        |> insert()
        |> Deck.changeset(%{
          dossier: dossier,
          dossier_source: :scout,
          dossier_stale: false,
          dossier_updated_at: DateTime.utc_now(:second)
        })
        |> Repo.update!()

      assert deck.dossier["plano"] == "Spellslinger Temur."
      assert deck.dossier_source == :scout
    end
  end
end
