defmodule Deckex.Spellbook do
  @moduledoc """
  Facade for the Commander Spellbook port, and the shape a combo takes here.

  A combo is the strongest statement this app can make about two cards being
  connected: not "these are played together often" but "these, together, do
  this". The owner's own case is the argument — Sam, Loyal Attendant and Prize
  Pig are unremarkable apart and a mana engine together, and no measurement of
  either card alone was ever going to say so.

  Only what a briefing can use is kept. The API answers with prices, legalities
  in nine formats, vendor links and a numeric mana value; a stage reading the
  deck needs the cards, what the line produces, and what it needs to be true
  first. The rest is weight in a prompt that already carries a hundred cards.
  """
  @behaviour Deckex.Spellbook.Client

  alias Deckex.Cards.Name
  alias Deckex.Error

  @adapter Application.compile_env(
             :deckex,
             [Deckex.Spellbook.Client, :adapter],
             Deckex.Spellbook.Http
           )

  @impl Deckex.Spellbook.Client
  defdelegate find_combos(main, commanders), to: @adapter

  @doc """
  Trims one API combo down to what a briefing and a screen actually read.

  String-keyed, because it lands in JSONB and comes back string-keyed anyway —
  one shape everywhere, the same rule the optimization contract follows.
  """
  @spec summarise(map()) :: map()
  def summarise(%{} = combo) do
    %{
      "id" => combo["id"],
      "cards" => card_names(combo),
      "produces" => features(combo),
      "prerequisites" => Enum.map(combo["notablePrerequisites"] || [], &to_string/1),
      "steps" => String.trim(to_string(combo["description"] || ""))
    }
  end

  @doc """
  The card a deck is missing for an almost-combo, or nil.

  The endpoint answers "one card away" without saying which one, so it is
  worked out here: the piece that is not in the list. More than one missing
  means this is not a one-card combo for this deck and it is dropped — a
  suggestion the owner cannot act on in one move is not the point.
  """
  @spec missing_piece(map(), MapSet.t(String.t())) :: String.t() | nil
  def missing_piece(%{"cards" => cards}, present) do
    # Both sides through the normalizer: Spellbook writes a double-faced card
    # one way and the catalogue another, and a name compared raw would report
    # every piece missing.
    case Enum.reject(cards, &MapSet.member?(present, Name.normalize(&1))) do
      [one] -> one
      _none_or_several -> nil
    end
  end

  @doc "Whether the adapter answered with something usable."
  @spec ok?({:ok, term()} | {:error, Error.t()}) :: boolean()
  def ok?({:ok, _answer}), do: true
  def ok?({:error, %Error{}}), do: false

  defp card_names(combo) do
    combo
    |> Map.get("uses", [])
    |> Enum.map(&get_in(&1, ["card", "name"]))
    |> Enum.reject(&is_nil/1)
  end

  defp features(combo) do
    combo
    |> Map.get("produces", [])
    |> Enum.map(&get_in(&1, ["feature", "name"]))
    |> Enum.reject(&is_nil/1)
  end
end
