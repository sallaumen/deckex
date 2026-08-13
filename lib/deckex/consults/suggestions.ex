defmodule Deckex.Consults.Suggestions do
  @moduledoc """
  Turns a consult's answer into rows you can act on.

  **Prices come from the catalogue, never from the model.** A model's price
  memory is stale on a good day and invented on a bad one, and Scryfall's is
  neither — so every suggested card is looked up in the catalogue and its own
  `price_usd` is used. Any price field the model volunteered is discarded.

  **This module only reads.** Building the table is what rendering a deck page
  does, and a render must never reach for the network — `Deckex.Consults.run/1`
  fetches the suggested cards into the catalogue once, in the background, when
  the answer arrives. A card that is missing here renders unresolved rather than
  making the page wait on Scryfall.

  CSV lives here as an *export*, not as the wire format. The model answers in
  JSON against a schema, which is typed and cannot be broken by a comma in a
  sentence; CSV is for getting the table into a spreadsheet.
  """

  alias Deckex.Cards.CardQuery
  alias Deckex.Cards.Name
  alias Deckex.Consults.Consult
  alias Deckex.Consults.Suggestion
  alias Deckex.Money

  @header "acao,carta,motivo,achado,preco_usd,preco_brl,resolvida"

  @doc "Every suggestion in a consult's answer, cuts first."
  @spec for_consult(Consult.t()) :: [Suggestion.t()]
  def for_consult(%Consult{response: nil}), do: []

  def for_consult(%Consult{} = consult) do
    rows = unresolved(consult)

    Enum.map(rows, &attach(&1, resolve(rows)))
  end

  @doc """
  The card names a consult's answer mentions, as written.

  `Deckex.Consults.run/1` hands these to the catalogue so the table has real
  cards and real prices by the time anyone looks at it.
  """
  @spec names(Consult.t()) :: [String.t()]
  def names(%Consult{} = consult) do
    consult |> unresolved() |> Enum.map(& &1.name) |> Enum.uniq()
  end

  @doc "What the adds would cost, in USD. Cuts do not count — they are refunds at best."
  @spec total_usd([Suggestion.t()]) :: Decimal.t()
  def total_usd(suggestions) do
    suggestions
    |> Enum.filter(&(&1.action == :add and &1.price_usd))
    |> Enum.reduce(Decimal.new(0), fn suggestion, total ->
      Decimal.add(total, suggestion.price_usd)
    end)
  end

  @doc "The table as CSV, for a spreadsheet."
  @spec to_csv([Suggestion.t()]) :: String.t()
  def to_csv(suggestions) do
    "#{@header}\n#{Enum.map_join(suggestions, "\n", &csv_line/1)}\n"
  end

  defp unresolved(%Consult{response: nil}), do: []

  defp unresolved(%Consult{response: response}) do
    rows(response, "cuts", :cut) ++ rows(response, "adds", :add)
  end

  defp rows(response, key, action) do
    response
    |> Map.get(key)
    |> List.wrap()
    |> Enum.map(fn row ->
      %Suggestion{
        action: action,
        name: row["card"],
        reason: row["reason"] || "",
        addresses: row["addresses"],
        replaces: row["replaces"]
      }
    end)
    |> Enum.reject(&is_nil(&1.name))
  end

  # One query for every name in the answer.
  defp resolve([]), do: %{}

  defp resolve(rows) do
    rows
    |> Enum.map(&Name.normalize(&1.name))
    |> Enum.uniq()
    |> CardQuery.list_by_normalized_names()
    |> Map.new(&{&1.name_normalized, &1})
  end

  defp attach(%Suggestion{} = suggestion, cards) do
    case Map.get(cards, Name.normalize(suggestion.name)) do
      nil -> %{suggestion | resolved?: false}
      card -> %{suggestion | card: card, price_usd: card.price_usd, resolved?: true}
    end
  end

  defp csv_line(suggestion) do
    [
      action_label(suggestion.action),
      suggestion.name,
      suggestion.reason,
      suggestion.addresses || "",
      price(suggestion.price_usd),
      price(Money.to_brl(suggestion.price_usd)),
      if(suggestion.resolved?, do: "sim", else: "nao")
    ]
    |> Enum.map_join(",", &escape/1)
  end

  defp action_label(:cut), do: "cortar"
  defp action_label(:add), do: "colocar"

  defp price(nil), do: ""
  defp price(%Decimal{} = amount), do: amount |> Decimal.round(2) |> Decimal.to_string(:normal)

  # RFC 4180: wrap in quotes when the field contains a comma, a quote or a
  # newline, and double any quote inside.
  defp escape(field) do
    if String.contains?(field, [",", "\"", "\n"]) do
      ~s("#{String.replace(field, "\"", "\"\"")}")
    else
      field
    end
  end
end
