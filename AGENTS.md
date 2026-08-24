# AGENTS.md — deckex conventions (ground truth)

The operational contract for anyone, human or AI, writing code here. It adopts
the **Elixir/Phoenix Architecture & Quality Playbook** in
[`docs/playbook/`](docs/playbook/) wholesale and records the project-specific
decisions on top of it. When this file and the playbook disagree, **this file
wins** — it is the tailored, project-level layer.

Read [`docs/superpowers/specs/2026-08-13-deckex-design.md`](docs/superpowers/specs/2026-08-13-deckex-design.md)
for *what* we are building and *why*. This file is *how*.

## Language rule (hard)

- **Code is English:** identifiers, module and function names, `@doc` /
  `@moduledoc`, commit messages.
- **User-facing text is pt-BR:** UI chrome, flashes, finding titles, error copy.
- **Card names are never translated.** They are data and the Scryfall key.

## The five principles (from the playbook)

1. **Layer strictly, depend inward.** Edges (LiveViews, workers) translate and
   delegate. The domain (`lib/deckex/`) holds all business logic and all
   queries. Edges never build Ecto queries.
2. **Every aggregate is a triad:** context (public API + mutations), Ecto schema
   (structure + changesets), `*Query` module (all reads). Reads are
   `defdelegate`'d to the query module.
3. **Errors are data.** Fallible ops return `{:ok, _}` / `{:error, %Deckex.Error{}}`.
   Raise only for genuine contract violations.
4. **Talk to the outside world through ports.** Behaviour + facade + real
   adapter + `Application.compile_env` selector + Mox mock.
5. **Test first, mock at the boundary.** No test performs network I/O.

## Project-specific laws

- **Cards are oracle-level.** One row per distinct card, keyed on `oracle_id`,
  never one per printing. `scryfall_id` is only the printing the image came
  from.
- **The card catalogue is permanent and global.** Cards are immutable; they are
  fetched once and shared across every deck. The lone mutable field is
  `price_usd` (plus `edhrec_rank`), refreshed by the upsert on re-fetch and
  advisory only — never trusted for logic.
- **Read the front face.** On `modal_dfc` / `transform` / `split` / `adventure`
  layouts, `mana_cost`, `colors` and `image_uris` live on the faces while `cmc`,
  `type_line`, `color_identity` and `produced_mana` stay at the top.
  `Deckex.Cards.ScryfallMapper.front/4` is the only place that knows this — do
  not re-derive the rule elsewhere.
- **Never `on_conflict: :nothing` on a UUID-keyed table.** Primary keys are
  generated client-side, so a skipped insert still returns a struct carrying an
  id that was never written. Upsert with an explicit `{:replace, [...]}`.
- **Scryfall budget law.** `POST /cards/collection` takes 75 identifiers per
  request and is capped at 2 requests/second. Never bypass
  `Deckex.Scryfall.Http`'s chunking or throttle, and never fetch a card the
  catalogue already holds.
- **A Scryfall miss is retried, never accepted.** Requests carry
  `retry: :transient` — `:transient` and not Req's `:safe_transient` default
  because the call that matters is a POST, and `POST /cards/collection` is a
  pure lookup. Any caller that tolerates a failure to keep going must also
  queue the work again: `Deckex.Consults.run/1` enqueues
  `Deckex.Workers.CatalogueWorker`. Verified 2026-08-24: with `retry: false`
  and the failure only logged, one 503 cost the whole batch permanently — five
  consults and ten real cards over ten days, each rendering "não achei essa
  carta na Scryfall" about a card Scryfall has, and each dropped from every
  count the audit and the optimizer make. **A card absent from the catalogue is
  indistinguishable from a card Scryfall does not have, and the app says the
  second while meaning the first.** That is why the miss cannot be left alone.
- **Moxfield is blocked, and we do not evade it.** An honest User-Agent gets a
  Cloudflare 403 (verified 2026-08-13). URL sync ships wired behind a
  configurable User-Agent for the day Moxfield approves one. **Pasting a
  decklist is the primary import path.** No browser impersonation, no
  User-Agent rotation, no CAPTCHA handling — ever.
