defmodule Deckex.Moxfield.Http do
  @moduledoc """
  Moxfield adapter over `Req`.

  One request per call, an identifiable and configurable User-Agent, and no
  retry — see `Deckex.Moxfield` for why this client is deliberately naive about
  being blocked. Every failure maps to a domain error whose message points the
  user at the paste path, because that is the path that always works.
  """
  @behaviour Deckex.Moxfield.Client

  alias Deckex.Error
  alias Deckex.Moxfield.DeckMapper

  @endpoint "https://api2.moxfield.com/v3/decks/all"
  @default_user_agent "deckex/0.1 (personal deck analysis tool)"
  @paste_hint "Você pode colar a lista exportada aqui do lado."

  @impl Deckex.Moxfield.Client
  def fetch_deck(public_id) when is_binary(public_id) do
    case Req.get(request(public_id)) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        DeckMapper.to_decklist(body)

      {:ok, %Req.Response{status: 200}} ->
        {:error, blocked("O Moxfield respondeu algo que não é um deck.", %{status: 200})}

      {:ok, %Req.Response{status: 401}} ->
        {:error,
         Error.new(:moxfield_private, "Esse deck é privado. #{@paste_hint}", %{status: 401})}

      {:ok, %Req.Response{status: 404}} ->
        {:error,
         Error.new(:moxfield_not_found, "Não achei esse deck no Moxfield.", %{status: 404})}

      {:ok, %Req.Response{status: status}} ->
        {:error,
         blocked("O Moxfield bloqueou a busca (#{status}). #{@paste_hint}", %{status: status})}

      {:error, reason} ->
        {:error,
         blocked("Não consegui falar com o Moxfield. #{@paste_hint}", %{reason: inspect(reason)})}
    end
  end

  @doc """
  The User-Agent sent to Moxfield. Configurable so an approved one can be
  dropped in without a code change.
  """
  @spec user_agent() :: String.t()
  def user_agent, do: config(:user_agent, @default_user_agent)

  defp blocked(message, details), do: Error.new(:moxfield_blocked, message, details)

  defp request(public_id) do
    [
      url: "#{@endpoint}/#{public_id}",
      headers: [{"user-agent", user_agent()}, {"accept", "application/json"}],
      receive_timeout: 15_000,
      retry: false
    ]
    |> Keyword.merge(config(:req_options, []))
    |> Req.new()
  end

  defp config(key, default) do
    :deckex |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
