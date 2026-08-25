defmodule Deckex.Spellbook.Http do
  @moduledoc """
  Commander Spellbook adapter over `Req`.

  **Why this site and not the other one.** The EDHREC law in `AGENTS.md` stands
  and this does not touch it: Commander Spellbook publishes a documented REST
  API for exactly this purpose, its backend is MIT-licensed open source, and
  `find-my-combos` exists to be sent a decklist. One request per deck, on a
  list that changed, with an identifying User-Agent — the same manners the
  Scryfall client uses.

  The endpoint answers with four buckets; two are useful here. `included` is
  every combo the deck already assembles. `almostIncluded` is every combo it is
  **one card** from, and that is the half a deck being optimised wants: it
  turns "add a good card" into "add this card and these three become a line".

  The other two buckets are dropped on purpose. `includedByChangingCommanders`
  and `almostIncludedByAddingColors` answer a different question — what this
  deck could be if it were a different deck — and the Reimaginar mode is where
  that question belongs.
  """
  @behaviour Deckex.Spellbook.Client

  alias Deckex.Error

  @endpoint "https://backend.commanderspellbook.com/find-my-combos/"
  @user_agent "deckex/0.1 (personal Commander deck analysis tool)"

  @impl Deckex.Spellbook.Client
  def find_combos([], []), do: {:ok, %{included: [], almost: []}}

  def find_combos(main, commanders) do
    case Req.post(request(), json: %{commanders: entries(commanders), main: entries(main)}) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, buckets(body)}

      {:ok, %Req.Response{status: status}} ->
        {:error,
         Error.new(
           :spellbook_unavailable,
           "O Commander Spellbook respondeu #{status}. Os combos ficam como estavam.",
           %{status: status}
         )}

      {:error, reason} ->
        {:error,
         Error.new(
           :spellbook_unavailable,
           "Não consegui falar com o Commander Spellbook.",
           %{reason: inspect(reason)}
         )}
    end
  end

  defp entries(names), do: Enum.map(names, &%{card: &1, quantity: 1})

  # `results` is the shape the endpoint documents; anything else is a version
  # of the API this code has not met, and an empty answer is a better outcome
  # than a crash in a background job.
  defp buckets(%{"results" => results}) when is_map(results) do
    %{
      included: Map.get(results, "included") || [],
      almost: Map.get(results, "almostIncluded") || []
    }
  end

  defp buckets(_unexpected), do: %{included: [], almost: []}

  defp request do
    Req.new(
      url: @endpoint,
      headers: [{"user-agent", @user_agent}, {"accept", "application/json"}],
      receive_timeout: 20_000,
      retry: :transient,
      max_retries: 2
    )
    |> Req.merge(Application.get_env(:deckex, __MODULE__, [])[:req_options] || [])
  end
end
