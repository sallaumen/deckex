# O que a mesa sente — reading a deck the way a table reads it

**Status:** approved 2026-08-14 (directions chosen by the owner after a research
pass). Extends the analysis engine described in
[the original design](2026-08-13-deckex-design.md) and feeds the contract of
[the Reimaginador](2026-08-14-reimaginador-design.md).

---

## 0. Why this exists

The app measures whether a deck *works*: mana, curve, interaction,
consistency, bracket floor. It says nothing about what the deck is like **to sit
across from**, and nothing about **where it dies**. Both are things every
Commander player negotiates before a game and neither is currently countable in
this codebase.

A research pass on the community's own vocabulary (EDHREC's salt survey,
WotC's bracket criteria, Rule 0 practice, and a body of writing on what makes
Commander games fun or miserable) produced four findings that this spec acts on.

### The four findings

1. **The root variable is table time, not power.** Independent authors converge
   on the same thing: what ruins a Commander game is time spent not playing —
   extra turns, chained combats, untap-denial, long solitaire turns. Mass land
   destruction is argued to be a *time* crime rather than a resource crime.
   This is the single strongest signal in the research and nothing in the app
   measures it.

2. **What the community finds salty is lockout and time theft — not attrition.**
   In the annual salt survey's top 100, the dominant categories are mass land
   denial, stax/prison, taxation ("pay or I profit"), rule-warping hosers,
   theft, extra turns, free counterspells and instant-win combos. **Mill, group
   slug and plain discard do not appear at all.** The owner's own intuition
   named mill; the data does not support it. This spec follows the data.

3. **Interaction is U-shaped.** No source endorses "more interaction is better".
   Over-interaction is compared directly to stax: if nobody can keep a
   permanent, nobody has fun. The engine currently models interaction as a
   floor to clear, which can only ever push one way.

4. **Archetype and theme are two orthogonal axes**, and the community has real
   names for both. The Reimaginador's `eixo` field — four values invented by
   this project — is replaced by that vocabulary.

### What we will NOT do, and why

**We will not consume EDHREC's data.** Their salt scores are the obvious
shortcut and their JSON is openly reachable, but their Terms of Service forbid
scripted requests to the site and forbid downloading or reproducing any part of
it. Verified 2026-08-14. This is the Moxfield law applied to a second site: the
rule is what the operator permits, never what is technically reachable. No
scraping, no "just one fetch", no caching a copy of their list.

The consequence shapes the design, and improves it. We cannot report *their*
number, so we measure **the play patterns ourselves**, from oracle text, with
evidence per card — which is what every other role in this engine already does.
A borrowed score says "2.8". Ours says "três efeitos de taxação: Rhystic Study,
Smothering Tithe, Mystic Remora" — nameable, checkable, and arguable.

**We will not have the model state a salt score, an archetype popularity, or a
community statistic.** The price law generalises: a model's memory of a
community dataset is stale on a good day and invented on a bad one.

---

## 1. New roles: the patterns a table notices

Six roles join `Deckex.Cards.RoleMatch`'s vocabulary, each detected by a rule
over oracle text in the existing style, each carrying its evidence string.
They are chosen because the research names them as the categories that
actually generate salt, and because each is detectable without guessing.

| role | what it detects | why it earns a slot |
|---|---|---|
| `:taxation` | "unless that player pays", "whenever an opponent draws… you may" — pay-or-I-profit | Rhystic Study and Smothering Tithe are top-5 saltiest; nothing in the engine sees them today |
| `:theft` | gaining control of, or casting from, another player's permanents/library/hand | Tergrid and Expropriate class; the "your stuff is mine" pattern |
| `:hoser` | rule-warping statics that turn off a whole category of play ("players can't", "can't cast", "activated abilities can't be activated") | Humility, Drannith Magistrate; distinct from stax because it removes an action, not a resource |
| `:forced_sacrifice` | "each opponent sacrifices", edict-style repeatable | Grave Pact / Dictate of Erebos lock |
| `:free_spell` | alternative cost that is not mana ("rather than pay this spell's mana cost", "without paying its mana cost") | Force of Will / Fierce Guardianship; a named Rule 0 axis |
| `:chaos` | randomness applied to everyone (coin flip, die roll, random redirection, shuffle-all) | Named category; also a *positive* preference for some tables |

Existing roles already cover the rest: `mass_land_denial`, `extra_turn`,
`stax`, `counter`, `tutor`, `board_wipe`, `mill`.

**`:mill` stays a role and stops being "salt".** It is a legitimate strategy the
engine should see; the research simply shows it is not what tables resent. It
moves out of the salt vocabulary and stays in the card vocabulary.

Adding roles makes the stored catalogue stale — the reclassification pass
(`Deckex.Cards.reclassify_all!/0`, written for `:mill`) runs again as part of
shipping this. That law already exists in AGENTS.md.

---

## 2. The table-time measure

A new measured section, `mesa`, and its findings.

Table time is approximated by counting the effects that **take turns, actions or
untap steps away from other players**, weighted by how repeatable each is:

- `extra_turn` cards (the explicit case)
- untap-denial and skip-step effects (`stax` cards whose text stops untapping or
  skips a step)
- repeatable extra-combat effects
- `taxation` and `hoser` statics, which make every opponent's turn slower
- `forced_sacrifice` and `theft`, which spend other people's turns

The output is not a score out of ten — **no 1-10 scale, ever**, per the project
law. It is a count with the cards named, plus one derived statement the engine
can defend: *"seis efeitos desta lista tiram tempo dos outros jogadores"*, with
the list.

