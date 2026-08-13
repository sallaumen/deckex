defmodule Deckex.Decks.DecklistParserTest do
  use ExUnit.Case, async: true

  alias Deckex.Decks.DecklistParser
  alias Deckex.Decks.DecklistParser.Entry
  alias Deckex.Error

  defp parse!(text) do
    {:ok, entries} = DecklistParser.parse(text)
    entries
  end

  describe "parse/1 card lines" do
    test "reads quantity and name" do
      assert [%Entry{quantity: 1, name: "Sol Ring", board: :main}] = parse!("1 Sol Ring")
    end

    test "reads a quantity above one" do
      assert [%Entry{quantity: 4, name: "Forest"}] = parse!("4 Forest")
    end

    test "accepts the 4x spelling" do
      assert [%Entry{quantity: 4, name: "Forest"}] = parse!("4x Forest")
    end

    test "keeps the set code and collector number on the name" do
      # Deckex.Cards.Name strips them later; the parser must not lose
      # information the catalogue might want.
      assert [%Entry{name: "Cultivate (M21) 177"}] = parse!("1 Cultivate (M21) 177")
    end

    test "drops the foil and etched markers" do
      assert [%Entry{name: "Sol Ring (M3C) 305"}] = parse!("1 Sol Ring (M3C) 305 *F*")
      assert [%Entry{name: "Scalding Tarn (MH2) 439"}] = parse!("1 Scalding Tarn (MH2) 439 *E*")
    end

    test "keeps a double-faced name intact, slash and all" do
      assert [%Entry{name: "Birgi, God of Storytelling / Harnfel, Horn of Bounty (KHM) 123"}] =
               parse!("1 Birgi, God of Storytelling / Harnfel, Horn of Bounty (KHM) 123")
    end
  end

  describe "parse/1 boards" do
    test "everything is main by default" do
      assert [%Entry{board: :main}, %Entry{board: :main}] = parse!("1 Sol Ring\n1 Cultivate")
    end

    test "a Commander header puts the next cards on the commander board" do
      text = """
      Commander
      1 Iroh, Grand Lotus
      """

      assert [%Entry{name: "Iroh, Grand Lotus", board: :commander}] = parse!(text)
    end

    test "a Commander header with a colon works too" do
      assert [%Entry{board: :commander}] = parse!("Commander:\n1 Iroh, Grand Lotus")
    end

    test "a dashed separator ends the commander section" do
      # This is the shape a real export took: a Commander header, one card, a
      # rule of dashes, then the rest of the deck.
      text = """
      Commander:
      1 Iroh, Grand Lotus (TLA) 227 *F*

       ----
      1 Sol Ring (M3C) 305
      """

      assert [
               %Entry{name: "Iroh, Grand Lotus (TLA) 227", board: :commander},
               %Entry{name: "Sol Ring (M3C) 305", board: :main}
             ] = parse!(text)
    end

    test "a Deck header returns to the main board" do
      text = """
      Commander
      1 Iroh, Grand Lotus
      Deck
      1 Sol Ring
      """

      assert [%Entry{board: :commander}, %Entry{board: :main}] = parse!(text)
    end

    test "sideboard and maybeboard land on the maybe board" do
      text = """
      1 Sol Ring
      Maybeboard
      1 Cultivate
      """

      assert [%Entry{board: :main}, %Entry{name: "Cultivate", board: :maybe}] = parse!(text)
    end

    test "the SB: prefix marks a single line as maybe" do
      assert [%Entry{name: "Cultivate", board: :maybe}] = parse!("SB: 1 Cultivate")
    end
  end

  describe "parse/1 noise" do
    test "ignores blank lines and prose" do
      text = """
      Nome do deck: Iroh das Lontra

      Tema: rampar no começo e segurar o game

      1 Sol Ring
      """

      assert [%Entry{name: "Sol Ring"}] = parse!(text)
    end

    test "ignores a line that merely starts with a word" do
      assert length(parse!("Commander\n1 Iroh, Grand Lotus\nobrigado!")) == 1
    end
  end

  describe "parse/1 failure" do
    test "a decklist with no card lines is an error, not an empty deck" do
      assert {:error, %Error{code: :empty_decklist}} = DecklistParser.parse("só conversa fiada")
    end

    test "empty input is an error" do
      assert {:error, %Error{code: :empty_decklist}} = DecklistParser.parse("")
    end
  end

  describe "parse/1 on the real deck" do
    test "reads every line of a real 100-card export" do
      text = File.read!("test/support/fixtures/decklists/iroh_das_lontra.txt")

      assert {:ok, entries} = DecklistParser.parse(text)

      assert length(entries) == 92
      assert Enum.sum(Enum.map(entries, & &1.quantity)) == 101
      assert Enum.count(entries, &(&1.board == :commander)) == 1
      assert %Entry{name: "Iroh, Grand Lotus (TLA) 227"} = hd(entries)
    end
  end
end
