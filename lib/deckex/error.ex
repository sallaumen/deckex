defmodule Deckex.Error do
  @moduledoc """
  The domain error. Every operation that can fail for an *expected* reason
  returns `{:error, %Deckex.Error{}}` rather than raising — errors are data.

  Raising is reserved for genuine contract violations (a missing preload, an
  impossible state), which should crash loudly instead of being handled.
  """

  @typedoc "Every expected failure in the system has one of these codes."
  @type code ::
          :moxfield_blocked
          | :moxfield_private
          | :moxfield_not_found
          | :scryfall_unavailable
          | :cards_not_found
          | :empty_decklist
          | :deck_not_found
          | :consult_not_found
          | :not_commander_legal
          | :ai_timeout
          | :ai_unavailable

  @type t :: %__MODULE__{code: code(), message: String.t(), details: map()}

  defexception [:code, :message, details: %{}]

  @doc """
  Builds a domain error. `message` is user-facing and therefore pt-BR; `details`
  carries whatever the caller needs for logging or for rendering a richer UI.
  """
  @spec new(code(), String.t(), map()) :: t()
  def new(code, message, details \\ %{}) when is_atom(code) and is_binary(message) do
    %__MODULE__{code: code, message: message, details: details}
  end
end