The finding fires when the count crosses a baseline the owner can see and set,
in the same way every other baseline works.

**Contract dial.** `contract["tempo_de_mesa"]` takes `livre | moderado |
minimo`. Under `minimo` the audit refuses an add carrying `extra_turn`, untap
denial, or repeatable extra combats — exactly like the salt guard already
refuses an avoided tactic. Under `moderado` it refuses only the chaining cases.
This reuses the guard mechanism built for salt; it is a new vocabulary over an
existing rule, not a new mechanism.

---

## 3. The fragility lens — "onde este deck morre"

Three fault lines, named by the research as the cross-cutting ways Commander
decks actually lose. All three are countable from what the engine already
stores.

| fault line | how it is measured | example, measured on the reference deck |
|---|---|---|
| **Varredura** | share of the deck's engine that sits on creatures — creature count, plus whether mana production depends on creatures (`ramp` roles held by creatures) — against the number of board wipes and `protection` pieces | 17 criaturas, mana vinda de criaturas, **1 varredura**, 5 de proteção |
| **Ódio a cemitério** | cards whose function needs the graveyard: `recursion` role, plus oracle text referencing casting/returning from a graveyard | **10 cartas** dependem do cemitério, 7 com papel de recursão |
| **Tax / stax** | dependence on casting several spells per turn: low average CMC combined with a high count of cheap spells and cast-trigger payoffs | the reference deck is a storm shell — the profile fits |

Each fault line produces an ordinary `Finding` with severity, the cards
involved, and a finding code — so it renders in the existing deck page with no
new UI, appears in consults' briefings like any other finding, and can be
targeted by "Pedir diagnóstico" exactly as today's findings are.

This is deliberately *diagnosis, not prescription*: the lens says where the deck
is exposed and names the cards, and the existing consult machinery is what
proposes what to do about it.

---

## 4. Interaction as a band

`Baselines` gains `interaction_max` alongside `interaction_target`, and the
interaction lens gains a second finding for **too much** — over-interaction is a
documented fun-killer, and a floor-only model can never say so.

The baseline numbers themselves are revised and, for the first time, **carry
their source**. Today's `draw_target: 8`, `interaction_target: 8`,
`board_wipe_target: 2` are anonymous. The published frameworks disagree with
them and with each other, so:

- `Baselines` gains a `source` field naming the framework a set of numbers came
  from, shown in the Ajustes panel.
- The shipped default is stated as one named framework rather than an unsourced
  average, and the owner can still edit every number, as today.

The engine keeps deciding nothing about which framework is right. It shows which
one it is using and who wrote it.

---

## 5. Archetype and theme replace the invented axis

`Vision`'s `eixo` — `consistencia | velocidade | resiliencia | eixo_de_vitoria`,
four values with no provenance — is replaced by two fields:

- `arquetipo`: what the deck tries to do — `aggro | midrange | controle |
  combo | stax | ramp | politica | grupo`
- `tema`: the mechanical engine, free text constrained by the briefing to the
  community's names (aristocrats, landfall, blink, spellslinger, storm,
  reanimator, enchantress, tokens, voltron, artifacts, +1/+1 counters, typal,
  theft, wheels, lifegain, toolbox…)

Both are stated in the briefing as vocabulary to choose from, not as an enum the
engine validates — naming is the model's job and the list grows with every set.
The colour identity remains the hard gate it already is.

The three visions must still differ, and the rule becomes sharper: they must
differ in **archetype**, not merely in theme. Three landfall decks is a failed
answer even if the card lists differ.

---

## 6. What this does NOT change

- No new page. Every output lands in the deck page's findings, the Ajustes
  panel, or the existing optimization contract.
- No new pipeline stage. The fragility findings feed the consults that exist.
- The bracket engine is untouched: it still reports a floor and never a verdict.
- The Reimaginador's flow — three visions, the owner chooses, the run waits — is
  unchanged apart from the vocabulary in §5.

---

## 7. Testing

- One rule test per new role, each with a real fixture card that matches and a
  near-miss that must not (the `:mill` rule's self-mill exclusion is the
  template).
- The fragility lens: a synthetic creature-heavy deck fires the wipe fault line;
  a spell deck does not. A graveyard deck fires the yard fault line; a deck with
  no recursion does not.
- The table-time guard: an `extra_turn` add is refused under `minimo` and passes
  under `livre`.
- The interaction band: a deck over `interaction_max` produces the new finding.
- Reclassification runs and is verified against the real catalogue before the
  work is called done.

---

## 8. Decision log

- **We do not consume EDHREC's data.** Their ToS forbids scripted requests and
  reproduction; reachability is not permission. This is the Moxfield law applied
  to a second site. (§0)
- **We measure the pattern instead of borrowing the score**, which turns out to
  be the better product: a nameable list of cards beats an opaque number, and it
  is arguable rather than authoritative. (§0)
- **Mill leaves the salt vocabulary and stays a role.** The owner named it; the
  survey data does not support it. Following the data is the point of having
  looked. (§1)
- **Table time becomes a first-class measure.** It is the variable the research
  identifies as the root of the experience, and nothing measured it. (§2)
- **Fragility is diagnosis, not prescription.** The lens names where the deck
  dies; the consults already know how to propose fixes. (§3)
- **Interaction is a band.** A floor-only model cannot express the documented
  failure mode at the top end. (§4)
- **Baselines carry a source.** Numbers presented without provenance read as
  facts; ours were one anonymous opinion, and behind the published revisions.
  (§4)
- **Archetype and theme replace the invented axis.** Four values this project
  made up are replaced by the vocabulary players actually use. (§5)
