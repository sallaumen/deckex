defmodule Deckex.Cards.NameTest do
  use ExUnit.Case, async: true

  alias Deckex.Cards.Name

  doctest Deckex.Cards.Name

  describe "normalize/1" do
    test "downcases" do
      assert Name.normalize("Sol Ring") == "sol ring"
    end

    test "keeps only the front face of a double-faced name" do
      assert Name.normalize("Agadeem's Awakening // Agadeem, the Undercrypt") ==
               "agadeem's awakening"
    end

    test "resolves the front-face-only spelling to the same key" do
      full = Name.normalize("Agadeem's Awakening // Agadeem, the Undercrypt")
      front_only = Name.normalize("Agadeem's Awakening")

      assert full == front_only
    end

    test "treats Moxfield's single-slash double-faced names as the same card" do
      # Scryfall writes "A // B"; Moxfield exports "A / B". If these produced
      # different keys, every double-faced card would miss the catalogue lookup
      # and be re-fetched on every single import, forever.
      moxfield = Name.normalize("Birgi, God of Storytelling / Harnfel, Horn of Bounty")
      scryfall = Name.normalize("Birgi, God of Storytelling // Harnfel, Horn of Bounty")

      assert moxfield == scryfall
      assert moxfield == "birgi, god of storytelling"
    end

    test "strips the set code that trails a single-slash double-faced name" do
      assert Name.normalize("Valakut Awakening / Valakut Stoneforge (ZNR) 174") ==
               "valakut awakening"
    end

    test "strips a trailing set code and collector number" do
      assert Name.normalize("Cultivate (M21) 177") == "cultivate"
      assert Name.normalize("Sol Ring (LTC)") == "sol ring"
    end

    test "strips accents so typed names match" do
      assert Name.normalize("Juzám Djinn") == "juzam djinn"
      assert Name.normalize("Márton Stromgald") == "marton stromgald"
    end

    test "trims surrounding whitespace" do
      assert Name.normalize("  Sol Ring  ") == "sol ring"
    end

    test "leaves apostrophes and commas alone — they are part of the name" do
      assert Name.normalize("Gaea's Cradle") == "gaea's cradle"
    end
  end
end
