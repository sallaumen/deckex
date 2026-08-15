defmodule Deckex.Optimizations.Balance do
  @moduledoc """
  Walking the sandbox back to 100 cards, a card or two per stage.

  A Commander deck is exactly 100 cards, and a run that starts at 105 has to
  end at 100 or the list cannot go on a table. Until now the briefing merely
  *stated* the count and hoped: nothing asked a stage for a direction, and
  nothing stopped one from drifting further away.

  Two mechanisms, and the split between them is the point.

  **The briefing asks.** Each stage is given the gap and a specific net for
  itself — "end this stage at 103: two more cuts than adds" — capped at
  `@max_drift`, because a stage told to shed five cards at once stops choosing
  the worst five and starts choosing any five. Closing the gap slowly means
  every card that leaves was the worst card left when it left.

  **The engine caps.** It refuses the add that would take the copy *further*
  from 100, and the cut that would take it further the other way. It cannot do
  more than that: no rule can make a model want to cut a card, exactly as the
  salt contract can refuse a tactic but never demand one. Asking is how the gap
  closes; capping is how it never widens.

  The cap reads the answer's **net**, not a running count: cuts come first in
  an answer, so a stage that cuts three and adds three is a swap, not a drift,
  and judging card by card would have refused all three cuts on a deck that is
  short. Ordinary stages get a card or two of slack either way; the closing
  stage gets none, because landing exactly on 100 is its whole job.
  """

  @target 100
  @max_drift 2

  @doc "Cards in a legal Commander deck. One number, one place."
  @spec target() :: pos_integer()
  def target, do: @target

  @doc """
  The net change a stage at `count` cards should aim for.

  Negative means cut more than you add. Zero means keep the balance. Capped
  at two either way — the gap closes over stages, not in one.
  """
  @spec drift(non_neg_integer()) :: integer()
  def drift(count) when is_integer(count) do
    (@target - count)
    |> max(-@max_drift)
    |> min(@max_drift)
  end

  @doc """
  Where an answer may leave the count, and it depends on which stage is asking.

  An **ordinary stage** may drift up to `@max_drift` from the target, or stay
  within the distance the copy already had — whichever is more room. Forbidding
  a stage at exactly 100 from ever ending at 101 would be stricter than the
  owner asked for and would cost the model the freedom to take two good cards
  now and pay for them next stage. What is not allowed is running away: a copy
  at 105 may not reach 106.

  The **closing stage** has one job and no slack. Its bounds are the target
  itself, so the arithmetic of its answer either lands on 100 or is refused.
  """
  @spec bounds(non_neg_integer(), :stage | :closing) :: %{floor: integer(), ceiling: integer()}
  def bounds(count, mode \\ :stage)

  def bounds(_count, :closing), do: %{floor: @target, ceiling: @target}

  def bounds(count, :stage) do
    reach = max(abs(@target - count), @max_drift)

    %{floor: @target - reach, ceiling: @target + reach}
  end

  @doc """
  How much of an answer's net has to go back, and from which side.

  Judged on the **net**, never on a running count. Cuts come first in a
  consult's answer, so the count dips before it recovers: a copy 95 cards short
  would have had every cut refused for "moving away" before reaching the adds
  that pay for them. A swap is not a drift.
  """
  @spec surplus(integer(), non_neg_integer(), :stage | :closing) ::
          {:add | :cut, pos_integer()} | :none
  def surplus(net, count, mode \\ :stage) do
    %{floor: floor, ceiling: ceiling} = bounds(count, mode)
    final = count + net

    cond do
      final > ceiling -> {:add, final - ceiling}
      final < floor -> {:cut, floor - final}
      true -> :none
    end
  end

  @doc "Why the engine refused, in the owner's language."
  @spec refusal(:add | :cut) :: String.t()
  def refusal(:add) do
    "esta entrada afastaria a cópia das #{@target} cartas mais do que a rodada permite"
  end

  def refusal(:cut) do
    "este corte afastaria a cópia das #{@target} cartas mais do que a rodada permite"
  end

  @doc """
  What to ask this stage for, in English, for the briefing.

  Says the number to end on rather than only the direction: "more cuts than
  adds" is advice, "end at 103" is a target a model can check itself against.
  """
  @spec instruction(non_neg_integer()) :: String.t()
  def instruction(@target) do
    "The copy is at exactly #{@target} cards, which is where a Commander deck " <>
      "belongs. Keep it there: one card in for every card out."
  end

  def instruction(count) do
    drift = drift(count)
    goal = count + drift

    "The copy has **#{count} cards** and a Commander deck has exactly #{@target}. " <>
      "#{gap_sentence(count)} Aim to end this stage at **#{goal}** — " <>
      "#{net_sentence(drift)}. Do not try to close the whole gap in one stage: the " <>
      "stages after you will keep walking it back, and a stage told to shed five cards " <>
      "at once stops choosing the worst five and starts choosing any five. The engine " <>
      "refuses any change that moves the count further from #{@target}."
  end

  defp gap_sentence(count) when count > @target,
    do: "It is #{count - @target} over."

  defp gap_sentence(count), do: "It is #{@target - count} short."

  defp net_sentence(drift) when drift < 0,
    do: "propose #{abs(drift)} more cut(s) than add(s)"

  defp net_sentence(drift), do: "propose #{drift} more add(s) than cut(s)"
end
