defmodule Deckex.Cards.Card do
  @moduledoc """
  A Magic card, cached from Scryfall.

  Stored at the **oracle** level: one row per distinct card, keyed on
  `oracle_id`, not one row per printing. Deck analysis does not care which
  printing of Sol Ring you own, so `scryfall_id` is retained only as the
  representative printing the image came from.

  Cards are effectively immutable. The exception is `price_usd`, refreshed
  opportunistically and treated as advisory.
  """
  use Deckex.Schema

  import Ecto.Changeset

  @fields ~w(oracle_id scryfall_id name name_normalized mana_cost cmc type_line power toughness
             oracle_text colors color_identity produced_mana keywords edhrec_rank
             rarity layout card_faces image_normal_url image_art_crop_url
             commander_legal game_changer price_usd prices_updated_at scryfall_uri
             fetched_at)a

  @required ~w(oracle_id scryfall_id name name_normalized cmc type_line layout
               fetched_at)a

  @type t :: %__MODULE__{}

  schema "cards" do
    field :oracle_id, Ecto.UUID
    field :scryfall_id, Ecto.UUID
    field :name, :string
    field :name_normalized, :string
    field :mana_cost, :string
    field :cmc, :decimal
    field :type_line, :string
    field :power, :string
    field :toughness, :string
    field :oracle_text, :string
    field :colors, {:array, :string}, default: []
    field :color_identity, {:array, :string}, default: []
    field :produced_mana, {:array, :string}, default: []
    field :keywords, {:array, :string}, default: []
    field :edhrec_rank, :integer
    field :rarity, :string
    field :layout, :string
    field :card_faces, {:array, :map}, default: []
    field :image_normal_url, :string
    field :image_art_crop_url, :string
    field :commander_legal, :boolean, default: false

    # The Commander Format Panel's Game Changers list, as Scryfall reports it.
    # Never a list we keep: it is revised a few times a year, and every card
    # object already carries the flag.
    field :game_changer, :boolean, default: false
    field :price_usd, :decimal
    field :prices_updated_at, :utc_datetime
    field :scryfall_uri, :string
    field :fetched_at, :utc_datetime

    timestamps()
  end

  @doc """
  Whether the card's front face is a land.

  Reads the front face only, like `Deckex.Analysis.CardEntry`: a spell whose
  back is a land is a spell you may also play as a land, and it is priced as
  the spell it is.
  """
  @spec land?(t()) :: boolean()
  def land?(%__MODULE__{type_line: nil}), do: false

  def land?(%__MODULE__{type_line: type_line}) do
    type_line |> String.split("//") |> hd() |> String.contains?("Land")
  end

  @doc """
  Whether this is a basic land, which a deck may hold any number of.

  Reads the type line rather than a list of five names: snow-covered basics and
  Wastes are basic too, and the type line already says so.
  """
  @spec basic_land?(t()) :: boolean()
  def basic_land?(%__MODULE__{type_line: nil}), do: false

  def basic_land?(%__MODULE__{type_line: type_line}) do
    String.contains?(type_line, "Basic") and String.contains?(type_line, "Land")
  end

  @doc """
  Whether the card's own text lifts the singleton rule.

  Relentless Rats and its cousins all say so in their rules text, so this asks
  the card instead of carrying a list that would go stale with the next set.
  """
  @spec any_number_allowed?(t()) :: boolean()
  def any_number_allowed?(%__MODULE__{oracle_text: nil}), do: false

  def any_number_allowed?(%__MODULE__{oracle_text: text}) do
    String.contains?(text, "any number of cards named")
  end

  @doc "Builds a changeset from Scryfall-derived attributes."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(card, attrs) do
    card
    |> cast(attrs, @fields)
    |> validate_required(@required)
    |> unique_constraint(:oracle_id)
    |> unique_constraint(:name_normalized)
  end
end
