defmodule Deckex.Analysis.Mana do
  @moduledoc """
  The mana base: how many lands, in which colours, and how fast the deck can
  accelerate.

  Three things here are easy to get wrong and are handled explicitly:

  1. **An MDFC whose back is a land counts as half a land.** It is a spell you
     can also play as a land, and modern decks lean on this enough that ignoring
     it misreports the land count outright.
  2. **The land target is derived, not fixed.** A deck averaging 2.6 with twelve
     ramp pieces genuinely wants fewer lands than one averaging 3.9 with six.
  3. **Colour sources are compared against the heaviest pip demand**, not the
     total. Eight cards wanting `{B}{B}` need roughly 25 black sources whether
     the deck holds eight of them or eighty.
  """

  alias Deckex.Analysis.Baselines
  alias Deckex.Analysis.CardEntry
  alias Deckex.Analysis.DeckSnapshot
  alias Deckex.Analysis.Finding

  @enters_tapped ~r/enters tapped/i

  @spec measure(DeckSnapshot.t(), Baselines.t()) :: map()
  def measure(snapshot, baselines) do
    lands = DeckSnapshot.lands(snapshot)
    nonlands = DeckSnapshot.nonlands(snapshot)
    ramp = DeckSnapshot.with_role(nonlands, :ramp)
    taplands = Enum.filter(lands, &tapland?/1)

    %{
      land_count: land_count(snapshot),
      land_target: land_target(snapshot, baselines),
      mdfc_lands: snapshot |> DeckSnapshot.mdfc_lands() |> DeckSnapshot.count(),
      ramp_total: DeckSnapshot.count(ramp),
      ramp_cheap: ramp |> Enum.filter(&(CardEntry.cmc(&1) <= 2)) |> DeckSnapshot.count(),
      ramp_by_band: ramp_by_band(ramp),
      taplands: DeckSnapshot.count(taplands),
      tapland_share: share(DeckSnapshot.count(taplands), DeckSnapshot.count(lands)),
      colors: colors(snapshot, baselines)
    }
  end

  @doc """
  The land count this deck actually wants: the baseline, pushed up by expensive
  spells and pulled down by ramp, clamped to the rails.
  """
  @spec land_target(DeckSnapshot.t(), Baselines.t()) :: integer()
  def land_target(snapshot, baselines) do
    nonlands = DeckSnapshot.nonlands(snapshot)
    count = DeckSnapshot.count(nonlands)
    avg = avg_cmc(nonlands, count)
    ramp = DeckSnapshot.count(DeckSnapshot.with_role(nonlands, :ramp))

    (baselines.land_base + cost_adjustment(avg, baselines) - ramp_adjustment(ramp, baselines))
    |> max(baselines.land_min)
    |> min(baselines.land_max)
  end

  @spec findings(DeckSnapshot.t(), Baselines.t()) :: [Finding.t()]
  def findings(snapshot, baselines) do
    measured = measure(snapshot, baselines)
    nonlands = DeckSnapshot.nonlands(snapshot)

    Enum.concat([
      land_count_findings(measured),
      ramp_findings(measured, nonlands, baselines),
      tapland_findings(measured, snapshot, baselines),
      color_findings(measured, snapshot)
    ])
  end

  # --- findings -------------------------------------------------------------

  defp land_count_findings(%{land_count: count, land_target: target}) do
    cond do
      count < target - 1 ->
        [
          Finding.new(
            "mana.land_count_low",
            :critical,
            :mana_ramp,
            "Poucos terrenos para o custo do deck",
            "#{fmt(count)} terrenos efetivos contra um alvo de #{target}. " <>
              "Travar em terreno é a forma mais comum de perder sem jogar.",
            evidence: %{land_count: count, target: target}
          )
        ]

      count > target + 2 ->
        [
          Finding.new(
            "mana.land_count_high",
            :warning,
            :mana_ramp,
            "Terrenos demais para o custo do deck",
            "#{fmt(count)} terrenos efetivos contra um alvo de #{target}. " <>
              "Sobra terreno onde cabia ação.",
            evidence: %{land_count: count, target: target}
          )
        ]

      true ->
        []
    end
  end

  defp ramp_findings(%{ramp_total: total, ramp_cheap: cheap}, nonlands, b) do
    names = nonlands |> DeckSnapshot.with_role(:ramp) |> DeckSnapshot.names()

    Enum.concat(ramp_low(total, names, b), ramp_slow(total, cheap, names, b))
  end

  defp ramp_low(total, names, b) when total < b.ramp_target do
    [
      Finding.new(
        "mana.ramp_low",
        :warning,
        :mana_ramp,
        "Pouca aceleração",
        "#{total} peças de ramp contra um alvo de #{b.ramp_target}. " <>
          "Rituais e redutores de custo não contam aqui — eles não te fazem " <>
          "baixar uma carta cara um turno antes com o campo vazio.",
        evidence: %{ramp: total, target: b.ramp_target},
        card_names: names
      )
    ]
  end

  defp ramp_low(_total, _names, _baselines), do: []

  defp ramp_slow(total, cheap, names, b)
       when total >= b.ramp_target and cheap < b.ramp_cheap_target do
    [
      Finding.new(
        "mana.ramp_too_slow",
        :warning,
        :mana_ramp,
        "Aceleração cara demais",
        "Só #{cheap} das #{total} peças de ramp custam 2 ou menos " <>
          "(alvo: #{b.ramp_cheap_target}). Ramp de 4 mana não adianta o jogo.",
        evidence: %{cheap: cheap, total: total, target: b.ramp_cheap_target},
        card_names: names
      )
    ]
  end

  defp ramp_slow(_total, _cheap, _names, _baselines), do: []

  defp tapland_findings(%{tapland_share: share, taplands: taplands}, snapshot, b)
       when share > b.tapland_share_max do
    [
      Finding.new(
        "mana.tapland_heavy",
        :warning,
        :mana_ramp,
        "Muito terreno entrando virado",
        "#{taplands} terrenos entram virados (#{percent(share)} da base). " <>
          "Cada um é meio turno perdido.",
        evidence: %{taplands: taplands, share: share},
        card_names:
          snapshot |> DeckSnapshot.lands() |> Enum.filter(&tapland?/1) |> DeckSnapshot.names()
      )
    ]
  end

  defp tapland_findings(_measured, _snapshot, _baselines), do: []

  defp color_findings(%{colors: colors}, snapshot) do
    Enum.flat_map(colors, fn {colour, measured} -> color_finding(colour, measured, snapshot) end)
  end

  defp color_finding(colour, %{sources: sources, max_pips: pips, target: target}, snapshot)
       when sources < target and pips > 0 do
    [
      Finding.new(
        "mana.color_starved",
        :critical,
        :mana_ramp,
        "Poucas fontes de #{colour}",
        "#{sources} fontes de #{colour} para uma exigência máxima de " <>
          "#{pips} pip(s) (alvo: #{target}). As cartas abaixo travam na mão.",
        evidence: %{color: colour, sources: sources, max_pips: pips, target: target},
        card_names: snapshot |> demanding(colour, pips) |> DeckSnapshot.names()
      )
    ]
  end

  defp color_finding(_colour, _measured, _snapshot), do: []

  # --- maths ----------------------------------------------------------------

  defp land_count(snapshot) do
    full = snapshot |> DeckSnapshot.lands() |> DeckSnapshot.count()
    halves = snapshot |> DeckSnapshot.mdfc_lands() |> DeckSnapshot.count()

    full + halves * 0.5
  end

  defp cost_adjustment(avg, b) when avg > b.avg_cmc_high, do: ceil((avg - b.avg_cmc_high) / 0.25)
  defp cost_adjustment(_avg, _baselines), do: 0

  defp ramp_adjustment(ramp, b) when ramp > b.ramp_target, do: div(ramp - b.ramp_target, 3)
  defp ramp_adjustment(_ramp, _baselines), do: 0

  defp ramp_by_band(ramp) do
    %{
      cheap: ramp |> Enum.filter(&(CardEntry.cmc(&1) <= 2)) |> DeckSnapshot.count(),
      mid: ramp |> Enum.filter(&(CardEntry.cmc(&1) == 3)) |> DeckSnapshot.count(),
      late: ramp |> Enum.filter(&(CardEntry.cmc(&1) >= 4)) |> DeckSnapshot.count()
    }
  end

  defp colors(snapshot, baselines) do
    Map.new(snapshot.color_identity, fn colour ->
      pips = max_pips(snapshot, colour)

      {colour,
       %{
         sources: sources(snapshot, colour),
         max_pips: pips,
         target: source_target(pips, baselines)
       }}
    end)
  end

  defp sources(%{main: main}, colour) do
    main |> Enum.filter(&produces?(&1, colour)) |> DeckSnapshot.count()
  end

  defp produces?(%{card: card}, colour), do: colour in (card.produced_mana || [])

  defp max_pips(snapshot, colour) do
    snapshot
    |> DeckSnapshot.nonlands()
    |> Enum.map(&CardEntry.pips(&1, colour))
    |> Enum.max(fn -> 0 end)
  end

  defp demanding(snapshot, colour, pips) do
    snapshot |> DeckSnapshot.nonlands() |> Enum.filter(&(CardEntry.pips(&1, colour) >= pips))
  end

  defp source_target(0, _baselines), do: 0
  defp source_target(1, b), do: b.sources_single_pip
  defp source_target(2, b), do: b.sources_double_pip
  defp source_target(_three_or_more, b), do: b.sources_triple_pip

  defp tapland?(%{card: card}), do: (card.oracle_text || "") =~ @enters_tapped

  defp avg_cmc(_nonlands, 0), do: 0.0

  defp avg_cmc(nonlands, count) do
    Enum.sum(Enum.map(nonlands, &(CardEntry.cmc(&1) * &1.quantity))) / count
  end

  defp share(_part, 0), do: 0.0
  defp share(part, whole), do: Float.round(part / whole, 3)

  # Always a float: the land count adds `halves * 0.5`, so even a deck with no
  # MDFCs comes through as 36.0 rather than 36.
  defp fmt(value), do: :erlang.float_to_binary(value, decimals: 1)

  defp percent(share), do: "#{round(share * 100)}%"
end
