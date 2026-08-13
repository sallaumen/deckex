defmodule Deckex.Analysis.Curve do
  @moduledoc """
  How fast the deck acts, and whether it still has anything to do late.

  `curve.too_slow` deliberately requires **both** a high average cost and thin
  ramp: a deck averaging 3.9 with twelve ramp pieces is a ramp deck working as
  intended, not a slow one.
  """

  alias Deckex.Analysis.Baselines
  alias Deckex.Analysis.CardEntry
  alias Deckex.Analysis.DeckSnapshot
  alias Deckex.Analysis.Finding

  @spec measure(DeckSnapshot.t()) :: map()
  def measure(snapshot) do
    nonlands = DeckSnapshot.nonlands(snapshot)
    count = DeckSnapshot.count(nonlands)

    %{
      histogram: histogram(nonlands),
      avg_cmc: avg_cmc(nonlands, count),
      nonland_count: count,
      early_plays: count_at(nonlands, &(&1 <= 3)),
      late_game: count_at(nonlands, &(&1 >= 5)),
      top_heavy_share: share_at(nonlands, count, &(&1 >= 6))
    }
  end

  @spec findings(DeckSnapshot.t(), Baselines.t()) :: [Finding.t()]
  def findings(snapshot, baselines) do
    nonlands = DeckSnapshot.nonlands(snapshot)
    measured = measure(snapshot)
    ramp = DeckSnapshot.count(DeckSnapshot.with_role(nonlands, :ramp))

    Enum.concat([
      too_slow(measured, ramp, nonlands, baselines),
      no_early_plays(measured, nonlands, baselines),
      top_heavy(measured, nonlands, baselines),
      no_late_game(measured, baselines)
    ])
  end

  # --- findings -------------------------------------------------------------

  defp too_slow(%{avg_cmc: avg}, ramp, nonlands, b)
       when avg > b.avg_cmc_slow and ramp < b.ramp_target do
    [
      Finding.new(
        "curve.too_slow",
        :critical,
        :speed_curve,
        "Deck lento demais para o ramp que tem",
        "Custo médio #{fmt(avg)} com só #{ramp} peças de aceleração. " <>
          "Ou o custo cai, ou o ramp sobe.",
        evidence: %{avg_cmc: avg, ramp: ramp, ramp_target: b.ramp_target},
        card_names: nonlands |> expensive(b.avg_cmc_slow) |> DeckSnapshot.names()
      )
    ]
  end

  defp too_slow(_measured, _ramp, _nonlands, _baselines), do: []

  defp no_early_plays(%{early_plays: early}, nonlands, b) when early < b.early_play_target do
    [
      Finding.new(
        "curve.no_early_plays",
        :critical,
        :speed_curve,
        "Pouca coisa para fazer nos primeiros turnos",
        "Só #{early} cartas jogáveis com 3 de mana ou menos (alvo: #{b.early_play_target}). " <>
          "Contra deck agressivo, os turnos 1 a 3 passam em branco.",
        evidence: %{early_plays: early, target: b.early_play_target},
        card_names: nonlands |> cheap() |> DeckSnapshot.names()
      )
    ]
  end

  defp no_early_plays(_measured, _nonlands, _baselines), do: []

  defp top_heavy(%{top_heavy_share: share}, nonlands, b) when share > b.top_heavy_share do
    [
      Finding.new(
        "curve.top_heavy",
        :warning,
        :speed_curve,
        "Topo de curva pesado",
        "#{percent(share)} das mágicas custam 6 ou mais. " <>
          "Isso trava a mão quando o jogo não vai longe.",
        evidence: %{share: share, max: b.top_heavy_share},
        card_names: nonlands |> expensive(5.9) |> DeckSnapshot.names()
      )
    ]
  end

  defp top_heavy(_measured, _nonlands, _baselines), do: []

  defp no_late_game(%{late_game: late, avg_cmc: avg}, b)
       when late < b.late_game_floor and avg < b.avg_cmc_low do
    [
      Finding.new(
        "curve.no_late_game",
        :warning,
        :speed_curve,
        "Sem fôlego para o late game",
        "Custo médio #{fmt(avg)} e só #{late} cartas de 5 ou mais. " <>
          "Se a partida passar do turno 7, acaba a gasolina.",
        evidence: %{late_game: late, floor: b.late_game_floor, avg_cmc: avg}
      )
    ]
  end

  defp no_late_game(_measured, _baselines), do: []

  # --- maths ----------------------------------------------------------------

  defp histogram(nonlands) do
    Enum.reduce(nonlands, %{}, fn entry, acc ->
      bucket = entry |> CardEntry.cmc() |> trunc() |> min(7)

      Map.update(acc, bucket, entry.quantity, &(&1 + entry.quantity))
    end)
  end

  defp avg_cmc(_nonlands, 0), do: 0.0

  defp avg_cmc(nonlands, count) do
    total = Enum.sum(Enum.map(nonlands, &(CardEntry.cmc(&1) * &1.quantity)))

    Float.round(total / count, 2)
  end

  defp count_at(nonlands, predicate) do
    nonlands |> Enum.filter(&predicate.(CardEntry.cmc(&1))) |> DeckSnapshot.count()
  end

  defp share_at(_nonlands, 0, _predicate), do: 0.0

  defp share_at(nonlands, count, predicate) do
    Float.round(count_at(nonlands, predicate) / count, 3)
  end

  defp cheap(nonlands), do: Enum.filter(nonlands, &(CardEntry.cmc(&1) <= 3))
  defp expensive(nonlands, above), do: Enum.filter(nonlands, &(CardEntry.cmc(&1) > above))

  defp fmt(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp percent(share), do: "#{round(share * 100)}%"
end
