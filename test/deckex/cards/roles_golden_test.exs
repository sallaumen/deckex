defmodule Deckex.Cards.RolesGoldenTest do
  @moduledoc """
  The rule engine's blast radius, visible in `mix test`.

  Every Scryfall fixture in the repo, classified, against a committed
  snapshot. A rule change that touches ANY of these cards fails here first —
  in CI, before the dev-catalogue diff, before a briefing miscounts.

  This exists because every regex change this engine has taken moved cards
  nobody expected: the reminder-text strip turned a cycling land back into a
  land, the Overload rule amplified a Mizzix's Mastery false positive, and
  none of it was visible in unit tests that each look at one card.

  **When a change here is intentional:** regenerate the snapshot with

      mix deckex.roles.golden

  paste the output over `@golden`, and review the diff line by line in the
  commit — the review IS the point. A row you cannot defend as a player is a
  rule that needs a guard, not a snapshot that needs updating.
  """
  use ExUnit.Case, async: true

  alias Deckex.Cards.Card
  alias Deckex.Cards.Roles
  alias Deckex.Cards.ScryfallMapper

  @fixtures Path.join([__DIR__, "..", "..", "support", "fixtures", "scryfall"])

  @golden %{
    agadeems_awakening: ~w(ritual)a,
    alania_divergent_storm: ~w()a,
    apex_devastator: ~w()a,
    arachnogenesis: ~w()a,
    archmage_emeritus: ~w(draw)a,
    arid_mesa: ~w(fixing)a,
    baral_chief_of_compliance: ~w(cost_reduction draw)a,
    blasphemous_act: ~w(board_wipe)a,
    brain_freeze: ~w(mill)a,
    bria_riptide_rogue: ~w(anthem)a,
    chaos_warp: ~w(spot_removal)a,
    clever_concealment: ~w(protection)a,
    command_tower: ~w(fixing)a,
    counterspell: ~w(counter)a,
    cultivate: ~w(fixing ramp)a,
    desperate_ritual: ~w(ritual)a,
    diabolic_edict: ~w(spot_removal)a,
    drannith_magistrate: ~w(hoser)a,
    endurance: ~w(free_spell graveyard_hate)a,
    fact_or_fiction: ~w(draw)a,
    faithless_looting: ~w(draw recursion)a,
    felidar_sovereign: ~w(wincon)a,
    finale_of_devastation: ~w(anthem tutor)a,
    flusterstorm: ~w(counter stax)a,
    force_of_will: ~w(counter free_spell)a,
    forest: ~w()a,
    glorious_anthem: ~w(anthem)a,
    goblin_anarchomancer: ~w(cost_reduction)a,
    goblin_electromancer: ~w(cost_reduction)a,
    grave_pact: ~w(forced_sacrifice)a,
    hullbreaker_horror: ~w(counter spot_removal)a,
    humility: ~w(hoser)a,
    island: ~w()a,
    ketria_triome: ~w(fixing)a,
    koma: ~w(protection token_engine)a,
    krarks_thumb: ~w(chaos)a,
    light_up_the_stage: ~w(draw)a,
    llanowar_elves: ~w(ramp)a,
    mystical_tutor: ~w(tutor)a,
    natures_lore: ~w(fixing ramp)a,
    oust: ~w(spot_removal)a,
    overwhelming_victory: ~w(spot_removal)a,
    perplexing_test: ~w(board_wipe)a,
    reliquary_tower: ~w()a,
    resculpt: ~w(spot_removal)a,
    rhystic_study: ~w(draw stax taxation)a,
    smothering_tithe: ~w(fixing ramp taxation)a,
    sol_ring: ~w(ramp)a,
    spectral_procession: ~w()a,
    steam_vents: ~w(fixing)a,
    stitchers_supplier: ~w()a,
    storm_kiln_artist: ~w(fixing ramp)a,
    subtlety: ~w(counter free_spell)a,
    swiftfoot_boots: ~w(protection)a,
    talrand_sky_summoner: ~w(token_engine)a,
    tergrid: ~w(theft)a,
    toxic_deluge: ~w(board_wipe)a,
    unsummon: ~w(spot_removal)a,
    warp_world: ~w()a,
    weapon_surge: ~w()a,
    winds_of_abandon: ~w(board_wipe spot_removal)a,
    young_pyromancer: ~w(token_engine)a
  }

  test "every fixture classifies exactly as the committed snapshot says" do
    actual =
      @fixtures
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Map.new(fn file ->
        kinds =
          struct!(
            Card,
            @fixtures
            |> Path.join(file)
            |> File.read!()
            |> Jason.decode!()
            |> ScryfallMapper.to_attrs()
          )
          |> Roles.classify()
          |> Enum.map(& &1.kind)
          |> Enum.sort()

        {String.to_atom(Path.rootname(file)), kinds}
      end)

    drifted =
      for {name, kinds} <- actual, Map.get(@golden, name) != kinds do
        "  #{name}: esperado #{inspect(Map.get(@golden, name))}, veio #{inspect(kinds)}"
      end

    missing =
      for {name, _kinds} <- @golden,
          not Map.has_key?(actual, name),
          do: "  #{name} (fixture sumiu)"

    assert drifted == [] and missing == [],
           """
           A classificação por regras mudou. Se foi de propósito, rode
           `mix deckex.roles.golden`, cole a saída sobre @golden e defenda cada
           linha do diff no commit:

           #{Enum.join(drifted ++ missing, "\n")}
           """
  end
end
