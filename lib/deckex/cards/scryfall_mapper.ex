defmodule Deckex.Cards.ScryfallMapper do
  @moduledoc """
  Translates a Scryfall card object into `Deckex.Cards.Card` attributes.

  Double-faced layouts are the reason this module exists. On `modal_dfc`,
  `transform`, `split` and `adventure` cards, Scryfall omits `mana_cost`,
  `colors` and `image_uris` at the top level and puts them on the faces — while
  `cmc`, `type_line`, `color_identity` and `produced_mana` stay at the top.
  Reading the wrong level yields a card with no cost and no image, which is
  exactly the sort of bug that only shows up on the handful of MDFCs in a deck.

  `front/3` is that rule, named once: read the top level, fall back to the front
  face. Fields that are always at the top level are read directly.
  """

  alias Deckex.Cards.Name

  @doc "Maps a Scryfall card object to attributes for `Card.changeset/2`."
  @spec to_attrs(map()) :: map()
  def to_attrs(card) when is_map(card) do
    face = front_face(card)
    images = front(card, face, "image_uris", %{})
    now = DateTime.utc_now(:second)

    %{
      oracle_id: front(card, face, "oracle_id"),
      scryfall_id: card["id"],
      name: card["name"],
      name_normalized: Name.normalize(card["name"]),
      mana_cost: blank_to_nil(front(card, face, "mana_cost")),
      cmc: to_decimal(card["cmc"]),
      type_line: front(card, face, "type_line"),
      power: front(card, face, "power"),
      toughness: front(card, face, "toughness"),
      oracle_text: front(card, face, "oracle_text"),
      colors: front(card, face, "colors", []),
      color_identity: list(card, "color_identity"),
      produced_mana: list(card, "produced_mana"),
      keywords: list(card, "keywords"),
      edhrec_rank: card["edhrec_rank"],
      rarity: card["rarity"],
      layout: card["layout"],
      card_faces: list(card, "card_faces"),
      image_normal_url: images["normal"],
      image_art_crop_url: images["art_crop"],
      commander_legal: get_in(card, ["legalities", "commander"]) == "legal",
      game_changer: card["game_changer"] == true,
      price_usd: to_decimal(get_in(card, ["prices", "usd"])),
      prices_updated_at: now,
      scryfall_uri: card["scryfall_uri"],
      fetched_at: now
    }
  end

  # The double-faced rule: prefer the top level, fall back to the front face.
  defp front(card, face, key, default \\ nil) do
    case card[key] do
      nil -> Map.get(face, key, default)
      value -> value
    end
  end

  defp list(card, key), do: card[key] || []

  defp front_face(%{"card_faces" => [face | _rest]}) when is_map(face), do: face
  defp front_face(_card), do: %{}

  # A land's mana_cost is "" rather than absent; store nil so "has no cost" is
  # one value everywhere instead of two.
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp to_decimal(nil), do: nil
  defp to_decimal(value) when is_binary(value), do: Decimal.new(value)
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)
end
