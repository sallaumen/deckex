defmodule Deckex.Consults.Briefing do
  @moduledoc """
  Builds the prompt sent to the model. Pure: a report and a snapshot in,
  Markdown out.

  The prompt is written in English because that is what the model reasons best
  in and because card names, rules text and everything it will search for are
  English. The *answer* comes back in Portuguese — the schema asks for it.

  Two things it always carries, and both are load-bearing: the **full
  decklist**, because a model asked to suggest cuts must know what is there;
  and the **colour identity**, because a suggestion outside it is not merely
  bad, it is illegal.
  """

  alias Deckex.Analysis.DeckSnapshot
  alias Deckex.Analysis.Report

  @spec build(Report.t(), DeckSnapshot.t(), atom(), keyword()) :: String.t()
  def build(%Report{} = report, %DeckSnapshot{} = snapshot, lens, opts \\ []) do
    findings = scoped_findings(report, lens, opts[:finding_code])

    """
    You are helping tune a Magic: The Gathering **Commander (EDH)** deck.

    #{deck_block(report, snapshot)}

    #{measurements_block(report, lens)}

    #{findings_block(findings)}

    #{decklist_block(snapshot)}

    ## What to do

    #{task_block(lens, opts)}

    Rules you must respect:

    - Every card you add must be inside the deck's colour identity
      (#{identity(report)}). A card outside it is illegal, not merely bad.
    - Only suggest cutting cards that are actually in the list above.
    - Prefer changes that address a finding over changes that are merely
      upgrades.#{budget_line(opts[:budget_usd])}
    - Search the web for current Commander staples and prices where it helps.
      The measurements above are facts about this deck; the card pool is what
      you know and can look up.

    Answer in **Portuguese (pt-BR)**, but never translate a card name.
    """
  end

  defp deck_block(report, snapshot) do
    commanders =
      case snapshot.commanders do
        [] -> "none declared"
        entries -> Enum.map_join(entries, ", ", & &1.card.name)
      end

    """
    ## The deck

    - Name: #{report.deck_name}
    - Commander: #{commanders}
    - Colour identity: #{identity(report)}
    """
  end

  defp measurements_block(report, lens) do
    sections =
      lens
      |> lens_keys()
      |> Enum.map_join("\n\n", fn key -> section(key, Map.fetch!(report, key)) end)

    "## Measurements\n\n#{sections}"
  end

  # A finding-scoped or full consult sees everything; a lens consult sees its
  # own numbers plus the curve, which is context for every other lens.
  defp lens_keys(:speed_curve), do: [:curve]
  defp lens_keys(:mana_ramp), do: [:curve, :mana]
  defp lens_keys(:interaction), do: [:curve, :interaction]
  defp lens_keys(:consistency), do: [:curve, :consistency]
  defp lens_keys(_everything_else), do: [:curve, :mana, :interaction, :consistency]

  # Each lens asks a different question of the same measurements. The rules
  # below the task are identical for all of them, which is deliberate: a
  # suggestion outside the colour identity is illegal no matter what was asked.
  defp task_block(:matchup, opts) do
    against = opts[:against] || "an unspecified aggressive deck"

    """
    This deck keeps losing to: **#{against}**.

    Work out why, from the measurements above, and name specific cards to
    **cut** and to **add** that would change that matchup. Say in one sentence
    each why the card helps against *that* deck specifically.
    """
  end

  defp task_block(:budget, opts) do
    ceiling = opts[:budget_usd] || 20

    """
    Improve this deck **as cheaply as possible**. Every card you add must cost
    roughly US$ #{ceiling} or less.

    Name specific cards to **cut** and to **add**, and say in one sentence each
    what it fixes. A cheap card that addresses a finding beats an expensive one
    that does not.
    """
  end

  defp task_block(:upgrade, _opts) do
    """
    Make this deck **as strong as it can be, regardless of price**.

    Name specific cards to **cut** and to **add**, and say in one sentence each
    what it fixes. Do not hold back on cost here — a separate question exists
    for the budget version.
    """
  end

  defp task_block(_lens, _opts) do
    """
    Work the findings above. For each one, name specific cards to **cut** from
    the list and specific cards to **add**, and say why in one sentence each.
    """
  end

  defp section(key, measured) do
    lines =
      measured
      |> Enum.sort_by(fn {field, _value} -> to_string(field) end)
      |> Enum.map_join("\n", fn {field, value} -> "- #{field}: #{inspect(value)}" end)

    "### #{key}\n\n#{lines}"
  end

  defp findings_block([]) do
    "## Findings\n\nNone — the deck passed every lens. Suggest refinements only."
  end

  defp findings_block(findings) do
    body =
      Enum.map_join(findings, "\n\n", fn finding ->
        cards =
          case finding.card_names do
            [] -> ""
            names -> "\n  Cards involved: #{Enum.join(names, ", ")}"
          end

        "- **[#{finding.severity}] #{finding.code}** — #{finding.title}\n" <>
          "  #{finding.detail}\n  Evidence: #{inspect(finding.evidence)}#{cards}"
      end)

    "## Findings\n\n#{body}"
  end

  defp decklist_block(snapshot) do
    lines =
      snapshot.main
      |> Enum.sort_by(& &1.card.name)
      |> Enum.map_join("\n", fn entry ->
        cost = entry.card.mana_cost || "no cost"

        "#{entry.quantity} #{entry.card.name} — #{cost} — #{entry.card.type_line}"
      end)

    "## The full decklist\n\n```\n#{lines}\n```"
  end

  defp scoped_findings(report, :finding, code) when is_binary(code) do
    Enum.filter(report.findings, &(&1.code == code))
  end

  defp scoped_findings(report, lens, _code) when lens in [:full, :finding], do: report.findings

  defp scoped_findings(report, lens, _code) do
    Enum.filter(report.findings, &(&1.lens == lens))
  end

  defp identity(%Report{color_identity: []}), do: "colourless"
  defp identity(%Report{color_identity: colors}), do: Enum.join(colors, "")

  defp budget_line(nil), do: ""

  defp budget_line(budget) do
    "\n- Keep each added card under about US$ #{budget}; say so if the best answer costs more."
  end
end
