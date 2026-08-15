defmodule Deckex.Cards.PlayRate do
  @moduledoc """
  How much of Commander plays this card.

  The owner's fear, in his words: *"carta muito barata normalmente não é boa"*.
  The catalogue says otherwise, and says it with his own suggestions — Arcane
  Signet costs two reais and is the third most-played card in the format, while
  Vexing Shusher costs thirty-six and sits past rank five thousand. Price
  tracks scarcity and hype at least as much as it tracks power, so an engine
  that preferred expensive cards would have thrown out the Signet and kept the
  Shusher.

  This is the signal price was standing in for. `edhrec_rank` is an ordinal —
  rank 3 is played in more decks than rank 700 — and it arrives inside the
  Scryfall card object the catalogue already fetches.

  **It is shown, never enforced.** Popularity is not quality: a card nobody
  plays can be exactly right for one deck's engine, and that possibility is the
  reason this app exists. The day this number decides something on its own it
  has become the power level this project refuses to build. So it renders next
  to a card and stops there — the argument for a card is still the argument for
  a card.
  """

  alias Deckex.Cards.Card

  @staple 500
  @common 2_000
  @niche 10_000

  @type band :: :staple | :common | :niche | :fringe | :unknown

  @doc """
  Which band a card's rank falls in.

  The cuts are round numbers, not discoveries: past ten thousand a card is
  genuinely rare at a table, and inside five hundred it is something most
  players have seen. They are here to turn an ordinal into a sentence.
  """
  @spec band(Card.t() | integer() | nil) :: band()
  def band(%Card{edhrec_rank: rank}), do: band(rank)
  def band(nil), do: :unknown
  def band(rank) when rank <= @staple, do: :staple
  def band(rank) when rank <= @common, do: :common
  def band(rank) when rank <= @niche, do: :niche
  def band(_rank), do: :fringe

  @doc "The band in pt-BR, for a reader who has never heard of a rank."
  @spec label(Card.t() | integer() | nil) :: String.t()
  def label(card_or_rank), do: card_or_rank |> band() |> band_label()

  @spec band_label(band()) :: String.t()
  def band_label(:staple), do: "carta de base do formato"
  def band_label(:common), do: "jogada com frequência"
  def band_label(:niche), do: "pouco jogada"
  def band_label(:fringe), do: "quase ninguém joga"
  def band_label(:unknown), do: "sem dado de uso"

  @doc """
  The rank itself, written the way a position is written in pt-BR.

  Thousands get a separator because `10632` and `1632` are one glance apart and
  a factor of six different.
  """
  @spec position(Card.t() | integer() | nil) :: String.t() | nil
  def position(%Card{edhrec_rank: rank}), do: position(rank)
  def position(nil), do: nil

  def position(rank) when is_integer(rank) do
    "#" <>
      (rank
       |> Integer.to_string()
       |> String.reverse()
       |> String.replace(~r/(\d{3})(?=\d)/, "\\1.")
       |> String.reverse())
  end

  @doc """
  The full sentence: position and band together.

  What a tooltip says, and what the CSV column holds — the number alone means
  nothing to someone who has not been told what it counts.
  """
  @spec sentence(Card.t() | integer() | nil) :: String.t()
  def sentence(nil), do: band_label(:unknown)

  def sentence(card_or_rank) do
    case position(card_or_rank) do
      nil -> band_label(:unknown)
      position -> "#{position} em uso no Commander — #{label(card_or_rank)}"
    end
  end

  @doc """
  Whether this card is rare enough at tables to be worth a second look.

  Not a verdict. A suggestion of a card almost nobody plays may be a find or
  may be filler, and the difference is in the reasoning next to it — this only
  says which suggestions deserve reading twice.
  """
  @spec worth_a_look?(Card.t() | integer() | nil) :: boolean()
  def worth_a_look?(card_or_rank), do: band(card_or_rank) == :fringe
end
