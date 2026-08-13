defmodule Deckex.Moxfield do
  @moduledoc """
  Facade for the Moxfield port, plus URL parsing.

  **Moxfield has no public API and its Terms of Service prohibit scraping.**
  Programmatic access is gated behind a User-Agent approved by e-mailing
  support@moxfield.com; an honest, identifying User-Agent gets a Cloudflare 403
  (verified 2026-08-13). This client therefore:

  - sends one identifiable, configurable User-Agent — which is precisely what
    makes sanctioned access possible;
  - makes one request per explicit, user-initiated sync, never polling;
  - performs **no detection evasion** of any kind, and never will;
  - degrades to the paste path on any failure.

  Pasting a decklist is the primary import path. This one is wired for the day
  Moxfield approves a User-Agent.
  """
  @behaviour Deckex.Moxfield.Client

  alias Deckex.Error

  @adapter Application.compile_env(
             :deckex,
             [Deckex.Moxfield.Client, :adapter],
             Deckex.Moxfield.Http
           )

  @deck_url ~r{moxfield\.com/decks/([A-Za-z0-9_-]+)}
  @bare_id ~r/^[A-Za-z0-9_-]+$/

  @impl Deckex.Moxfield.Client
  defdelegate fetch_deck(public_id), to: @adapter

  @doc "Extracts the public id from a Moxfield deck URL, or accepts a bare id."
  @spec public_id_from_url(String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def public_id_from_url(url) when is_binary(url) do
    trimmed = String.trim(url)

    cond do
      captures = Regex.run(@deck_url, trimmed) -> {:ok, Enum.at(captures, 1)}
      Regex.match?(@bare_id, trimmed) -> {:ok, trimmed}
      true -> {:error, not_a_deck_url(trimmed)}
    end
  end

  defp not_a_deck_url(url) do
    Error.new(:moxfield_not_found, "Isso não parece um link de deck do Moxfield.", %{url: url})
  end
end
