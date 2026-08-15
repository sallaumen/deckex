defmodule Deckex.Analysis.Baselines do
  @moduledoc """
  Every threshold the lenses test against, in one place.

  These are **heuristics for 99-card Commander**, not laws. They live here so a
  lens never hides a magic number, and so the user can tune them to their
  playgroup — a casual table and a cEDH table disagree about most of these.

  The colour-source targets follow the commonly cited Karsten-style framework:
  roughly 19 sources for a single coloured pip on curve, 25 for a double pip,
  31 for a triple.

  **The shipped numbers now say who wrote them.** They previously did not, and
  a number presented without provenance reads as a fact — ours were one
  anonymous opinion, and behind the published revisions. `source/0` names the
  framework the defaults follow so the Ajustes panel can show it, and the owner
  can disagree with a named author instead of with the app.

  The draw and interaction targets were raised from 8 to 10 to match the
  Command Zone's 2025 revision, whose stated reason was that the format got
  faster and more threat-dense.

  `interaction_max` is the other half of a band nothing here modelled. No
  published source argues that more interaction is always better; the failure
  mode at the top end is documented and compared directly to stax — if nobody
  can keep a permanent on the board, nobody gets to play.
  """

  @source "Command Zone, revisão de 2025 (ep. 658), adaptado onde este motor conta diferente"

  @doc "The framework the shipped defaults follow, for the Ajustes panel."
  @spec source() :: String.t()
  def source, do: @source

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
            interaction_target: 10,
            interaction_floor: 5,
            interaction_max: 16,
            board_wipe_target: 2,
            draw_target: 10,
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