- **Every card write takes its locks in `oracle_id` order.** The Ecto sandbox
  isolates what a test can *see*, not the locks it *takes*: two async
  transactions inserting the same card rows in different orders deadlock in
  Postgres, surfacing as a random `40P01` in whichever one lost. One global
  order means concurrent writers queue instead of colliding. This holds in
  production code (`Deckex.Cards.insert_all/1`, the classification pass) and in
  tests (`Deckex.CatalogueFixture`). **Never hand-roll a card insert in a
  test** — seed through `CatalogueFixture`, once per test, in a single call.
  This bug came back three times before the rule was written down here.
- **A Tailwind class that names a nothing is silent.** `class="text-hero"`
  compiles, renders, and does nothing; it cost four page titles their size for
  weeks. Every utility using a design-token prefix must name a token declared in
  the `@theme` block of `assets/css/app.css`. `DeckexWeb.DesignTokensTest`
  enforces it — if a class is a structural Tailwind utility with no token behind
  it, add it to that test's `@builtins` deliberately.
- **Card facts are fetched, never written down here.** The Game Changers list
  is the Commander Format Panel's and is revised a few times a year; Scryfall
  carries `game_changer` on every card object, so it arrives with the fetch we
  already do. The same goes for legality and price. A list of card names
  hardcoded in this repository is wrong within months, and wrong in the
  direction that looks authoritative.
- **The engine reports a bracket FLOOR, never a bracket.** Two of the five
  bracket criteria — whether a two-card combo exists, and whether the deck
  closes before the expected turn — need knowledge of the card pool. The
  engine states what it can count and prints the rest as questions. Naming a
  bracket we cannot prove is the same overreach as inventing a price.
- **No 1–10 power level, ever.** It is a card-ranking algorithm with a decimal
  point, and not building one is why this project exists. Brackets are
  different: they are countable rules.
- **The model never guesses at legality.** Verified 2026-08-14: a model
  declined to suggest Underworld Breach believing it banned in Commander;
  Scryfall says legal. A *decline* leaves no row for the audit to check, so
  the briefing tells the model to suggest uncertain cards and let the app
  verify them. The audit can only check what was suggested.
- **The model never states a price.** Card prices come from the catalogue, which
  gets them from Scryfall. A model's price memory is stale on a good day and
  invented on a bad one — verified 2026-08-13, when `fable` quoted a Cyclonic
  Rift 28% under its actual price. The briefing forbids it and
  `Deckex.Consults.Suggestions` discards any price field the model volunteers.
- **A card costs what its CHEAPEST printing costs.** `POST /cards/collection`
  answers a name with one printing — usually the newest, which on release day
  has no price at all. Measured 2026-08-15 over the whole catalogue: 104 of 178
  prices were wrong, Finale of Devastation by half, and four staples (Steam
  Vents, Breeding Pool, Stomping Ground, Swiftfoot Boots) held no price
  whatsoever. Unpriced is the dangerous half: the ceiling guard passes a card
  it cannot price, so the limit silently stopped applying to exactly the cards
  nobody could see. `Deckex.Cards.reprice/1` asks for the printings and takes
  the minimum; a card that arrives unpriced is queued for it automatically.
- **A price ceiling is a limit, never a target.** The engine must not prefer
  the expensive card, and the briefing says so in as many words. Cheap is not
  evidence of weak — the cheapest card any model ever suggested here was Arcane
  Signet, third most-played card in the format.
- **The price rule is a count, not a line.** A per-card ceiling answers "is
  this card too expensive" and gets the real question wrong: the owner will
  own a few cards at four hundred reais and not twelve, and wants room for the
  two that are worth breaking his own rule for. `Deckex.Budget` holds both
  tiers; the ceiling is the exception threshold and the slots above it are the
  only roof. **The audit folds rather than maps** — three suggestions each
  asking "is there room for one more?" would all be told yes, and applying the
  three leaves the deck with three of the two allowed. Cuts come first in the
  list, so a cut that frees a slot is counted before the adds are judged.
- **Building a page never reaches for the network.** Rendering a deck reads;
  fetching happens in the background job that already exists. A suggested card
  missing from the catalogue renders unresolved rather than making the page wait.
- **Analysis is pure.** `Deckex.Analysis` has no Repo, no HTTP, no process
  state. Reports are computed on demand, never cached.
- **Classification records its provenance.** Every `card_role` carries `source`
  (`:rule` / `:ai` / `:manual`) and `evidence`. A `:manual` role is never
  overwritten.
