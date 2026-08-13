defmodule Deckex.Cards.RoleMatch do
  @moduledoc """
  One role a rule (or the AI) assigned to a card, with the confidence behind it
  and the evidence that produced it.

  Evidence is not decoration. Every number the app shows is a count of these,
  and the user must be able to click a number and see why each card is in it —
  otherwise a wrong rule is indistinguishable from a wrong deck.
  """

  @kinds ~w(ramp ritual cost_reduction fixing counter spot_removal board_wipe
            protection draw tutor recursion wincon graveyard_hate stax)a

  @type kind :: atom()
  @type confidence :: :high | :medium | :low
  @type t :: %__MODULE__{kind: kind(), confidence: confidence(), evidence: String.t()}

  @enforce_keys [:kind, :confidence, :evidence]
  defstruct [:kind, :confidence, :evidence]

  @doc "Every role a card can hold."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "Builds a match, rejecting a kind outside the vocabulary."
  @spec new(kind(), confidence(), String.t()) :: t()
  def new(kind, confidence, evidence)
      when kind in @kinds and confidence in [:high, :medium, :low] and is_binary(evidence) do
    %__MODULE__{kind: kind, confidence: confidence, evidence: evidence}
  end
end
