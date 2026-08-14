defmodule Deckex.Analysis.ReportDiff do
  @moduledoc """
  What changed between two reports, by finding code.

  The three buckets answer the owner's actual question about a proposed set
  of changes: what does it fix (**resolved**), what does it leave open
  (**remaining**), and what does it break (**introduced**) — cutting a land
  to fit a spell can starve the mana base, and this is where that shows up.
  """

  alias Deckex.Analysis.Finding
  alias Deckex.Analysis.Report

  @type t :: %{resolved: [Finding.t()], remaining: [Finding.t()], introduced: [Finding.t()]}

  @doc """
  Diffs findings by code. `resolved` and `remaining` carry the *before*
  finding (its evidence is what the owner has been looking at); `introduced`
  carries the *after* finding, because it did not exist before.
  """
  @spec diff(Report.t(), Report.t()) :: t()
  def diff(%Report{} = before_report, %Report{} = after_report) do
    codes_after = MapSet.new(after_report.findings, & &1.code)
    codes_before = MapSet.new(before_report.findings, & &1.code)

    {remaining, resolved} =
      Enum.split_with(before_report.findings, &MapSet.member?(codes_after, &1.code))

    %{
      resolved: resolved,
      remaining: remaining,
      introduced: Enum.reject(after_report.findings, &MapSet.member?(codes_before, &1.code))
    }
  end
end
