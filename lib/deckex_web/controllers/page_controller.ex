defmodule DeckexWeb.PageController do
  use DeckexWeb, :controller

  @moduledoc """
  The table itself, plus the design-system preview.

  `home/2` is a holding page: the Mesa grid lands with the screens milestone
  (spec §13.7). `ui/2` renders every component in `DeckexWeb.UI` against real
  sample data and is wired only under the `dev_routes` scope — it exists so the
  vocabulary can be looked at without a deck in the database.
  """

  def home(conn, _params) do
    render(conn, :home)
  end

  # Real Scryfall art and costs — a preview built on invented data hides exactly
  # the failures that matter (long names wrapping, dark art under light ink).
  @sample_cards [
    %{
      name: "Cultivate",
      mana_cost: "{2}{G}",
      type_line: "Sorcery",
      quantity: 1,
      art:
        "https://cards.scryfall.io/art_crop/front/e/6/e60deb92-f7dd-4f4e-9036-e47dd586f985.jpg?1783903229"
    },
    %{
      name: "Sol Ring",
      mana_cost: "{1}",
      type_line: "Artifact",
      quantity: 1,
      art:
        "https://cards.scryfall.io/art_crop/front/9/f/9f37c5b6-a59c-45cd-9a99-e9357fe9ea1b.jpg?1783919146"
    },
    %{
      name: "Counterspell",
      mana_cost: "{U}{U}",
      type_line: "Instant",
      quantity: 1,
      art:
        "https://cards.scryfall.io/art_crop/front/4/f/4f616706-ec97-4923-bb1e-11a69fbaa1f8.jpg?1783909630"
    },
    %{
      name: "Blasphemous Act",
      mana_cost: "{8}{R}",
      type_line: "Sorcery",
      quantity: 1,
      art:
        "https://cards.scryfall.io/art_crop/front/7/d/7d4b1d44-126e-4987-9a9f-f0f9627a09cb.jpg?1783903234"
    }
  ]

  # {bucket, count, tone} — the 6+ buckets carry the tone a top-heavy finding
  # would light up.
  @sample_curve [
    {"0", 2, :neutral},
    {"1", 7, :neutral},
    {"2", 14, :neutral},
    {"3", 18, :neutral},
    {"4", 11, :neutral},
    {"5", 6, :neutral},
    {"6", 5, :warning},
    {"7+", 4, :warning}
  ]

  @sample_decklist """
  1 Cultivate
  1 Sol Ring
  1 Counterspell
  1 Agadeem's Awakening // Agadeem, the Undercrypt\
  """

  def ui(conn, _params) do
    render(conn, :ui,
      page_title: "Vocabulário",
      cards: @sample_cards,
      curve: @sample_curve,
      decklist: @sample_decklist
    )
  end
end
