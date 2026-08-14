defmodule Deckex.Optimizations.Salt do
  @moduledoc """
  The tactics an owner may ask a run to avoid, and the roles that detect them.

  "Salt" is table slang for the plays that make people stop enjoying the game.
  It is a matter of taste, not of power, which is why it is a per-run contract
  field and never a default: the engine has no opinion about whether counters
  are rude.

  Only `evitar` is enforceable. The audit refuses an add carrying an avoided
  role, exactly like the price ceiling. `quero` goes into the briefing as an
  invitation — no engine can force a model to have an idea, and pretending
  otherwise would be the same overreach as inventing a price.
  """

  @tactics [
    %{key: "counter", role: :counter, label: "counters"},
    %{key: "stax", role: :stax, label: "stax / prisão"},
    %{key: "mass_land_denial", role: :mass_land_denial, label: "destruição de terreno"},
    %{key: "extra_turn", role: :extra_turn, label: "turnos extras"},
    %{key: "graveyard_hate", role: :graveyard_hate, label: "ódio a cemitério"},
    %{key: "mill", role: :mill, label: "mill"}
  ]

  # The two tactics the bracket engine reads as bracket-4 markers. Wanting
  # either under a lower cap is a contract at war with itself.
  @bracket_four ~w(mass_land_denial extra_turn)

  @doc "Every tactic the owner can rule on, in display order."
  @spec tactics() :: [%{key: String.t(), role: atom(), label: String.t()}]
  def tactics, do: @tactics

  @doc "The roles set to `evitar`, keyed by role, carrying the pt-BR label."
  @spec avoided(map() | nil) :: %{atom() => String.t()}
  def avoided(nil), do: %{}

  def avoided(salt) do
    @tactics
    |> Enum.filter(&(Map.get(salt, &1.key) == "evitar"))
    |> Map.new(&{&1.role, &1.label})
  end

  @doc "The pt-BR labels the owner actively asked for."
  @spec wanted(map() | nil) :: [String.t()]
  def wanted(nil), do: []

  def wanted(salt) do
    @tactics |> Enum.filter(&(Map.get(salt, &1.key) == "quero")) |> Enum.map(& &1.label)
  end

  @doc "A named preset, as a full salt map."
  @spec preset(String.t()) :: map()
  def preset("mesa_tranquila") do
    Map.new(@tactics, fn tactic ->
      calm = if tactic.key in ["counter", "graveyard_hate"], do: "tanto_faz", else: "evitar"

      {tactic.key, calm}
    end)
  end

  def preset("sem_freio"), do: Map.new(@tactics, &{&1.key, "tanto_faz"})

  @doc """
  The reason this contract cannot be honoured, or nil.

  Caught at launch rather than mid-run: every such add would be refused by the
  bracket guard anyway, one paid consult at a time.
  """
  @spec contradiction(map()) :: String.t() | nil
  def contradiction(%{"bracket_max" => max, "salt" => salt})
      when is_integer(max) and max <= 3 do
    wanted =
      @tactics
      |> Enum.filter(&(&1.key in @bracket_four and Map.get(salt || %{}, &1.key) == "quero"))
      |> Enum.map(& &1.label)

    if wanted != [] do
      "Você pediu #{Enum.join(wanted, " e ")}, e isso leva o deck ao Bracket 4 — acima do teto de Bracket #{max} que você escolheu. Suba o bracket ou tire o pedido."
    end
  end

  def contradiction(_contract), do: nil
end
