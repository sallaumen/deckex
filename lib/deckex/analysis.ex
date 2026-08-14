defmodule Deckex.Analysis do
  @moduledoc """
  The diagnostic engine: a pure function from a loaded deck to a measured report.

  No Repo, no HTTP, no process state. `Deckex.Decks.snapshot/1` does the one
  database read; everything here is arithmetic over structs in memory, which is
  why reports are computed on demand and never cached — it costs microseconds,
  and a cache would only buy staleness bugs.
  """

  alias Deckex.Analysis.Baselines
  alias Deckex.Analysis.Bracket
  alias Deckex.Analysis.Consistency
  alias Deckex.Analysis.Curve
  alias Deckex.Analysis.DeckSnapshot
  alias Deckex.Analysis.Finding
  alias Deckex.Analysis.Interaction
  alias Deckex.Analysis.Mana
  alias Deckex.Analysis.Report

  @doc "Measures `snapshot` against `baselines`."
  @spec report(DeckSnapshot.t(), Baselines.t()) :: Report.t()
  def report(%DeckSnapshot{} = snapshot, baselines \\ Baselines.default()) do
    %Report{
      deck_id: snapshot.deck_id,
      deck_name: snapshot.deck_name,
      color_identity: snapshot.color_identity,
      curve: Curve.measure(snapshot),
      mana: Mana.measure(snapshot, baselines),
      interaction: Interaction.measure(snapshot),
      consistency: Consistency.measure(snapshot),
      bracket: Bracket.floor(snapshot),
      findings: findings(snapshot, baselines)
    }
  end

  defp findings(snapshot, baselines) do
    [Curve, Mana, Interaction, Consistency]
    |> Enum.flat_map(& &1.findings(snapshot, baselines))
    |> Finding.sort()
  end
end
