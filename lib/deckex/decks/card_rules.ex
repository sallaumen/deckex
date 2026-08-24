defmodule Deckex.Decks.CardRules do
  @moduledoc """
  The owner's standing decisions about cards, as text going in and as groups
  coming out. Pure: no database, no network.

  Going in, the format is the one he already has in his hands — a list of card
  names, one per line, the way every deck site on earth exports them. Quantity
  prefixes are tolerated and thrown away because a rule is about a card, not
  about copies of it, and a pasted decklist line should not become a rule about
  a card named "1x Sol Ring".

  The reason is optional and goes after a pipe: `Sam, Loyal Attendant | faz
  comida sair de graça com o Prize Pig`. A pipe is the separator because no
  Magic card name contains one — commas, colons, apostrophes, dashes and
  slashes all appear in real names, and every one of them would have made this
  parser wrong.
  """

  alias Deckex.Cards.Name
  alias Deckex.Decks.CardNote

  # "1 Sol Ring", "4x Forest" — the quantity is noise here.
  @quantity ~r/^\s*\d+\s*x?\s+/i

  # Anything a person writes above their own list to organize it.
  @comment ~r{^\s*(?:#|//)}

  @type entry :: %{name: String.t(), note: String.t() | nil}
  @type groups :: %{locked: [CardNote.t()], wanted: [CardNote.t()], notes: [CardNote.t()]}

  @doc """
  Parses pasted text into entries, in the order written, one per card.

  A card named twice keeps its first line: the person who typed it twice meant
  it once, and the first reason is the one they thought of first.

      iex> Deckex.Decks.CardRules.parse("1x Sol Ring | rampa\\n\\n# lixo\\nSol Ring")
      [%{name: "Sol Ring", note: "rampa"}]
  """
  @spec parse(String.t() | nil) :: [entry()]
  def parse(nil), do: []

  def parse(text) do
    text
    |> String.split(["\r\n", "\n", "\r"])
    |> Enum.reject(&(String.trim(&1) == "" or Regex.match?(@comment, &1)))
    |> Enum.map(&entry/1)
    |> Enum.reject(&(&1.name == ""))
    |> Enum.uniq_by(&Name.normalize(&1.name))
  end

  defp entry(line) do
    {name, note} =
      case String.split(line, "|", parts: 2) do
        [written, reason] -> {written, reason}
        [written] -> {written, ""}
      end

    %{name: name |> String.replace(@quantity, "") |> String.trim(), note: blank_to_nil(note)}
  end

  defp blank_to_nil(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  @doc """
  Splits stored rules by stance, each group in the order it was read.

  Always returns all three keys — a screen that renders "nenhuma carta
  obrigatória" needs the empty list to exist.
  """
  @spec split([CardNote.t()]) :: groups()
  def split(rules) do
    grouped = Enum.group_by(rules, & &1.stance)

    %{
      locked: Map.get(grouped, :locked, []),
      wanted: Map.get(grouped, :wanted, []),
      notes: Map.get(grouped, :note, [])
    }
  end

  @doc "The card names carrying one stance, as the owner wrote them."
  @spec names([CardNote.t()], CardNote.stance()) :: [String.t()]
  def names(rules, stance) do
    rules |> Enum.filter(&(&1.stance == stance)) |> Enum.map(& &1.card_name)
  end

  @doc """
  Which of these names are absent from a list of card names.

  An order to keep a card the deck does not have is not a contradiction — it
  is the most useful line on the screen, because it is the one still waiting
  to be acted on.
  """
  @spec missing_from([String.t()], [String.t()]) :: MapSet.t(String.t())
  def missing_from(names, present) do
    have = MapSet.new(present, &Name.normalize/1)

    names
    |> Enum.reject(&MapSet.member?(have, Name.normalize(&1)))
    |> MapSet.new()
  end
end
