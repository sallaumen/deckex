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

  alias Deckex.Analysis.Bracket
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

    #{bracket_block(report)}

    #{dossier_block(lens, opts)}

    #{optimization_block(opts[:optimization])}

    #{decklist_block(snapshot)}

    ## What to do

    #{task_block(lens, opts)}

    #{rules_block(lens, report, opts)}
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
    against = matchup_targets(opts[:against])

    """
    This deck keeps losing to: **#{against}**.

    Work out why, from the measurements above, and name specific cards to
    **cut** and to **add** that would change that matchup. Say in one sentence
    each why the card helps against *that* deck specifically.
    """
  end

  defp task_block(:budget, opts) do
    """
    Improve this deck **as cheaply as possible**.
    #{ceiling_lines(opts[:ceilings])}
    Name specific cards to **cut** and to **add**, and say in one sentence each
    what it fixes. A cheap card that addresses a finding beats an expensive one
    that does not.
    """
  end

  defp task_block(:upgrade, opts) do
    """
    Make this deck **as strong as it can be**. Power is the goal here; a
    separate question exists for the cheap version.
    #{ceiling_lines(opts[:ceilings])}
    Name specific cards to **cut** and to **add**, and say in one sentence each
    what it fixes.
    """
  end

  defp task_block(:bracket, _opts) do
    """
    Say which Commander Bracket this deck belongs in, and answer the two
    questions the measurements above cannot.

    The **floor** stated in the bracket section is arithmetic — Game Changers
    counted, mass land denial and extra turns detected. You may place the deck
    at that bracket or higher, never lower.

    What is left to you:

    - `combo`: is there a two-card combo that wins on the spot? Name both
      cards and the earliest turn it assembles. Bracket 3 tolerates one only
      if it cannot come together before turn 6.
    - `speed`: on which turn does this deck realistically close a game?
      Brackets expect at least 9 / 8 / 6 / 4 turns, or any turn for cEDH.

    Suggest no cuts and no adds. This question is about where the deck sits,
    not about changing it.
    """
  end

  defp task_block(:alinhamento, _opts) do
    """
    The dossier above is the **fixed reference**: it was written before any of
    this optimization's changes. Compare the current list against it.

    Does this deck still do what its dossier says it does? Propose changes
    ONLY where the optimization drifted from the stated purpose — a card that
    serves the plan poorly, a line of victory that got weakened, an identity
    the changes diluted. If nothing drifted, say so and propose nothing.
    """
  end

  defp task_block(:scout, _opts) do
    """
    Read this deck and write its strategic dossier — nothing else.

    - `plano`: what the deck is trying to do and how the commander enables it.
    - `sinergias`: the interactions that give this deck its identity, naming cards.
    - `linhas_de_vitoria`: how the deck actually closes a game.
    - `fraquezas`: ONLY what the measurements above do not show — dependencies
      and failure modes no number can see.

    Do not propose any change. Do not name cards to cut or to add. You are the
    scout, not the consultant.
    """
  end

  defp task_block(_lens, _opts) do
    """
    Work the findings above. For each one, name specific cards to **cut** from
    the list and specific cards to **add**, and say why in one sentence each.
    """
  end

  # The bracket is the vocabulary players actually use at a table, and the
  # headroom is the part nobody notices on their own: a deck sitting on three
  # Game Changers leaves bracket 3 with one more. Every consult run against
  # the reference deck suggested a fourth before this block existed.
  defp bracket_block(%Report{bracket: nil}), do: ""

  defp bracket_block(%Report{bracket: bracket}) do
    """
    ## Commander Bracket

    Measured floor: **Bracket #{bracket.floor}**. #{Enum.join(bracket.reasons, " ")}
    #{headroom_line(bracket)}
    """
  end

  defp headroom_line(bracket) do
    case Bracket.game_changer_headroom(bracket) do
      nil ->
        "The deck is already at a bracket 4 floor, so Game Changers are unrestricted."

      0 ->
        "**The deck is at the bracket 3 ceiling of 3 Game Changers.** Any Game Changer you add is the fourth and moves it to bracket 4 — if you suggest one, say so in `notes` and explain why it is worth the move."

      room ->
        "There is room for #{room} more Game Changer(s) before the deck leaves bracket 3."
    end
  end

  # The part of the prompt no template can write. The scout itself never sees
  # one — it must read the deck fresh, not be anchored by its own predecessor.
  defp dossier_block(:scout, _opts), do: ""
  defp dossier_block(_lens, opts), do: dossier_lines(opts[:dossier], opts[:dossier_stale])

  defp dossier_lines(nil, _stale), do: ""

  defp dossier_lines(dossier, stale) do
    """
    ## Leitura estratégica (dossiê do deck)

    - Plano: #{dossier["plano"]}
    - Sinergias: #{dossier["sinergias"]}
    - Linhas de vitória: #{dossier["linhas_de_vitoria"]}
    - Fraquezas que os números não veem: #{dossier["fraquezas"]}
    #{stale_line(stale)}
    This dossier is the owner's current understanding of the deck. Trust it as
    context — and when the list itself says otherwise, contradict it explicitly
    in `leitura`.
    """
  end

  defp stale_line(true) do
    "\nCaution: the deck has changed since this dossier was written — weigh it accordingly.\n"
  end

  defp stale_line(_fresh), do: ""

  # The scout only reads, so most of the consulting rules are noise to it.
  defp rules_block(:scout, _report, _opts) do
    """
    Search the web where it helps you understand a card's role in this deck.

    Answer in **Portuguese (pt-BR)**, but never translate a card name.
    """
  end

  defp rules_block(_lens, report, opts) do
    """
    Rules you must respect:

    - Write `leitura` first: your own reading of the deck's plan#{dossier_clause(opts[:dossier])},
      before choosing a single cut.
    - Every card you add must be inside the deck's colour identity
      (#{identity(report)}). A card outside it is illegal, not merely bad.
    - Only suggest cutting cards that are actually in the list above.
    - A card may appear once. Basic lands and cards whose own text allows any
      number are the only exceptions — Commander is singleton.
    - Prefer changes that address a finding over changes that are merely
      upgrades.#{budget_line(opts[:ceilings])}
    - **Never guess at legality or bans.** The app holds Scryfall's current
      legality for every card and checks each suggestion against it, so a card
      you are unsure about should be *suggested and verified*, not silently
      dropped. If you decline a card because you believe it is banned, say so
      explicitly in `notes` — a wrong belief that never becomes a suggestion
      is the one thing the app cannot check for you.
    - **Never state a price.** The app shows the current Scryfall price next to
      every suggestion, so a number from you can only disagree with it. Say
      "cheap" or "expensive" if it matters to the argument; leave the figure out.
    - Search the web for current Commander staples where it helps. The
      measurements above are facts about this deck; the card pool is what you
      know and can look up.

    Answer in **Portuguese (pt-BR)**, but never translate a card name.
    """
  end

  defp matchup_targets(nil), do: "an unspecified aggressive deck"
  defp matchup_targets(against) when is_binary(against), do: against
  defp matchup_targets(against) when is_list(against), do: Enum.join(against, "; ")

  # The pipeline's context: the contract every stage must respect, and the
  # changelog of what earlier stages did — with the model's reasons for what
  # went in and the ENGINE's reasons for what was refused. Disagreement is
  # welcome once, with engagement; the flip-flop guard makes twice impossible.
  defp optimization_block(nil), do: ""

  defp optimization_block(%{contract: contract, changelog: changelog, stage_kind: stage_kind}) do
    """
    ## Otimização em andamento

    You are one stage of an optimization pipeline running over a sandbox copy
    of this deck. The contract for the whole run:

    - Maximum bracket: **#{contract["bracket_max"]}** — an add that moves the deck past it will be rejected by the engine.
    - Price ceilings: R$ #{contract["ceilings"]["card"]} per card, R$ #{contract["ceilings"]["land"]} per land.
    #{keep_line(contract["keep"])}#{notes_line(contract["notes"])}
    #{changelog_lines(changelog)}
    You may revert an earlier stage's change, but engage its stated reason.
    Each card may enter and leave this optimization once — the engine enforces
    it, so do not propose re-flipping a card listed above as already reverted.
    #{stage_kind_line(stage_kind)}
    """
  end

  defp keep_line([]), do: ""
  defp keep_line(nil), do: ""

  defp keep_line(keep) do
    "- Protected cards (never cut): #{Enum.join(keep, ", ")}.\n"
  end

  defp notes_line(""), do: ""
  defp notes_line(nil), do: ""
  defp notes_line(notes), do: "- Owner's notes: #{notes}\n"

  defp changelog_lines([]), do: "\nNo stage has run before this one.\n"

  defp changelog_lines(changelog) do
    body =
      Enum.map_join(changelog, "\n", fn stage ->
        applied =
          Enum.map_join(stage.applied, "\n", fn change ->
            "  - #{change["action"]} #{change["card"]}: #{change["reason"]}"
          end)

        rejected =
          Enum.map_join(stage.rejected, "\n", fn change ->
            "  - REJECTED #{change["action"]} #{change["card"]}: #{Enum.join(change["problems"] || [], "; ")}"
          end)

        ["### #{stage.label}", applied, rejected]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")
      end)

    "\nWhat earlier stages did:\n\n#{body}\n"
  end

  defp stage_kind_line(:checkpoint) do
    "\nThis is a **stabilization checkpoint**: look at the whole picture. Reverting earlier changes that did not earn their place is exactly your job."
  end

  defp stage_kind_line(:validation) do
    "\nThis is a **validation stage**: your job is to find what the tuning missed, not to tune further."
  end

  defp stage_kind_line(_lens), do: ""

  defp dossier_clause(nil), do: ""
  defp dossier_clause(_dossier), do: ", confronted with the dossier above"

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

  # Stated in reais because that is what the owner set, and the app checks the
  # answer against the same number afterwards — a ceiling the model is told in
  # one currency and audited in another is a ceiling nobody can trust.
  defp ceiling_lines(nil), do: ""
  defp ceiling_lines(%{card: nil, land: nil}), do: ""

  defp ceiling_lines(ceilings) do
    lines =
      [
        ceilings.card && "- No card you add may cost more than **R$ #{ceilings.card}**.",
        ceilings.land && "- No *land* you add may cost more than **R$ #{ceilings.land}**."
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    """

    Hard price ceilings — the app checks these against Scryfall afterwards, so
    a suggestion over the line is simply rejected:

    #{lines}

    If the best answer costs more than the ceiling, say so in `notes` instead
    of suggesting it.
    """
  end

  defp budget_line(nil), do: ""

  defp budget_line(ceilings) when is_map(ceilings) do
    case ceilings.card do
      nil -> ""
      max -> "\n- Keep each added card at or under R$ #{max}."
    end
  end
end
