defmodule Deckex.Consults.Vacancies do
  @moduledoc """
  Reads an answer into `Deckex.Consults.Vacancy` structs, for the Bancada.

  Two shapes come in and one goes out. A `:cardapio` answer is already
  vacancies. Every other lens that reaches this board — today only `:critico` —
  answers in the ordinary cuts/adds shape, and each of its changes becomes a
  **vacancy of one**: in this mode the critic's corrections are offered rather
  than applied, because a critic that silently corrected the owner's curation
  would hand the last word back to the model.

  Candidates are joined to the catalogue here, in one query for the whole
  board, for the same reason visions are priced when they are shown: he must
  never pick a card and only then learn the app has never heard of it.
  """

  alias Deckex.Cards.Name
  alias Deckex.Consults.Consult
  alias Deckex.Consults.Suggestion
  alias Deckex.Consults.Suggestions
  alias Deckex.Consults.Vacancy
  alias Deckex.Consults.Vacancy.Candidate

  @default_cuts 10
  @default_adds 20

  @doc """
  How many vacancies of each kind this run asked for.

  Defaults rather than a hard rule: the launch modal writes both numbers into
  the contract, and a run launched before they existed still has to render.
  """
  @spec slot_counts(map() | nil) :: %{cuts: pos_integer(), adds: pos_integer()}
  def slot_counts(contract) do
    contract = contract || %{}

    %{
      cuts: positive(contract["vagas_corte"], @default_cuts),
      adds: positive(contract["vagas_entrada"], @default_adds)
    }
  end

  defp positive(value, _fallback) when is_integer(value) and value > 0, do: value

  defp positive(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} when parsed > 0 -> parsed
      _not_a_number -> fallback
    end
  end

  defp positive(_absent_or_junk, fallback), do: fallback

  @doc """
  Every vacancy in a consult's answer, cuts first, joined to the catalogue.

  Cut vacancies past the principal count are flagged `reserve?`. They exist so
  a board that takes fifteen entries can pay for all fifteen without buying
  another consult — the arithmetic the owner hits on his first run, since a
  100-card deck that takes fifteen adds needs fifteen cuts.
  """
  @spec for_consult(Consult.t() | nil, map() | nil) :: [Vacancy.t()]
  def for_consult(nil, _contract), do: []
  def for_consult(%Consult{response: nil}, _contract), do: []

  def for_consult(%Consult{} = consult, contract) do
    principal = slot_counts(contract).cuts

    consult
    |> rows()
    |> build(principal)
    |> resolve()
  end

  @doc """
  Every card name a vacancy answer mentions, for the catalogue to fetch.

  Without this the candidates would never resolve and the board would show a
  wall of unpriced names: a cardápio answer has no `cuts` and no `adds`, so the
  ordinary suggestion path finds nothing in it — the same hole `Visions` fills
  for its key cards.
  """
  @spec card_names(Consult.t()) :: [String.t()]
  def card_names(%Consult{lens: :cardapio} = consult) do
    consult
    |> rows()
    |> Enum.flat_map(fn {_action, row} -> List.wrap(row["candidatos"]) end)
    |> Enum.map(& &1["carta"])
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
  end

  def card_names(%Consult{}), do: []

  defp rows(%Consult{lens: :cardapio, response: response}) do
    tagged(response, "cortes", :cut) ++ tagged(response, "adicoes", :add)
  end

  defp rows(%Consult{response: response}) do
    corrections(response, "cuts", :cut) ++ corrections(response, "adds", :add)
  end

  defp tagged(response, key, action) do
    response |> Map.get(key) |> List.wrap() |> Enum.map(&{action, &1})
  end

  defp corrections(response, key, action) do
    response
    |> Map.get(key)
    |> List.wrap()
    |> Enum.map(fn row ->
      {action,
       %{
         "grupo" => "Correção do crítico",
         "vaga" => row["reason"] || "",
         "candidatos" => [%{"carta" => row["card"], "porque" => row["reason"] || ""}]
       }}
    end)
  end

  # Indexed per action, because the key has to survive the reserve being
  # hidden, the board being re-sorted by `grupo`, and the page being remounted.
  defp build(rows, principal) do
    rows
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(fn {action, action_rows} ->
      action_rows
      |> Enum.with_index()
      |> Enum.map(fn {row, index} ->
        %Vacancy{
          key: Vacancy.key(action, index),
          action: action,
          index: index,
          grupo: string(row["grupo"]),
          vaga: string(row["vaga"]),
          candidatos: candidates(row["candidatos"]),
          reserve?: action == :cut and index >= principal
        }
      end)
    end)
    |> Enum.reject(&(&1.candidatos == []))
    |> Enum.sort_by(&{&1.action == :add, &1.index})
  end

  defp candidates(rows) do
    rows
    |> List.wrap()
    |> Enum.map(&%Candidate{name: &1["carta"], porque: string(&1["porque"])})
    |> Enum.reject(&(is_nil(&1.name) or &1.name == ""))
    |> Enum.uniq_by(&Name.normalize(&1.name))
  end

  defp string(nil), do: ""
  defp string(value) when is_binary(value), do: value
  defp string(value), do: to_string(value)

  # One query for every card on the board, not one per vacancy.
  defp resolve(vacancies) do
    cards =
      vacancies
      |> Enum.flat_map(fn vacancy ->
        Enum.map(vacancy.candidatos, &%Suggestion{action: :add, name: &1.name, reason: ""})
      end)
      |> Suggestions.attach_cards()
      |> Map.new(&{Name.normalize(&1.name), &1})

    Enum.map(vacancies, fn vacancy ->
      %{vacancy | candidatos: Enum.map(vacancy.candidatos, &attach(&1, cards))}
    end)
  end

  defp attach(%Candidate{} = candidate, cards) do
    case Map.get(cards, Name.normalize(candidate.name)) do
      nil ->
        candidate

      %Suggestion{} = suggestion ->
        %{
          candidate
          | card: suggestion.card,
            price_usd: suggestion.price_usd,
            resolved?: suggestion.resolved?
        }
    end
  end
end
