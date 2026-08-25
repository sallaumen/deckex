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
      "prerequisites" => prerequisites(combo["notablePrerequisites"]),
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

  # The live API answers this one as a **string** — a prose paragraph, newline
  # separated — while the schema page reads like a list, and the first real
  # request crashed on it. Both shapes are accepted rather than one guessed at:
  # this field is written by contributors and a version that changes its mind
  # must not take a background job down with it.
  defp prerequisites(nil), do: []
  defp prerequisites(notes) when is_list(notes), do: Enum.map(notes, &to_string/1)

  defp prerequisites(prose) when is_binary(prose) do
    prose
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp prerequisites(_unexpected), do: []

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
