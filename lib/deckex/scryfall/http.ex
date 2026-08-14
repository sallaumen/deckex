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

  alias Deckex.Error

  @endpoint "https://api.scryfall.com/cards/collection"
  @batch_size 75
  @throttle_ms 500
  @user_agent "deckex/0.1 (personal Commander deck analysis tool)"

  @impl Deckex.Scryfall.Client
  def fetch_by_names([]), do: {:ok, %{found: [], not_found: []}}

  def fetch_by_names(names) when is_list(names) do
    names
    |> Enum.chunk_every(@batch_size)
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{found: [], not_found: []}}, &fetch_batch/2)
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
      retry: false
    ]
    |> Keyword.merge(config(:req_options, []))
    |> Req.new()
  end

  defp throttle_ms, do: config(:throttle_ms, @throttle_ms)

  defp config(key, default) do
    :deckex |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