- **An informational note is not a problem.** In the audit, `problems != []`
  rejects the suggestion (in the pipeline) and excludes it from the simulation
  (everywhere). The Game Changer note "sobra espaço para 3" masqueraded as a
  problem and silently rejected every legal GC add — found by the first
  pipeline regression, 2026-08-14. If the engine only wants to *say* something,
  it must not say it in the problems list.
- **The engine states the copy's card count, every stage.** Stages may
  legitimately go net negative, no lens measures deck size, and models cannot
  count a 90-line list. The first real run reached 98/100 with nothing anywhere
  saying so. The briefing now carries the count and the direction; the run page
  shows `Cartas N/100`; a finished off-100 run warns before the owner saves.
- **Resolution gets a worker-side retry before any verdict.** The answer-time
  catalogue fetch is best-effort, and a transient Scryfall failure once got a
  perfectly real card (Barkchannel Pathway) rejected as "não resolvida". The
  pipeline's judge calls `Consults.refresh_catalogue/1` again in the worker —
  the page still never touches the network; the worker was always allowed to.

- **A new role makes the stored catalogue stale.** Cards already catalogued
  were classified before the rule existed, so a guard reading that role
  silently misses them — a rule that looks enforced and is not. Ship a rule
  together with a run of `Deckex.Cards.reclassify_all!/0`, which walks the
  catalogue in `oracle_id` order like every other card write.
- **Self-mill is not mill.** Milling yourself is a graveyard build-around;
  milling an opponent is a tactic aimed at a person, and only the second is
  something an owner asks to avoid. Templating separates them for free —
  targeted mill names its victim, self-mill omits the subject.
- **A commander swap must preserve the colour identity exactly.** Not a subset:
  a narrower commander makes every card outside its identity illegal at once, a
  cascade of cuts made for a reason that has nothing to do with the deck being
  better. `Deckex.Consults.Visions.commander_problem/2` is the only place that
  decides this.
- **Taste is enforced in one direction only.** The salt contract can refuse an
  add carrying a tactic the owner avoids, exactly like a price ceiling. It
  cannot make a model *want* something: `quero` is an invitation in the
  briefing, and treating it as a rule would be the same overreach as inventing
  a price.

- **The model floor is drawn by what an answer CHANGES.** A lens that only
  reads — `:scout`, `:bracket` — may use any model; one that proposes cutting a
  card from a real deck may not, and `:visao` counts as changing the deck
  because it names what gets bought. It **refuses** in the pipeline, where
  nobody is supervising, and only **marks** on the deck page, where model
  comparison is a feature. `Deckex.Consults.model_rank/1` is the one place that
  orders models; an unknown alias ranks lowest so a typo cannot clear the floor.
- **Redoing a stage rewinds everything after it.** Stage N's answer is the
  input to N+1; recomputing N while keeping what was built on it would leave
  the sandbox describing a history that never happened. The discarded consults
  are kept — comparing what two models said is the point.
- **A rule must be able to take a role back.** `classify_card/1` prunes
  `:rule`-sourced roles that no longer match, or a tightened rule is invisible
  and the catalogue only ever accumulates verdicts nothing would give today.
  `:ai` roles were paid for and `:manual` ones are the user's; neither is ours.
- **We never request anything from EDHREC.** Their terms forbid scripted
  requests and reproduction (verified 2026-08-14). Reachable is not permitted —
  the Moxfield law, applied to a second site. No scraping, no pages, no lists,
  no synergy percentages. Play *patterns* are measured from oracle text here
  instead: a nameable list of cards beats an opaque score.
  The one exception is `edhrec_rank`, a single ordinal that arrives inside the
  Scryfall card object the catalogue already fetches — no request to their site
  and no reproduction of their content. It is **shown and never enforced**: it
  renders next to a card so the owner can see that a two-real card is the third
  most-played in the format, and no guard, filter or ranking reads it. The day
  it decides something on its own it has become the power level this project
  refuses to build.
- **A creature that carries the engine is not a blocker.** You do not block
  with your mana or your win condition, so counting those bodies as defence
  lies. The reference deck holds eight creatures with real toughness and can
  defend with two — which is exactly what its owner reported before the engine
  could see it.

