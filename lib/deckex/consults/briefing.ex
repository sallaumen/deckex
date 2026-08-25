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
  alias Deckex.Decks.CardRules
  alias Deckex.Optimizations.Balance
  alias Deckex.Optimizations.Salt

  @spec build(Report.t(), DeckSnapshot.t(), atom(), keyword()) :: String.t()
  def build(%Report{} = report, %DeckSnapshot{} = snapshot, lens, opts \\ []) do
    findings = scoped_findings(report, lens, opts[:finding_code])

    """
    You are helping tune a Magic: The Gathering **Commander (EDH)** deck.

    #{deck_block(report, snapshot)}

    #{measurements_block(report, lens)}

    #{findings_block(findings)}

    #{bracket_block(report)}

    #{description_block(opts[:description])}

    #{dossier_block(lens, opts)}

    #{card_notes_block(opts[:card_notes])}

    #{combos_block(opts[:combos])}

    #{optimization_block(opts[:optimization])}

    #{plan_block(get_in(opts, [:optimization, :plan]))}

    #{effect_block(get_in(opts, [:optimization, :effect]))}

    #{decklist_block(snapshot)}

    ## What to do

    #{task_block(lens, opts)}

    #{rules_block(lens, report, opts)}
    """
  end

  defp deck_block(report, snapshot) do
    """
    ## The deck

    - Name: #{report.deck_name}
    - Colour identity: #{identity(report)}
    #{commander_block(snapshot.commanders)}
    """
  end

  # The one card that is in play every single game, and for most of this app's
  # life the briefing named it and stopped. Its text is the deck's whole
  # premise; a stage that has to remember what the commander does is a stage
  # guessing at the plan it is being asked to serve.
  defp commander_block([]), do: "- Commander: none declared"

  defp commander_block(entries) do
    "\n### Commander\n\n#{card_entries(entries)}"
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

  # A whole-deck question sees every section: what the table feels, where the
  # deck dies, and whether it is a legal deck at all. The legality counts are
  # the reason a stage can be told to go net negative — a model that cannot see
  # the deck is at 103 cards has no way to know it must cut three.
  defp lens_keys(_everything_else),
    do: [:curve, :mana, :interaction, :consistency, :mesa, :fragility, :legality]

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

  defp task_block(:visao, _opts) do
    """
    Propose **three different directions** this deck could take to become
    genuinely stronger. This is not a tuning pass: you are allowed to change
    what the deck *is*.

    Name each direction with the vocabulary players actually use, on two axes
    the community keeps separate:

    - `arquetipo` — what the deck is TRYING TO DO: aggro, midrange, controle,
      combo, stax, ramp, politica, grupo.
    - `tema` — the mechanical engine that does it: aristocrats, landfall,
      blink, spellslinger, storm, reanimator, enchantress, tokens, voltron,
      artifacts, +1/+1 counters, typal, theft, wheels, lifegain, toolbox, and
      so on. This one is not a fixed list; use the name a player would use.

    The three MUST differ in **arquetipo**, not merely in theme. Three landfall
    decks with different card lists is a failed answer.

    For each direction give, in pt-BR: a short name, the thesis for why it
    makes this deck stronger, and — with the same care — what the deck
    **loses** by going that way. List the key cards that define the direction
    by exact name. **Never state a price**: the app prices them from Scryfall
    and shows the owner the real number in R$.

    You may propose a different commander for a direction, but it must have
    **exactly this deck's colour identity**. The app verifies this and prints a
    refusal on your vision if it does not. Omit it to keep the current one.

    Propose no cuts and no adds here. The owner picks one direction, and the
    stages after you will build it.
    """
  end

  # The closing stage. It exists because a run may not end on a list that
  # cannot go on a table: the ordinary stages walk the count back a card or two
  # at a time, and whatever gap they left is this one's whole job. It is the
  # only stage told to close the gap completely.
  defp task_block(:balanco, opts) do
    # Nested, like every other pipeline fact: the count travels inside the
    # `optimization` block the run builds, not as a loose option.
    count = get_in(opts, [:optimization, :card_count]) || Balance.target()
    gap = abs(Balance.target() - count)

    """
    This copy has **#{count} cards** and a Commander deck has exactly
    #{Balance.target()}. #{balance_order(count, gap)}

    This is the only thing to do here. Do not propose anything else: the
    stages before you already made the deck better, and a change that is not
    about the count is a change nobody asked you for at this point.

    Choose by the same standard the earlier stages used — the weakest cards for
    the plan this deck is now running, or the most useful ones missing from it.
    The engine checks the arithmetic and refuses anything that does not land on
    exactly #{Balance.target()}.
    """
  end

  # The one stage where a person outranks the pipeline. Everything else here
  # is arithmetic and a model's reading of card text; this is the person who
  # actually plays the deck saying the reading was wrong.
  defp task_block(:revisao, opts) do
    """
    The owner of this deck read the whole run and wrote back. **This stage is
    his.**

    #{owner_review(opts[:optimization])}

    ## How to treat what he said

    He plays this deck. When he says a card does something the earlier stages
    got wrong — its text, its role, what it actually enables in *this* list —
    **he is right and the run was wrong**. Do not argue the reading back at
    him; act on it.

    - A card he defends that an earlier stage cut: **propose adding it back**,
      and cut whatever is now weakest to pay for it.
    - A card he dislikes that an earlier stage added: **propose cutting it**,
      and add what the deck actually needed instead.
    - A card he asks about without a verdict: answer him in `leitura` and
      propose a change only if his point implies one.
    - Something he said about the deck as a whole: apply it as far as it
      reaches, and say in `leitura` what you did not do and why.

    Change **only** what his notes reach. Everything else in this deck was
    already argued over for several stages; a change he did not ask for is a
    change nobody asked you for.

    The deck must still end at exactly #{Balance.target()} cards, so every card
    that comes back has to be paid for by one that leaves.
    """
  end

  # A round of one stage, run because the owner already knows what he wants
  # done and does not need nine stages to discover it. The whole pipeline's
  # value is that later stages correct earlier ones; here there are none, so
  # the instruction is narrowness rather than ambition.
  defp task_block(:livre, opts) do
    """
    #{free_request(get_in(opts, [:optimization, :contract, "pedido"]))}

    ## How to treat it

    This is a **single-stage round**. Nothing runs after you: no checkpoint
    will revisit your changes, no validation will catch an overreach, and the
    owner applies what you return or throws the whole round away. So do the
    thing that was asked and stop.

    - Change **only** what his request and his standing decisions above reach.
      A change nobody asked for has no later stage to argue with it, and it is
      the reason he will discard the round.
    - Every card he locked stays. Every card he is asking for is a candidate
      you should take unless you can say why not.
    - The deck must end at exactly #{Balance.target()} cards, so every card
      that comes in is paid for by one that goes out — and the one that goes
      out is the weakest card for the plan this deck is actually running, not
      the cheapest or the most recently added.
    """
  end

  # The question the owner cannot answer card by card without spending an
  # evening on it, and the engine cannot answer at all: it reads one card at a
  # time and a pillar is usually a card that is unremarkable alone.
  defp task_block(:pilares, _opts) do
    """
    Name the cards this deck **cannot lose**, and nothing else.

    A pillar is not a good card. It is a card whose removal changes what the
    deck *does*:

    - one half of an interaction the rest of the list is built to assemble —
      the case that matters most, because each half looks ordinary alone and a
      stage reading them one at a time will cut one of them;
    - the engine every other card feeds, or the payoff they all feed;
    - the only card doing a job the plan requires, with no second copy of that
      job in the list.

    **Not** a pillar: a strong generic staple any deck in these colours would
    play, a card that is merely expensive, a card that is merely popular. Those
    are replaceable — that is what makes them staples, and replaceable is the
    opposite of what this list is for.

    Be strict. Most decks have between five and twelve of these. **A list that
    names a quarter of the deck protects nothing**, because a pipeline that
    cannot cut anything cannot improve anything, and the owner will delete the
    whole list rather than sort it.

    Every entry needs the sentence that justifies it, and when the card is half
    of an interaction, **name the other half**. He is going to read these one
    by one and decide; "carta forte" is not a reason he can check.

    Propose no cuts and no adds. You are not tuning this deck.
    """
  end

  # Reads everything, changes nothing. The whole reason this stage exists is
  # that the old recipe had nobody deciding what a round was *for* — every
  # stage started cutting immediately, from its own partial view, and the
  # stages after it spent their budget disagreeing.
  defp task_block(:plano, _opts) do
    """
    Plan this round. **Propose no cuts and no adds** — a later stage makes every
    change, and it will be bound to what you write here.

    Two things, both required.

    **The plan.** Name the three to five problems that actually cost this deck
    games, worst first, reading the card text above rather than the old dossier.
    For each: what it is, which game it loses, and the *shape* of the fix. You
    may name cards as examples; you are not choosing them.

    Then `nao_mexer`: what this round must leave alone. That field is not
    filler. A round that improves the curve by dismantling the engine is the
    failure this pipeline keeps producing, and you are the only stage in a
    position to forbid it before it happens.

    **The dossier.** Rewrite the deck's four standing fields — `plano`,
    `sinergias`, `linhas_de_vitoria`, `fraquezas` — from the list as it is now.
    They outlive this round and every future briefing carries them, so a card
    named there that is not in the decklist above is a mistake that costs
    somebody a paragraph later.
    """
  end

  defp task_block(:execucao, _opts) do
    """
    Make **every** change this round is going to make, in one answer. Nothing
    runs after you except a critic reading the result — there is no second pass
    to finish a job you left half done, and no later stage that will revert
    you.

    - Work the plan above, in its order. The first problem is the one that costs
      the most games.
    - Respect `nao_mexer`. A change it forbids is a change the owner throws the
      whole round out for.
    - **#{Balance.target()} cards exactly** when you are done. If the count in
      the run block above says the list is already off that number, closing the
      gap is part of your job; otherwise every add is paid for by a cut.
    - Aim for **8 to 15 cuts and 8 to 15 adds** — that is eight to fifteen
      *swaps*, not eight to fifteen cards touched. Fewer does not pay for the
      round; more than twenty swaps is a different deck, and he cannot judge
      forty cards one by one.
    - Every cut names what it was failing to do, and every add names the
      problem from the plan it answers.
    """
  end

  # The stage the owner asked for by name: complete, detailed, wants the deck
  # perfect, does not let a good card slip out, and **may not leave the deck
  # worse than it found it**. That last one is measured by the engine and
  # handed to it below, because a model asked to promise it will simply promise.
  defp task_block(:critico, _opts) do
    """
    A round just ran on this deck. **Judge it, then fix it.** You are the last
    stage; what you leave is what the owner sees. The plan it was working to
    and the engine's before-and-after are both above.

    Write `veredito` **first**, before proposing anything: did this deck get
    better? Where did it get worse? Which good card went out that should not
    have, and which obvious card is still missing? Say it plainly — an
    approving verdict on a round that broke something is worth nothing to him.

    Then correct it. Your changes are held to a harder standard than the ones
    above, because nobody checks you:

    - **The deck may not end worse than it started.** Every finding listed as
      *introduced* above is damage this round did, and closing it is your first
      job. If you cannot close one without breaking something worse, say which
      in `veredito` and say why.
    - A card cut above that you would put back: put it back, and pay for it by
      cutting what the round should have cut instead.
    - A card the deck plainly wants and nobody suggested: add it. "The previous
      stage did not think of it" is not a reason to leave it out.
    - Change nothing that is merely *different from your taste*. The round
      already argued these cards; re-litigating them costs the owner a stage
      and moves nothing.

    Land on exactly #{Balance.target()} cards.
    """
  end

  # The reimagine rebuild. It shares `:execucao`'s place in the recipe and
  # nothing else: a stage told to turn a chosen direction into a deck cannot
  # also be told to keep to eight changes, and shipping both instructions in
  # one prompt is exactly the contradiction this recipe was rewritten to end.
  defp task_block(:reconstrucao, opts) do
    """
    #{vision_task(get_in(opts, [:optimization, :contract, "visao"]))}

    Turn it into a deck, in one answer. **You have more room here than any
    other stage** — cut everything that does not serve the direction and add
    what does, however many cards that takes.

    Everything else still holds: the colour identity, the ceilings, the cards
    the owner locked, the salt contract, and exactly #{Balance.target()} cards
    when you are done.

    Every cut names what it served that the new direction does not need, and
    every add names the part of the direction it builds.
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

  # The through-line. Carried verbatim into both stages after it, because a plan
  # summarised is a plan the next stage gets to reinterpret.
  defp plan_block(nil), do: ""

  defp plan_block(plan) do
    priorities =
      plan
      |> Map.get("prioridades", [])
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {item, index} ->
        "#{index}. **#{item["problema"]}** — #{item["porque_importa"]} " <>
          "Forma da solução: #{item["como_resolver"]}"
      end)

    """
    ## O plano desta rodada

    #{plan["leitura"]}

    #{priorities}

    **Não mexer:** #{plan["nao_mexer"]}
    """
  end

  # Measured by the engine from the same baselines, before and after. This is
  # what makes "never leave the deck worse" a rule rather than a wish: the
  # critic is handed the list of what its own round broke, by code, instead of
  # being asked to notice.
  defp effect_block(nil), do: ""

  defp effect_block(effect) do
    """
    ## O que a rodada fez, medido pelo motor

    #{finding_lines("Resolveu", effect.resolved, "these are the round's real gains")}
    #{finding_lines("INTRODUZIU", effect.introduced, "**this is damage this round did, and closing it is your first job**")}
    #{finding_lines("Continua aberto", effect.remaining, "the round did not reach these")}
    """
  end

  defp finding_lines(_label, [], _note), do: ""

  defp finding_lines(label, findings, note) do
    body = Enum.map_join(findings, "\n", &"- #{&1.code} — #{&1.title}")

    "**#{label} (#{length(findings)})** — #{note}:\n#{body}\n"
  end

  # A round launched with no text is not an empty request: it is "do what I
  # already told you", and everything he told you is above.
  defp free_request(nil), do: free_request("")

  defp free_request(pedido) do
    case String.trim(pedido) do
      "" ->
        """
        The owner launched this round without writing a request. That means the
        work is the standing decisions above and nothing else: put back every
        card he locked that is missing, take the cards he is asking for, and pay
        for them.
        """

      request ->
        """
        The owner asked for one thing, and it is this:

        > #{String.replace(request, "\n", "\n> ")}
        """
    end
  end

  defp vision_task(nil) do
    "The owner picked a direction for this deck; it is stated in the run's contract above."
  end

  defp vision_task(vision) do
    """
    The owner picked this direction, and it is what you are building:

    > **#{vision["nome"]}** — #{vision["tese"]}
    > O que o deck perde por isso: #{vision["custo"]}
    """
  end

  defp balance_order(count, gap) when count > 100 do
    "Cut exactly **#{gap}** card(s) and add none."
  end

  defp balance_order(_count, gap) do
    "Add exactly **#{gap}** card(s) and cut none."
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

  # Every measurement in this app reads one card at a time, and that is exactly
  # how a stage cut Sam, Loyal Attendant: alone she is a 2/4 nobody plays, and
  # the line she makes with Prize Pig lives in neither card's text nor either
  # card's rank. A combo database is the one source that answers "what do these
  # do together" as a fact rather than as an inference.
  defp combos_block(nil), do: ""

  defp combos_block(%{"assembled" => [], "one_card_away" => []}), do: ""

  defp combos_block(combos) do
    """
    ## Combos conhecidos nesta lista

    From Commander Spellbook, matched against the decklist below.

    #{assembled_lines(combos["assembled"])}
    #{one_away_lines(combos["one_card_away"], combos["one_card_away_total"])}
    """
  end

  defp assembled_lines([]), do: ""

  defp assembled_lines(combos) do
    """
    **The deck already assembles these (#{length(combos)}).** Every piece is in
    the list. Treat those pieces as load-bearing: cutting one of these cards
    does not lose a card, it loses the line — and the owner may not know he
    owns it.

    #{Enum.map_join(combos, "\n", &combo_line/1)}
    """
  end

  defp one_away_lines([], _total), do: ""

  defp one_away_lines(combos, total) do
    """
    **One card away (#{length(combos)}#{of_total(combos, total)}).** The deck holds every piece but one,
    and the missing card is named. This is the sharpest answer available to
    "what should this deck add": each of these turns cards already bought into
    a line. Weigh them against the plan — a combo this deck does not want is
    still a combo it does not want.

    #{Enum.map_join(combos, "\n", &missing_line/1)}
    """
  end

  # A trimmed list that does not say it was trimmed reads as the whole answer.
  defp of_total(combos, total) when is_integer(total) and total > length(combos) do
    " shown, of #{total} — the ones that produce the most"
  end

  defp of_total(_combos, _total), do: ""

  defp combo_line(combo) do
    "- #{Enum.join(combo["cards"], " + ")} → #{produces(combo)}#{prerequisite_note(combo)}"
  end

  defp missing_line(combo) do
    "- **add #{combo["missing"]}** → with #{others(combo)} this produces #{produces(combo)}"
  end

  defp others(combo) do
    combo["cards"] |> List.delete(combo["missing"]) |> Enum.join(" + ")
  end

  defp produces(combo) do
    case combo["produces"] do
      [] -> "a known line"
      features -> Enum.join(features, ", ")
    end
  end

  defp prerequisite_note(%{"prerequisites" => [_ | _] = notes}) do
    " (needs: #{Enum.join(notes, "; ")})"
  end

  defp prerequisite_note(_none), do: ""

  # Above the dossier, and the order is the argument: the dossier is a model's
  # reading of the list, this is the person who built it saying what he was
  # going for. When the two disagree about *intent*, he is not wrong — it is
  # his deck. When they disagree about *fact*, the list settles it.
  defp description_block(nil), do: ""
  defp description_block(""), do: ""

  defp description_block(description) do
    """
    ## O que o dono diz que este deck é

    #{description}

    These are his words about his own deck, and they are the **intent** — what
    he is trying to build. Nothing here is a measurement, so the list can
    contradict it on facts and the list wins on those; say so plainly when it
    does. But it cannot contradict him on what he *wants*. A change that makes
    the deck better at something he did not ask for, at the cost of the thing
    he did, is a change he will throw out along with the rest of the round.
    """
  end

  # The owner correcting a card is the most expensive knowledge this app holds
  # — it cost him a run to notice and a review to say. It goes in every
  # briefing about this deck, above every measurement, because a model that
  # misreads a card will misread it the same way next time.
  defp card_notes_block(nil), do: ""
  defp card_notes_block([]), do: ""

  defp card_notes_block(notes) do
    groups = CardRules.split(notes)

    [locked_block(groups.locked), wanted_block(groups.wanted), said_block(groups.notes)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  # The strongest thing the owner can say, and the only one the engine also
  # enforces. It is stated in the prompt anyway: a stage that spends its answer
  # proposing a cut the audit will reject has wasted the whole stage, and the
  # owner pays for stages.
  defp locked_block([]), do: ""

  defp locked_block(locked) do
    """
    ## Cartas que o dono trancou neste deck

    #{Enum.map_join(locked, "\n", &rule_line/1)}

    These cards are **not available to cut**. Not for value, not for the
    curve, not to make room, not to close the count — the engine rejects a cut
    of any of them and the stage loses the change. Several of them are here
    because a card that looks unremarkable on its own is load-bearing in *this*
    list; where he explained why, that explanation is worth more than your
    reading of the card in isolation.

    If one of them is **missing from the decklist below**, putting it back is
    the first change you should propose, and something else pays for it.
    """
  end

  defp wanted_block([]), do: ""

  defp wanted_block(wanted) do
    """
    ## Cartas que o dono está pedindo

    #{Enum.map_join(wanted, "\n", &rule_line/1)}

    He wants these in the deck. Treat each one as a strong candidate to add —
    stronger than anything you would have thought of yourself, because he
    plays this deck and you are reading it. You may still decline one, but
    then say so **by name** in `leitura` and say what the deck would lose by
    taking it. Silence about a card he asked for reads as having ignored him.
    """
  end

  defp said_block([]), do: ""

  defp said_block(said) do
    """
    ## O que o dono já disse sobre cartas deste deck

    #{Enum.map_join(said, "\n", &rule_line/1)}

    These are his words about his own list, from earlier rounds. Where one of
    them contradicts your reading of a card, **his reading wins** — he plays
    the deck and he wrote this down precisely because a stage got it wrong
    once. Do not propose a change that a note above argues against without
    engaging the note by name.
    """
  end

  defp rule_line(%{card_name: name, note: nil}), do: "- **#{name}**"
  defp rule_line(%{card_name: name, note: note}), do: "- **#{name}**: #{note}"

  # "Weigh it accordingly" was too soft to act on. A stage that opened on a
  # dossier three versions old spent its whole first paragraph listing the
  # eight cards the dossier calls the plan and the deck no longer has — correct,
  # useful once, and paid for by an owner who wanted the stage to work the
  # findings. Now the prompt says which of the two documents wins and what to
  # do about the gap, in one sentence, rather than leaving the stage to invent
  # a policy.
  defp stale_line(true) do
    """

    **This dossier is out of date: the deck's list has changed since it was
    written.** The decklist below is the deck; the dossier is a description of
    what it used to be. Where the two disagree — a card named here that is not
    in the list, a plan the current cards no longer support — the list wins,
    without argument. Say what changed in **one sentence** in `leitura` and
    spend the rest of your answer on the deck as it is now. Cataloguing
    everything the dossier gets wrong is not the work.
    """
  end

  defp stale_line(_fresh), do: ""

  # The scout only reads, so most of the consulting rules are noise to it.
  # Read-only, like the scout: every rule about cuts, adds, ceilings and colour
  # identity is noise to a stage that proposes no change.
  # Read-only: every rule about cuts, adds, ceilings and colour identity is
  # noise to a stage that is forbidden from proposing a change.
  defp rules_block(:plano, _report, _opts) do
    """
    Search the web where it helps you understand what a card does in this deck.

    Propose no cuts and no adds. Name cards only as examples of a solution's
    shape, and only cards that make sense in this colour identity.

    Answer in **Portuguese (pt-BR)**, but never translate a card name.
    """
  end

  defp rules_block(:pilares, _report, _opts) do
    """
    Search the web where it helps you understand what a card does in this deck,
    or find the interaction it belongs to.

    Only name cards that are in the decklist above. A card you think the deck
    *should* have is a different question, asked on a different screen.

    Answer in **Portuguese (pt-BR)**, but never translate a card name.
    """
  end

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
    - **A price ceiling is a limit, not a target.** Do not optimise for
      cheapness. The owner would rather pay for the card that answers the
      finding than save money on one that half-answers it, and a deck built out
      of the cheapest card that vaguely fits is the failure mode here. Name the
      best card that fits under the ceiling. If that turns out to be a card
      everyone already plays, it is not a boring suggestion — it is the answer,
      and it is cheap because it was reprinted, not because it is weak.#{budget_shape_lines(opts[:budget])}
    - **The play rate is evidence, never a verdict.** It is how many Commander
      decks run the card, and it answers a question price cannot: Arcane Signet
      costs two reais and is one of the most-played cards in the format, while
      a thirty-six-real card can sit past rank five thousand. Read it in both
      directions. A staple missing from a deck that wants it is the cheapest
      fix on the table. A rarely-played card in the list is **not a cut on
      sight** — it is either a build-around this deck is built on or a card
      nobody thought about, and the difference is what the deck is trying to
      do, which you can read above. Cutting every low-ranked card would delete
      exactly the engines that make a deck someone's.
    - Prefer answers that work against **anything** over answers aimed at one
      deck. This is a four-player pod where every archetype turns up; a card
      that only beats the deck you guessed is dead against the other two.
      Flexible removal, not hate cards.
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

  defp optimization_block(
         %{contract: contract, changelog: changelog, stage_kind: stage_kind} = optimization
       ) do
    """
    ## Otimização em andamento

    You are one stage of an optimization pipeline running over a sandbox copy
    of this deck. The contract for the whole run:

    - Maximum bracket: **#{contract["bracket_max"]}** — an add that moves the deck past it will be rejected by the engine.
    #{land_ceiling_line(contract["ceilings"])}
    #{salt_line(contract["salt"])}#{keep_line(contract["keep"])}#{notes_line(contract["notes"])}#{count_line(optimization[:card_count])}
    #{changelog_lines(changelog)}
    You may revert an earlier stage's change, but engage its stated reason.
    Each card may enter and leave this optimization once — the engine enforces
    it, so do not propose re-flipping a card listed above as already reverted.
    #{vision_line(contract["visao"])}#{stage_kind_line(stage_kind)}
    """
  end

  defp owner_review(nil), do: ""

  defp owner_review(optimization) do
    cards = optimization[:marks] || []
    general = get_in(optimization, [:contract, "revisao_geral"])

    [marked_cards(cards), general_note(general)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp marked_cards([]), do: ""

  defp marked_cards(marks) do
    lines =
      Enum.map_join(marks, "\n\n", fn mark ->
        "- **#{mark.card_name}** — the run #{did(mark.action)}. He says: \"#{mark.note}\""
      end)

    "### As cartas que ele marcou\n\n#{lines}"
  end

  defp did(:add), do: "added it"
  defp did(:cut), do: "cut it"
  defp did(:rejected), do: "had it suggested and the engine refused it"
  defp did(_unknown), do: "touched it"

  defp general_note(nil), do: ""
  defp general_note(""), do: ""

  defp general_note(note), do: "### O que ele achou da rodada inteira\n\n#{note}"

  # Once a direction is chosen it is the target, and the deck's old dossier —
  # which may still be injected above — becomes context rather than the goal.
  defp vision_line(nil), do: ""

  defp vision_line(vision) do
    """

    ### A direção escolhida: #{vision["nome"]}

    #{vision["tese"]}

    The owner accepted this cost: #{vision["custo"]}

    This is the target now. The deck's dossier, if one appears above, is **what
    the deck was** — context, not the goal.
    """
  end

  # Models do not count 90-line lists reliably, and earlier stages may have
  # legitimately gone net negative — so the engine states the number and the
  # direction, every stage, until the copy closes at exactly 100.
  # Stating the count was never enough: a stage that knows the copy is at 105
  # and is asked for nothing in particular tends to swap card-for-card and
  # leave it at 105. `Balance` turns the gap into a number for this stage.
  defp count_line(nil), do: ""

  defp count_line(count), do: "\n- " <> Balance.instruction(count)

  # Only the avoided half is a rule; the wanted half is an invitation, and the
  # briefing says which is which so the model does not read a preference as a
  # constraint or a constraint as a preference.
  defp salt_line(nil), do: ""

  defp salt_line(salt) do
    avoided = salt |> Salt.avoided() |> Map.values()
    wanted = Salt.wanted(salt)

    [
      avoided != [] &&
        "- Do NOT propose: #{Enum.join(avoided, ", ")}. The engine rejects these adds.\n",
      wanted != [] && "- The owner actively wants more of: #{Enum.join(wanted, ", ")}.\n"
    ]
    |> Enum.filter(& &1)
    |> Enum.join()
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

  defp stage_kind_line(:reconstruction) do
    "\nThis is the **reconstruction**: the stage that turns the chosen direction into a deck. You have more room here than any other stage — cut what does not serve the direction and add what does. The ceilings, the colour identity, the salt contract and the flip-flop rule all still hold."
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

  # **With the rules text.** For most of this app's life the decklist was a
  # hundred lines of name, mana cost and type line, and every model that ever
  # read one was working from memory about what the cards actually do. That is
  # the single cause behind the worst failures the owner has hit: a stage cut
  # Jaheira without knowing she turns Food into mana creatures; a stage cut Sam,
  # Loyal Attendant — "Creature — Halfling Peasant", said the briefing —
  # without knowing she makes Food abilities cost {1} less, which is half of an
  # infinite combo with Prize Pig; a stage invented Austere Command's modes and
  # the next stage had to spend itself undoing the add.
  #
  # Every one of those texts was already in the catalogue, fetched from
  # Scryfall at import and never sent. A hundred-card deck costs about 3.5k
  # tokens of rules text against the 30-90k a stage already spends. There is no
  # trade-off here; there was only an omission.
  #
  # Nothing is truncated. Half a card's text is how you produce a *new*
  # misreading, and the long cards are exactly the ones being misread.
  defp decklist_block(snapshot) do
    "## The full decklist\n\n#{card_entries(snapshot.main)}"
  end

  defp card_entries(entries) do
    entries
    |> Enum.sort_by(& &1.card.name)
    |> Enum.map_join("\n\n", fn entry ->
      cost = entry.card.mana_cost || "no cost"

      "#{entry.quantity} **#{entry.card.name}** — #{cost} — #{entry.card.type_line}" <>
        body(entry.card) <>
        "\n  " <>
        facts(entry) <>
        oracle_lines(entry.card)
    end)
  end

  defp body(%{power: nil}), do: ""
  defp body(%{toughness: nil}), do: ""
  defp body(%{power: power, toughness: toughness}), do: " — #{power}/#{toughness}"

  # Everything else the catalogue already knows and the briefing used to throw
  # away. `edhrec_rank` in particular: the format's own count of how many decks
  # play a card, downloaded with every card since the first import and never
  # once sent. Asking a model whether a card is good while withholding the one
  # measurement of what the format thinks is how "good" stayed a matter of the
  # model's memory.
  defp facts(entry) do
    [play_rate_fact(entry.card.edhrec_rank), roles_fact(entry.roles), changer_fact(entry.card)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" · ")
  end

  defp play_rate_fact(nil), do: "play rate: unknown"

  defp play_rate_fact(rank) do
    "play rate: EDHREC ##{rank} (#{rank_gloss(rank)})"
  end

  # The same cuts `Deckex.Cards.PlayRate` renders in the UI, said in the
  # briefing's language.
  defp rank_gloss(rank) when rank <= 500, do: "a staple of the format"
  defp rank_gloss(rank) when rank <= 2_000, do: "played often"
  defp rank_gloss(rank) when rank <= 10_000, do: "rarely played"
  defp rank_gloss(_rank), do: "almost nobody plays it"

  # The app's own classification, which every measurement above is counted
  # from. A stage told "0 wincons" could not see which cards were classified as
  # what, so it could neither trust the count nor correct it.
  defp roles_fact(roles) do
    case Enum.sort(roles) do
      [] -> ""
      kinds -> "roles: #{Enum.join(kinds, ", ")}"
    end
  end

  defp changer_fact(%{game_changer: true}), do: "**GAME CHANGER**"
  defp changer_fact(_ordinary), do: ""

  # **Both faces.** `oracle_text` on a two-faced card is the FRONT only, and
  # for sixteen cards in the owner's decks that meant the briefing described a
  # different card than the one in the list: Brightclimb Pathway read as a
  # mono-white land when it is a W/B dual, and Malevolent Hermit's whole back
  # face — "noncreature spells you control can't be countered" — was invisible
  # to a stage being asked whether the deck had protection.
  #
  # `card_faces` was in the catalogue the entire time, fetched with every card.
  defp oracle_lines(card) do
    case faces(card) do
      [] -> ""
      [single] -> quoted(single.text)
      several -> Enum.map_join(several, "", &("\n  **#{&1.name}** —" <> quoted(&1.text)))
    end
  end

  defp faces(%{card_faces: [_ | _] = faces} = card) do
    faces
    |> Enum.map(&%{name: &1["name"] || card.name, text: &1["oracle_text"] || ""})
    |> Enum.reject(&(&1.text == ""))
  end

  defp faces(%{oracle_text: text}) when is_binary(text) and text != "",
    do: [%{name: nil, text: text}]

  defp faces(_textless), do: []

  # Indented under its card so a hundred of them still read as a list rather
  # than as one wall of rules text.
  defp quoted(text) do
    "\n" <> Enum.map_join(String.split(text, "\n"), "\n", &"  > #{&1}")
  end

  defp scoped_findings(report, :finding, code) when is_binary(code) do
    Enum.filter(report.findings, &(&1.code == code))
  end

  # Only the four narrow lenses see a slice. Everything else asks a question
  # about the whole deck and must see the whole diagnosis — this used to be
  # inverted, and the cost was severe: `:visao`, which sets the direction nine
  # stages then execute, was told "the deck passed every lens" about a deck
  # with two criticals. `:upgrade`, `:budget` and `:matchup` were blind the
  # same way.
  @narrow_lenses [:speed_curve, :mana_ramp, :interaction, :consistency]

  defp scoped_findings(report, lens, _code) when lens in @narrow_lenses do
    Enum.filter(report.findings, &(&1.lens == lens))
  end

  defp scoped_findings(report, _lens, _code), do: report.findings

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

  # The owner's limits are about the LIST, not the card, so the model is told
  # how much of each allowance is already spent. A model that only knew the
  # thresholds would propose four exceptions and let the engine refuse three —
  # three wasted suggestions, and the owner reading refusals instead of ideas.
  #
  # Both numbers are computed by the caller: this module is pure and cannot ask
  # Settings what the limits are or Money what a dollar is worth.
  # A land gets a hard ceiling of its own and no exception slots: an expensive
  # land is the easiest way to spend a lot and win nothing. The per-card
  # ceiling is not repeated here — it is stated as the exception line, where
  # its allowance is stated with it.
  defp land_ceiling_line(%{"land" => land}) when is_integer(land) do
    "- No land may cost more than R$ #{land}."
  end

  defp land_ceiling_line(_none), do: ""

  defp budget_shape_lines(nil), do: ""

  defp budget_shape_lines(%{policy: policy, occupancy: occupancy}) do
    [
      expensive_line(policy.expensive, occupancy.expensive),
      exception_line(policy.exception, occupancy.exception)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join("", &("\n" <> &1))
  end

  defp expensive_line(%{threshold: nil}, _used), do: nil
  defp expensive_line(%{max: nil}, _used), do: nil

  defp expensive_line(%{threshold: threshold, max: max}, used) do
    "- A card over **R$ #{threshold}** counts as expensive, and this deck may hold " <>
      "#{max} of them. It already holds **#{used}**, so #{room_phrase(max - used)}."
  end

  defp exception_line(%{threshold: nil}, _used), do: nil
  defp exception_line(%{max: nil}, _used), do: nil

  defp exception_line(%{threshold: threshold, max: max}, used) do
    "- Over **R$ #{threshold}** is an *exception*: the deck allows #{max}, and " <>
      "#{used} are spent. There is no ceiling above that — the slots are the ceiling — " <>
      "so an exception may cost anything, and must be worth it. Spend one only on a card " <>
      "that is decisively better than everything under the line, and say in its reason " <>
      "why nothing cheaper does the job. If none is, propose none."
  end

  defp room_phrase(room) when room <= 0, do: "there is no room for another"
  defp room_phrase(1), do: "there is room for one more"
  defp room_phrase(room), do: "there is room for #{room} more"
end
