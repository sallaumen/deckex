defmodule Deckex.Analysis.Consistency do
  @moduledoc """
  Whether the deck finds its pieces and can actually end a game.

  `single_points_of_failure` lists the roles the deck holds exactly one copy of.
  One sweeper, one tutor, one recursion outlet — each is a card that, once
  answered or buried, the deck simply cannot do any more.
  """

  alias Deckex.Analysis.Baselines
  alias Deckex.Analysis.DeckSnapshot
  alias Deckex.Analysis.Finding

  # Roles where holding exactly one copy is a structural risk. Draw and ramp are
  # excluded: nobody expects redundancy counted that way.
  @fragile_roles [:board_wipe, :tutor, :recursion, :graveyard_hate, :protection]

  @spec measure(DeckSnapshot.t()) :: map()
  def measure(snapshot) do
    nonlands = DeckSnapshot.nonlands(snapshot)

    %{
      draw: count_role(nonlands, :draw),
      tutors: count_role(nonlands, :tutor),
      recursion: count_role(nonlands, :recursion),
      wincons: count_role(nonlands, :wincon),
      single_points_of_failure: Enum.filter(@fragile_roles, &(count_role(nonlands, &1) == 1))
    }
  end

  @spec findings(DeckSnapshot.t(), Baselines.t()) :: [Finding.t()]
  def findings(snapshot, baselines) do
    measured = measure(snapshot)
    nonlands = DeckSnapshot.nonlands(snapshot)

    Enum.concat([
      draw_low(measured, nonlands, baselines),
      no_wincon(measured),
      single_point(measured)
    ])
  end

  defp draw_low(%{draw: draw}, nonlands, b) when draw < b.draw_target do
    [
      Finding.new(
        "consistency.draw_low",
        :warning,
        :consistency,
        "Pouca compra de carta",
        "#{draw} peças de vantagem de carta (alvo: #{b.draw_target}). " <>
          "Sem compra, a partida vira quem topa mais na sorte.",
        evidence: %{draw: draw, target: b.draw_target},
        card_names: nonlands |> DeckSnapshot.with_role(:draw) |> DeckSnapshot.names()
      )
    ]
  end

  defp draw_low(_measured, _nonlands, _baselines), do: []

  defp no_wincon(%{wincons: 0}) do
    [
      Finding.new(
        "consistency.no_wincon",
        :critical,
        :consistency,
        "Nenhuma win condition identificada",
        "Nenhuma carta foi classificada como plano de vitória. " <>
          "Ou falta um fecho, ou a classificação precisa de correção manual.",
        evidence: %{wincons: 0}
      )
    ]
  end

  defp no_wincon(_measured), do: []

  defp single_point(%{single_points_of_failure: []}), do: []

  defp single_point(%{single_points_of_failure: roles}) do
    [
      Finding.new(
        "consistency.single_point_of_failure",
        :warning,
        :consistency,
        "Efeitos sem redundância",
        "O deck tem exatamente uma carta para: #{Enum.join(roles, ", ")}. " <>
          "Cada uma é um ponto único de falha.",
        evidence: %{roles: roles}
      )
    ]
  end

  defp count_role(entries, role) do
    entries |> DeckSnapshot.with_role(role) |> DeckSnapshot.count()
  end
end