- **A rule for every lens goes in `rules_block/3`, never in a task block.**
  Twice in one afternoon a universal rule was written into one branch, and both
  times the lenses that needed it most were the ones that missed it: the
  findings scope left `:visao`, `:upgrade`, `:budget` and `:matchup` being told
  a deck with two criticals "passed every lens", and the flexible-answers rule
  reached only the lenses without a task block of their own. `BriefingTest`
  walks `Consult.lenses()` and asserts the universal pieces reach all of them —
  guard the class, not the two instances you happened to find.

- **The sandbox list is the main board; the commanders are not in it.** The
  hundred-card rule is about the deck, so the pipeline measures
  `Optimizations.sandbox_size/2` and never `card_count/1`. Confusing the two
  meant every "Cartas 100/100" the run page printed described a deck of 101,
  and the reference deck finished an entire eight-stage run one card over
  legal with nothing anywhere saying so.
- **A run may not end on a list that cannot go on a table.** Ordinary stages
  walk the count toward 100 a card or two at a time — the owner's own
  preference, and it means every card that leaves was the worst card left when
  it left — but walking slowly does not guarantee arriving. When the recipe is
  spent and the copy is off 100, the run appends a **closing stage** whose only
  job is the count, bounded at `@max_balance_stages`. `Deckex.Optimizations.Balance`
  holds both halves: the briefing **asks** for a direction, the engine **caps**
  the drift, and nothing here can make a model want to cut a card — the same
  one-way rule the salt contract follows.
- **Balance is judged on the answer's NET, never on a running count.** Cuts
  come first in an answer, so the count dips before it recovers: judging card
  by card refused every cut on a deck that was short, before reaching the adds
  that paid for them. A swap is not a drift. Ordinary stages get a card or two
  of slack; the closing stage gets none.
- **A test deck is 100 cards.** Five-card fixtures were a fiction that worked
  only while nothing checked the count, and two features now do. The same
  lesson as `commander_legal` defaulting to `false` in `AnalysisFixture`: a
  fixture that models something impossible hides the bug it was meant to catch.
- **The owner outranks the pipeline about his own cards.** Every stage is
  arithmetic plus a model's reading of card text, and a misreading is a real
  failure mode — Jaheira turns Food into creatures that tap for mana, and a
  stage cut her for "só dá mana a tokens de criatura". So a run ends with an
  optional **review stage** built from cards the owner bookmarked while
  reading and what he wrote about each. In that stage his word beats the
  model's reading, and it beats the flip-flop guard for the cards he named —
  the churn guard exists to stop two models arguing in circles, and a person
  with new information is not churn. Everything else still applies: the engine
  audits, the budget holds, the count lands on a hundred.
- **Every model call is measured, and never estimated.** The CLI envelope
  carries `usage` and `total_cost_usd` on every answer; the adapter reads them
  and `Deckex.AI.Ledger` records one row per call. Every meter on screen — the
  global one, the per-deck one, the per-consult one — is the same rows summed
  differently, so no two numbers can disagree. A call that reported no usage
  writes **no row**: a row of zeros reads exactly like a measurement, and an
  estimated token count is worse than none because it looks the same.
- **A correction is knowledge about the deck, not about the run.** The note he
  writes in a review is upserted onto the deck as a `deck_card_note` and
  injected into **every future briefing for that deck** — with the instruction
  that where it contradicts the model's reading, his reading wins. It cost a
  run to notice and a review to say; making him say it again next month would
  be the app forgetting on purpose. Editable and forgettable on the deck page,
  beside the dossier, because both are what the owner knows that no number
  shows.
- **A mark is a bookmark, not a verdict.** Marking costs one click in the
  middle of reading and says only "come back to this"; the note is written at
  the end, against a list, when the run has stopped moving. A stage that costs
  a consult and has nothing to answer is refused rather than run.
- **An applied optimization is a version of the deck it came from.** A run is
  work done on a deck, so applying it writes the deck's own cards and marks the
  version that says what it did — `Versions.apply_list/4`, never a second deck
  named "— otimizado". Forking still exists for the owner who wants both lists
  side by side, which is a different intention and reads as one on the page.
- **Nothing overwrites a list that was never saved.** `apply_list/4`
  photographs the working state first when it has drifted from the last
  version, or when there is no version at all. The five cards someone edited by
  hand before running the optimizer are theirs to go back to.
