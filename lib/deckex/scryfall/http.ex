defmodule Deckex.Scryfall.Http do
  @moduledoc """
  Scryfall adapter over `Req`.

  Two published limits shape this module. `POST /cards/collection` accepts at
  most **75 identifiers per request**, and that endpoint is capped at **2
  requests/second** — tighter than the 10/s the rest of the API allows. So names
  are chunked by 75 and every request after the first waits out the throttle
  window. A 100-card Commander deck therefore costs two requests.

  Scryfall also requires a descriptive `User-Agent` and an explicit `Accept`
  header on every request; both are set here.
  """
  @behaviour Deckex.Scryfall.Client

  require Logger

  alias Deckex.Error
  alias Deckex.Log

  @endpoint "https://api.scryfall.com/cards/collection"
  @batch_size 75
  @throttle_ms 500
  @user_agent "deckex/0.1 (personal Commander deck analysis tool)"

  @impl Deckex.Scryfall.Client
  def fetch_by_names([]), do: {:ok, %{found: [], not_found: []}}

  def fetch_by_names(names) when is_list(names) do
    chunks = Enum.chunk_every(names, @batch_size)
    started = System.monotonic_time(:millisecond)

    result =
      chunks
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, %{found: [], not_found: []}}, &fetch_batch/2)

    log(result, length(names), length(chunks), System.monotonic_time(:millisecond) - started)

    result
  end

  # This module spends the one budget in the app that is not ours to spend: two
  # requests a second, 75 identifiers each. How many requests a deck import
  # actually costs, and how long the throttle held it, was until now knowable
  # only by reading this source and doing the arithmetic.
  defp log({:ok, %{found: found, not_found: missing}}, asked, requests, ms) do
    Logger.info(
      "Scryfall: #{Log.count(asked, "nome", "nomes")} em " <>
        "#{Log.count(requests, "requisição", "requisições")} — " <>
        "#{length(found)} achados, #{length(missing)} não · #{Log.duration(ms)}"
    )
  end

  defp log({:error, error}, asked, requests, ms) do
    Logger.warning(
      "Scryfall falhou depois de #{Log.count(requests, "requisição", "requisições")} " <>
        "(#{Log.count(asked, "nome", "nomes")}, #{Log.duration(ms)}): #{error.message}"
    )
  end

  defp fetch_batch({chunk, index}, {:ok, acc}) do
    if index > 0, do: Process.sleep(throttle_ms())

    case post_collection(chunk) do
      {:ok, batch} -> {:cont, {:ok, merge(acc, batch)}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp post_collection(names) do
    identifiers = Enum.map(names, &%{name: &1})

    case Req.post(request(), json: %{identifiers: identifiers}) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, %{found: body["data"] || [], not_found: not_found_names(body)}}

      {:ok, %Req.Response{status: status}} ->
        {:error,
         Error.new(
           :scryfall_unavailable,
           "A Scryfall respondeu #{status}. Tenta de novo em instantes.",
           %{status: status}
         )}

      {:error, reason} ->
        {:error,
         Error.new(
           :scryfall_unavailable,
           "Não consegui falar com a Scryfall.",
           %{reason: inspect(reason)}
         )}
    end
  end

  defp not_found_names(body) do
    body
    |> Map.get("not_found", [])
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
  end

  defp merge(acc, batch) do
    %{
      found: acc.found ++ batch.found,
      not_found: acc.not_found ++ batch.not_found
    }
  end

  @doc """
  Runs a Scryfall search and returns every page of results.

  Scryfall paginates at 175 cards; the Game Changers list is well under that
  today, but a query that grows past a page must not silently truncate — a
  half-read list of restricted cards is worse than no list.
  """
  @impl Deckex.Scryfall.Client
  def search(query) when is_binary(query) do
    collect_pages("https://api.scryfall.com/cards/search?q=#{URI.encode(query)}", [])
  end

  @doc """
  Every paper printing of one card, for pricing.

  `unique=prints` is a query *parameter*, not search syntax — the search
  endpoint collapses to one printing per card without it, which is exactly the
  behaviour this call exists to escape.

  Two exclusions. Digital-only printings have prices in a currency you cannot
  hand to a shop, and gold-bordered World Championship decks are cheap
  collectibles that are not the card: counting either as "the cheapest
  printing" would understate what buying this actually costs.

  A card with no paper printing answers 404, which `collect_pages` reports as
  an error — the caller keeps the price it already had rather than treating a
  missing answer as free.
  """
  @impl Deckex.Scryfall.Client
  def printings(oracle_id) when is_binary(oracle_id) do
    query = URI.encode("oracleid:#{oracle_id} game:paper -border:gold")

    collect_pages("https://api.scryfall.com/cards/search?q=#{query}&unique=prints", [])
  end

  defp collect_pages(nil, acc), do: {:ok, acc}

  defp collect_pages(url, acc) do
    case Req.get(request(url)) do
      {:ok, %Req.Response{status: 200, body: %{"data" => data} = body}} ->
        Process.sleep(throttle_ms())
        collect_pages(body["next_page"], acc ++ data)

      {:ok, %Req.Response{status: status}} ->
        {:error,
         Error.new(
           :scryfall_unavailable,
           "A Scryfall respondeu #{status} para a busca.",
           %{status: status}
         )}

      {:error, reason} ->
        {:error,
         Error.new(
           :scryfall_unavailable,
           "Não consegui falar com a Scryfall.",
           %{reason: inspect(reason)}
         )}
    end
  end

  defp request(url) do
    request() |> Req.merge(url: url)
  end

  defp request do
    [
      url: @endpoint,
      headers: [{"user-agent", @user_agent}, {"accept", "application/json"}],
      receive_timeout: 15_000,
      # Retried, and that is load-bearing. Without it a single 429 from the
      # rate limiter, a 503, or a dropped connection cost the entire batch —
      # and because the failure is only logged, the cards never reached the
      # catalogue and the suggestion table reported "não achei essa carta na
      # Scryfall" about cards Scryfall has. Measured over ten days: five
      # consults, ten real cards, silently dropped.
      #
      # `:transient` rather than Req's default `:safe_transient` because the
      # call that matters here is a POST. `POST /cards/collection` is a pure
      # lookup — it writes nothing and returns the same answer every time — so
      # retrying it is safe in the only sense that matters.
      retry: :transient,
      max_retries: 3
    ]
    |> Keyword.merge(config(:req_options, []))
    |> Req.new()
  end

  defp throttle_ms, do: config(:throttle_ms, @throttle_ms)

  defp config(key, default) do
    :deckex |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
