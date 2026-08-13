defmodule Deckex.Decks.DecklistParser do
  @moduledoc """
  Turns decklist text into entries. Pure: no database, no network.

  Real exports carry more than card lines — a title, a description, section
  headers, rules of dashes, and foil markers. Anything that is not a card line
  or a recognized header is ignored rather than guessed at, so a user pasting
  their own notes above the list still gets a clean import.

  Set codes and collector numbers are **kept on the name**. `Deckex.Cards.Name`
  strips them when resolving; throwing them away here would lose information the
  catalogue might later want.
  """

  alias Deckex.Error

  defmodule Entry do
    @moduledoc "One parsed decklist line."

    @type board :: :commander | :main | :maybe
    @type t :: %__MODULE__{quantity: pos_integer(), name: String.t(), board: board()}

    @enforce_keys [:quantity, :name, :board]
    defstruct [:quantity, :name, :board]
  end

  # "1 Sol Ring", "4x Forest", "SB: 1 Cultivate"
  @card_line ~r/^\s*(?:(SB):\s*)?(\d+)x?\s+(.+?)\s*$/i

  # A trailing foil/etched marker printed by Moxfield.
  @finish_marker ~r/\s*\*[A-Z]\*\s*$/

  # A rule of dashes closes a section and returns to the main deck.
  @separator ~r/^\s*-{3,}\s*$/

  @headers %{
    "commander" => :commander,
    "commanders" => :commander,
    "deck" => :main,
    "main" => :main,
    "mainboard" => :main,
    "sideboard" => :maybe,
    "maybeboard" => :maybe,
    "maybe" => :maybe,
    "considering" => :maybe
  }

  @doc """
  Parses decklist text into entries, in the order they appear.

  Returns `{:error, %Deckex.Error{code: :empty_decklist}}` when no line looks
  like a card — an empty result is far more likely to be a paste mistake than a
  deck with no cards.
  """
  @spec parse(String.t()) :: {:ok, [Entry.t()]} | {:error, Error.t()}
  def parse(text) when is_binary(text) do
    entries =
      text
      |> String.split("\n")
      |> Enum.reduce({:main, []}, &consume_line/2)
      |> elem(1)
      |> Enum.reverse()

    case entries do
      [] -> {:error, empty_error()}
      entries -> {:ok, entries}
    end
  end

  defp consume_line(line, {board, acc}) do
    cond do
      Regex.match?(@separator, line) -> {:main, acc}
      new_board = header(line) -> {new_board, acc}
      entry = card(line, board) -> {board, [entry | acc]}
      true -> {board, acc}
    end
  end

  defp header(line) do
    Map.get(@headers, line |> String.trim() |> String.trim_trailing(":") |> String.downcase())
  end

  defp card(line, board) do
    case Regex.run(@card_line, line) do
      [_all, sideboard, quantity, name] ->
        %Entry{
          quantity: String.to_integer(quantity),
          name: name |> String.replace(@finish_marker, "") |> String.trim(),
          board: if(sideboard == "", do: board, else: :maybe)
        }

      _no_match ->
        nil
    end
  end

  defp empty_error do
    Error.new(
      :empty_decklist,
      "Não achei nenhuma carta nessa lista. Confere se colou a exportação do deck.",
      %{}
    )
  end
end
