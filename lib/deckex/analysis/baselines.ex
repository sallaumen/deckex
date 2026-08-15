defmodule Deckex.Analysis.Baselines do
  @moduledoc """
  Every threshold the lenses test against, in one place.

  These are **heuristics for 99-card Commander**, not laws. They live here so a
  lens never hides a magic number, and so the user can tune them to their
  playgroup — a casual table and a cEDH table disagree about most of these.

  The colour-source targets follow the commonly cited Karsten-style framework:
  roughly 19 sources for a single coloured pip on curve, 25 for a double pip,
  31 for a triple.
  """

  @typedoc """
  `table_close_turn` is a fact about the owner's pod, not about Magic: the turn
  their games actually end. A deck that does nothing before turn five is in
  trouble where games close on seven and perfectly fine where they run to
  twelve. The engine cannot measure someone else's table, so the owner states
  it and every lens gets to use it.

  `table_time_max` is how many time-taking effects a deck may hold before the
  other three players start spending the evening watching.
  """
  @type t :: %__MODULE__{}

  defstruct avg_cmc_low: 2.4,
            avg_cmc_high: 3.5,
            avg_cmc_slow: 3.8,
            land_base: 36,
            land_min: 33,
            land_max: 40,
            ramp_target: 10,
            ramp_cheap_target: 4,
            early_play_target: 12,
            late_game_floor: 5,
            top_heavy_share: 0.20,
            interaction_target: 8,
            interaction_floor: 5,
            board_wipe_target: 2,
            draw_target: 8,
            sources_single_pip: 19,
            sources_double_pip: 25,
            sources_triple_pip: 31,
            tapland_share_max: 0.25,
            table_time_max: 4,
            blockers_target: 6,
            board_exposure_floor: 12,
            graveyard_exposure_floor: 8,
            table_close_turn: 8

  @doc "The documented Commander defaults."
  @spec default() :: t()
  def default, do: %__MODULE__{}
end
