defmodule Deckex.Analysis.Finding do
  @moduledoc """
  One thing the engine noticed about a deck.

  A finding carries its `evidence` — the raw numbers behind it — and the
  `card_names` implicated, because a number the user cannot drill into is a
  number they cannot act on. `title` and `detail` are shown to the user and are
  therefore pt-BR.
  """

  @type severity :: :critical | :warning | :info
  @type lens :: :speed_curve | :mana_ramp | :interaction | :consistency

  @type t :: %__MODULE__{
          code: String.t(),
          severity: severity(),
          lens: lens(),
          title: String.t(),
          detail: String.t(),
          evidence: map(),
          card_names: [String.t()]
        }

  @enforce_keys [:code, :severity, :lens, :title, :detail]
  defstruct [:code, :severity, :lens, :title, :detail, evidence: %{}, card_names: []]

  @rank %{critical: 0, warning: 1, info: 2}

  @spec new(String.t(), severity(), lens(), String.t(), String.t(), keyword()) :: t()
  def new(code, severity, lens, title, detail, opts \\ [])
      when severity in [:critical, :warning, :info] and
             lens in [:speed_curve, :mana_ramp, :interaction, :consistency] do
    %__MODULE__{
      code: code,
      severity: severity,
      lens: lens,
      title: title,
      detail: detail,
      evidence: Keyword.get(opts, :evidence, %{}),
      card_names: Keyword.get(opts, :card_names, [])
    }
  end

  @spec critical?(t()) :: boolean()
  def critical?(%__MODULE__{severity: severity}), do: severity == :critical

  @doc "Most severe first — the order the deck screen lists them in."
  @spec sort([t()]) :: [t()]
  def sort(findings), do: Enum.sort_by(findings, &@rank[&1.severity])
end
