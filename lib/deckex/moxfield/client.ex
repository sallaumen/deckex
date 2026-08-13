defmodule Deckex.Moxfield.Client do
  @moduledoc """
  Port for fetching a deck from Moxfield. The real adapter is
  `Deckex.Moxfield.Http`; tests use `Deckex.Moxfield.Mock`.
  """

  @callback fetch_deck(public_id :: String.t()) ::
              {:ok, %{name: String.t(), decklist: String.t()}} | {:error, Deckex.Error.t()}
end
