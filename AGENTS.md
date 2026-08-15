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
- **We do not consume EDHREC's data.** Their terms forbid scripted requests and
  reproduction (verified 2026-08-14). Reachable is not permitted — the Moxfield
  law, applied to a second site. Play patterns are measured from oracle text
  here instead, which is better anyway: a nameable list of cards beats an
  opaque score.
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
