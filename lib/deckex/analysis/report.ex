defmodule Deckex.Analysis.Report do
  @moduledoc """
  Everything the engine measured about one deck, at one moment.

  A report is computed on demand and never persisted as live state — a consult
  freezes a copy for reproducibility, which is a different thing.
  """

  alias Deckex.Analysis.Bracket
  alias Deckex.Analysis.Finding

  @type t :: %__MODULE__{
          deck_id: String.t(),
          deck_name: String.t(),
          color_identity: [String.t()],
          curve: map(),
          mana: map(),
          interaction: map(),
          consistency: map(),
          bracket: Bracket.t(),
          findings: [Finding.t()]
        }

  @derive Jason.Encoder
  @enforce_keys [
    :deck_id,
    :deck_name,
    :color_identity,
    :curve,
    :mana,
    :interaction,
    :consistency,
    :bracket,
    :findings
  ]
  defstruct [
    :deck_id,
    :deck_name,
    :color_identity,
    :curve,
    :mana,
    :interaction,
    :consistency,
    :bracket,
    :findings
  ]

  @doc "How many critical findings the deck has — the vital sign on a deck tile."
  @spec critical_count(t()) :: non_neg_integer()
  def critical_count(%__MODULE__{findings: findings}) do
    Enum.count(findings, &Finding.critical?/1)
  end

  @doc "The findings belonging to one lens."
  @spec by_lens(t(), Finding.lens()) :: [Finding.t()]
  def by_lens(%__MODULE__{findings: findings}, lens) do
    Enum.filter(findings, &(&1.lens == lens))
  end
end