- **A change records why it happened, at the moment it happens.** Comparing
  two lists recovers *what* changed and can never recover *why*, so every add
  and every cut writes a `deck_edits` row carrying the consult's own sentence —
  and the next version consumes those rows instead of diffing. The diff is
  still there as the fallback, and it is the right fallback: always correct
  about what, silent about why.
- **A punctual consult ends where the Otimizador ends.** Applying an answer is
  one act — `Decks.apply_suggestions/3` — that writes the cards and marks the
  version, origin `:consult`, pointing at the consult. The engine's refusals
  are excluded from it: overriding the audit is something the owner does one
  click at a time, with the reason printed beside the row, never in bulk.
- **A version's changelog is the net, not the transcript.** A card added by one
  stage and cut by a later one nets to nothing, and the history reads as what
  happened to the deck rather than as a diary of the run — the same fold
  `consolidated_diff/2` already applies to the shopping list.
- **The owner says it once, not once per round.** A card's stance
  (`deck_card_notes.stance`) belongs to the deck: `:locked` is merged into
  every run's protection list at launch *and* read live by the audit, so a lock
  written at stage four binds stage five. The launch modal's box is an
  exception for one round, never the only place a card can be protected — it
  came up empty every time, which is exactly how a combo piece got cut.
- **An order does not need a reason, but the reason is what teaches.** A locked
  or wanted card may carry no text; only a bare observation disappears when its
  text is erased. The text is what reaches the briefing, and it is the half
  that stops the next run misreading the same card.
- **The dossier goes stale wherever the list is replaced, not only where it is
  edited.** `Versions.write_back/4` flags it, the same as `add_card/3` does —
  applying a run rewrites every card at once and used to leave the flag alone,
  so a deck could take two optimizations and still hand the next briefing a
  description of a deck that no longer existed. `Optimizations.recipe/2`
  schedules the scout off that same flag, so a dossier that cannot go stale
  cannot be rewritten either. A restore that lands on an identical list changes
  nothing and says nothing: a false staleness costs a consult to clear.
- **"Enters tapped" is a clause, not a verdict.** Every modern dual attaches a
  condition to it, and the conditions are load-bearing: a shockland is untapped
  for two life, a fastland is untapped in exactly the turns a fast deck lives
  in, and a battlebond land's condition — two or more opponents — is the
  definition of this format. So `Mana.tapland_weight/1` weighs rather than
  judges: 1 unconditional, ½ conditional (the same half the MDFC lands get), 0
  when the format itself satisfies the condition. A finding names only the
  cards it counted; naming the rest is how a stage spends a paid answer arguing
  with the engine instead of working it.
- **A round of one stage changes only what was asked.** `:livre` has no
  checkpoint after it to catch an overreach and no validation to argue with it,
  so its briefing asks for narrowness rather than ambition. The audit, the
  sandbox and the closing balance stage still apply: one stage is still a
  round, not a shortcut around the engine.

## Operating notes

- **`mix run` starts Oban, and Oban consumes.** A script that enqueues a job
  will often be the process that *picks it up*, and when the script ends the
  VM dies mid-job: the row sits in `executing` with no producer until the
  Lifeline plugin rescues it, up to half an hour later. Launching the first
  real Fable run cost exactly that. Enqueue from the running app, or hand the
  job back with
  `docker exec deckex-db-1 psql -U postgres -d deckex_dev -c "UPDATE oban_jobs
  SET state='available', attempted_at=NULL, attempt=0 WHERE id=<id>"` — and
  inspect through `psql` rather than `mix run` while a run is in flight, so a
  throwaway instance cannot steal the next stage.

## Quality gate

`mix lint` must be green **before** every commit — not after:

```
format --check-formatted, deps.unlock --check-unused, credo --strict,
sobelow --config, dialyzer
```

`mix precommit` runs `compile --warnings-as-errors`, `deps.unlock --unused`,
`format`, `test`.

Credo runs `--strict`. Findings in generator output are fixed, not suppressed.

## Local setup

PostgreSQL runs in Docker on **host port 5435** (5432/5433/5434 belong to other
projects on this machine).

The app serves on **port 4005**.

```bash
docker compose up -d
mix setup
mix phx.server
```

Note: after changing an already-applied migration, the test database keeps the
old schema (same timestamp = considered applied). Drop it:
`MIX_ENV=test mix ecto.drop`.
