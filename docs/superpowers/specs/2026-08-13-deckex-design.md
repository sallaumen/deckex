# deckex — Design Spec

**Date:** 2026-08-13
**Status:** Approved (design), pending implementation plan

---

## 1. What we are building

A single-user web application that ingests a Magic: The Gathering **Commander
(EDH)** decklist, enriches it with authoritative card data, computes a
deterministic diagnostic report about the deck's *shape*, and hands that report
to Claude — with web search enabled — to get concrete, cited suggestions for
what to cut and what to add.

The product answers one recurring frustration, in the owner's words: *"tenho
decks que são muito lentos", "decks muito rápidos que não sobrevivem ao late
game", "decks faltando mana, sentindo falta de ramp de terreno."* Each of those
is a measurable property of a 100-card list. The app measures them; the AI
interprets them against a card pool it can search online.

### What we are explicitly NOT building

- **Not a card evaluation engine.** We never decide that card A is "better" than
  card B. That is what the AI (with web search) is for, and it is already solved
  elsewhere. We describe the deck's shape; the AI reasons about the card pool.
- **No opening-hand Monte Carlo simulation in v1.** It fits cleanly into the pure
  analysis core later, but it is not the thing losing games today.
- **No match/result logging in v1.** The data model leaves room for it without a
  painful migration.
- **No multi-format support.** Commander only. This is a deliberate constraint:
  it makes every baseline sharp instead of hedged.

---

## 2. Stack and conventions

Phoenix 1.8 + LiveView 1.2 + PostgreSQL + Oban, on Elixir 1.19 / OTP 27 —
matching `beatgrid` and `forrozin_page`.

OTP app `:deckex`; modules `Deckex` (domain) and `DeckexWeb` (edges).

Dependencies beyond the Phoenix defaults, mirroring the reference projects:
`oban` (async pipeline), `req` (HTTP for both external ports), `uniq` (UUID v7
primary keys), `dotenvy` (config), `credo` + `dialyxir` + `sobelow` +
`ex_check` + `excoveralls` (quality gate), `ex_machina` + `mox` (test), and
`heroicons` + `tailwind` + `esbuild` (assets).

This project adopts the **Elixir/Phoenix Architecture & Quality Playbook** in
`docs/playbook/` wholesale (copied from `beatgrid`). Its five principles are the
ground truth:

1. Layer strictly, depend inward. Edges translate and delegate; they never build
   Ecto queries.
2. Every aggregate is a triad: context (public API + mutations), Ecto schema
   (structure + changesets), `*Query` module (all reads).
3. Errors are data. Fallible operations return `{:ok, _}` / `{:error, _}`;
   domain errors are `Deckex.Error` structs with `:code`, `:message`, `:details`.
4. Talk to the outside world through ports: behaviour + real adapter +
   `Application.compile_env!` selector + Mox mock.
5. Test first, mock at the boundary.

### Language rule (hard)

- **Code is English:** identifiers, module and function names, `@moduledoc` /
  `@doc`, commit messages.
- **User-facing text is pt-BR:** UI chrome, flash messages, finding titles,
  error copy. The product speaks the player's language.
- **Card names are never translated.** They are data and the identifier used
  against Scryfall.

### Scope decisions from the playbook

We follow the playbook but scale infrastructure to a **single-user local app**.
Omitted for v1, all explicitly optional in the playbook: GraphQL (Absinthe),
public REST API, Broadway, Elasticsearch, Cloak encryption, clustering,
PaperTrail. Adopted in full: the triad, errors-as-data, ports & adapters + Mox,
the wrapped `Deckex.Repo`, `Repo.transact/1`, `Ecto.Enum`, UUID v7 primary keys,
idempotent migrations, Oban worker conventions, and the testing matrix.

---

## 3. Architecture

```
Inbound edges           Domain core (lib/deckex)          Outbound ports
─────────────           ────────────────────────          ──────────────
LiveViews         →     Deckex.Cards      ──────────→     Scryfall.Client
Oban workers      →     Deckex.Decks      ──────────→     Moxfield.Client
                        Deckex.Analysis   (pure)          AI.Client
                        Deckex.Consults   ──────────→     Repo / PostgreSQL
                        Deckex.Settings
```

### 3.1 `Deckex.Cards` — the global card catalogue

```
lib/deckex/cards.ex               # public API
lib/deckex/cards/card.ex          # schema + changesets
lib/deckex/cards/card_query.ex    # all reads
lib/deckex/cards/roles.ex         # rule engine (pure)
lib/deckex/cards/role_ai.ex       # AI residue classification
lib/deckex/cards/card_role.ex     # schema for a classified role
lib/deckex/cards/scryfall_mapper.ex  # Scryfall JSON → Card attrs
```

**Cards are stored at the *oracle* level, one row per distinct card, not per
printing.** Deck analysis does not care which printing of Sol Ring you own.
`oracle_id` is the unique business key; `scryfall_id` is retained only as the
representative printing we pulled the image from.

Cards are effectively immutable and cached forever. The one mutable field is
`price_usd`, refreshed opportunistically on deck sync and treated as advisory
only.

### 3.2 `Deckex.Decks` — the user's decks

```
lib/deckex/decks.ex
lib/deckex/decks/deck.ex
lib/deckex/decks/deck_card.ex
lib/deckex/decks/deck_query.ex
lib/deckex/decks/decklist_parser.ex   # text decklist → [{qty, name, board}]
lib/deckex/decks/import.ex            # orchestration: fetch → parse → resolve
```

**Name matching rule (explicit).** Decklists identify cards by name, and the
same card appears written several ways in the wild: `1 Cultivate`,
`1 Cultivate (M21) 177`, `1 Agadeem's Awakening`, and
`1 Agadeem's Awakening // Agadeem, the Undercrypt`. The parser strips set codes
and collector numbers, and `name_normalized` is built from the **front face
only** (text before ` // `), downcased and accent-stripped. Both the full
double-faced name and the front-face-only name therefore resolve to the same
card. Anything still unresolved goes to Scryfall by name and, failing that, is
reported to the user by name.

### 3.3 `Deckex.Analysis` — the pure functional core

**This module has no Repo, no HTTP, no Oban, no process state.** It takes a
fully-loaded `DeckSnapshot` struct and returns a `Report` struct. It is the most
important boundary in the system: it makes the diagnostics fast, trivially
testable, and impossible to serve stale.

```
lib/deckex/analysis.ex                 # report/1, the single entry point
lib/deckex/analysis/deck_snapshot.ex   # input struct
lib/deckex/analysis/card_entry.ex      # card + quantity + role set
lib/deckex/analysis/baselines.ex       # Commander reference numbers
lib/deckex/analysis/curve.ex           # lens: speed & curve
lib/deckex/analysis/mana.ex            # lens: mana & ramp
lib/deckex/analysis/interaction.ex     # lens: interaction
lib/deckex/analysis/consistency.ex     # lens: consistency & closing
lib/deckex/analysis/finding.ex         # finding struct
lib/deckex/analysis/report.ex          # report struct + JSON encoding
```

**Reports are computed on demand, every time, and never persisted as live
state.** Computing one is arithmetic over ~100 in-memory structs — microseconds.
This eliminates an entire class of stale-cache bugs. (A report *is* frozen into
`consults.report_snapshot` when a consult is created, so that consult stays
reproducible — but that is a historical record, not a cache.)

### 3.4 `Deckex.Consults` — AI diagnostic runs

```
lib/deckex/consults.ex
lib/deckex/consults/consult.ex
lib/deckex/consults/consult_query.ex
lib/deckex/consults/briefing.ex     # Report + lens → Markdown prompt
lib/deckex/consults/schemas.ex      # JSON output schema per lens
```

Every consult persists the **exact briefing sent**, the **frozen report
snapshot**, the model used, and the structured response. This makes runs
reproducible and auditable — and it makes the "copy the command and run it in
your own terminal" affordance free, since the prompt is already stored.

### 3.5 `Deckex.Settings`

Key/value settings with a typed registry (mirroring `beatgrid/settings`):
`moxfield_user_agent`, `claude_model`, `claude_timeout_ms`, `max_budget_usd`,
and per-key overrides for every baseline in `Analysis.Baselines`.

---

## 4. Ports

Each is a behaviour + real adapter + `Application.compile_env!` selector + Mox
mock. **Tests never touch the network.**

| Port | Real adapter | Talks to |
|---|---|---|
| `Deckex.Scryfall.Client` | `Scryfall.Http` (Req) | Scryfall REST API |
| `Deckex.Moxfield.Client` | `Moxfield.Http` (Req) | Moxfield deck endpoint |
| `Deckex.AI.Client` | `AI.ClaudeCli` | `claude` CLI, headless |

### 4.1 Scryfall

Official, free, documented. Requests set a descriptive `User-Agent` and
`Accept: application/json`, as the API requires.

- Bulk resolution uses `POST /cards/collection`, **75 identifiers per batch**,
  throttled to **2 requests/second** (that endpoint's hard cap; the rest of the
  API allows 10/s).
- A 100-card Commander deck resolves in **2 requests**, and only for cards not
  already in the local catalogue.
- Identifiers are sent as `{"name": "..."}`. Unresolved names come back in
  `not_found` and are surfaced to the user as an import warning naming each
  card, never silently dropped.

### 4.2 Moxfield

**Moxfield has no official public API.** Its Terms of Service prohibit scraping,
and programmatic access is gated behind a `User-Agent` approved by e-mailing
support@moxfield.com. The deck endpoint used by community tools is undocumented,
sits behind Cloudflare, and returns public decks only.

**Verified empirically on 2026-08-13.** A single `GET` to
`api2.moxfield.com/v3/decks/all/<publicId>` carrying an honest, identifying
`User-Agent` returned **HTTP 403** with a Cloudflare challenge page, not deck
JSON. This is the expected behaviour for an unapproved client, and it sets the
v1 reality:

- **Pasting the decklist is the primary, working import path in v1.**
- **URL sync ships implemented but blocked.** It is wired end to end behind the
  configurable `User-Agent`, so the day Moxfield approves one, the owner pastes
  it into Ajustes and sync begins working with no code change.
- The UI must therefore never present URL sync as the default happy path while
  it is blocked; it surfaces `:moxfield_blocked` with the paste form inline.

The owner chose automatic URL sync with this understood. The implementation is
therefore **honest, not evasive**:

- A single, **identifiable and user-configurable** `User-Agent` (settable in
  Ajustes). This is precisely what makes it possible to request sanctioned
  access from Moxfield support and become legitimate.
- **One request per explicit user-initiated sync.** No polling, no crawling, no
  background refresh loops.
- Responses are persisted; a deck is never re-fetched without the user asking.
- **No detection evasion.** No browser fingerprint impersonation, no User-Agent
  rotation, no CAPTCHA handling, no proxying.
- On any block or failure the app degrades gracefully: it reports what happened
  and offers the paste path.

**The paste path is the primary import feature**, not a hidden fallback. It is
the only way to import a private deck, the only path that works today, and the
only one that cannot break.

### 4.3 AI

Adapted from `beatgrid/lib/beatgrid/ai/claude_cli.ex`. Runs
`claude -p <prompt> --output-format json --json-schema <schema>` and returns the
`structured_output` object. Two hardening details carried over verbatim, both
learned the hard way in beatgrid:

- **stdin redirected from `/dev/null`** — the CLI otherwise blocks forever
  waiting for piped input when spawned non-interactively from `phx.server`.
- **The whole call is bounded by a timeout**, surfacing `{:error, :timeout}`
  instead of an endless spinner.

Consults run with `--allowedTools WebSearch` so the model can ground its
suggestions in the current card pool and meta. This is the point of the whole
feature: the app supplies measured facts about *this* deck, the model supplies
knowledge about *all* cards.

---

## 5. Data model

All tables use UUID v7 primary keys and `:utc_datetime` timestamps.

### `cards`

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK |
| `oracle_id` | uuid | **unique**, the business key |
| `scryfall_id` | uuid | representative printing |
| `name` | text | canonical Scryfall name |
| `name_normalized` | text | **unique**; downcased, accent-stripped, front face for DFCs |
| `mana_cost` | text | nullable (null on DFCs, see below) |
| `cmc` | numeric(4,1) | Scryfall returns floats |
| `type_line` | text | |
| `oracle_text` | text | |
| `colors` | text[] | |
| `color_identity` | text[] | |
| `produced_mana` | text[] | |
| `keywords` | text[] | |
| `edhrec_rank` | integer | nullable; popularity signal |
| `rarity` | text | |
| `layout` | text | `normal`, `modal_dfc`, `transform`, `split`, `adventure`… |
| `card_faces` | jsonb | face name / mana_cost / type_line / oracle_text |
| `image_normal_url` | text | |
| `image_art_crop_url` | text | |
| `commander_legal` | boolean | from `legalities.commander` |
| `price_usd` | numeric(10,2) | advisory, refreshed on sync |
| `prices_updated_at` | utc_datetime | |
| `scryfall_uri` | text | link out |
| `fetched_at` | utc_datetime | |

**Double-faced card rule (explicit).** For `modal_dfc` / `transform` / `split` /
`adventure` layouts, the top-level `mana_cost` is `nil` and `type_line` is
`"Sorcery // Land"`-shaped. All analysis reads the **front face** for cost and
type, except the mana lens, which additionally inspects the back face: **an MDFC
whose back face is a Land counts as 0.5 toward the land count.** This is the
established Commander convention and materially changes land-count findings for
modern decks.

### `card_roles`

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK |
| `card_id` | uuid | FK → cards, on delete cascade |
| `kind` | enum | see below |
| `confidence` | enum | `:high` / `:medium` / `:low` |
| `source` | enum | `:rule` / `:ai` / `:manual` |
| `evidence` | text | which rule matched, or the model's reasoning |

Unique index on `(card_id, kind)`.

**Role kinds** (`Ecto.Enum`): `:ramp`, `:ritual`, `:cost_reduction`, `:fixing`,
`:counter`, `:spot_removal`, `:board_wipe`, `:protection`, `:draw`, `:tutor`,
`:recursion`, `:wincon`, `:graveyard_hate`, `:stax`.

A card may hold several: `Cultivate` is `:ramp` + `:fixing`; `Chromatic Lantern`
is `:ramp` + `:fixing`; `Cyclonic Rift` is `:board_wipe` + `:protection`.

**`:ritual` and `:cost_reduction` are separate from `:ramp` on purpose**, added
2026-08-13 after a manual pass over a real deck. Lumping them together reported
five ramp pieces where the deck had one: `Desperate Ritual` and `Seething Song`
are one-shot bursts that do not help you cast a 6-drop a turn earlier on an
empty board, and `Goblin Electromancer` / `Baral` / `Sorcerer Class` reduce
spell costs without adding mana. All three behave differently on the curve, and
the mana lens must not count them as the same thing.

Likewise **`:counter` and `:spot_removal` must never be summed into a single
"interaction" figure.** A counterspell is a dead card once the threat has
resolved; against an aggressive deck only the answers that address a permanent
already on the battlefield count. The interaction lens reports them separately
for this reason.

`:manual` is never overwritten by a later rule or AI pass. A user correction is
permanent and becomes evidence for improving the rules.

### `decks`

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK |
| `name` | text | |
| `moxfield_url` | text | nullable |
| `moxfield_public_id` | text | nullable, unique where not null |
| `source` | enum | `:moxfield` / `:paste` |
| `color_identity` | text[] | derived from the commander(s) |
| `status` | enum | `:importing` / `:enriching` / `:classifying` / `:ready` / `:failed` |
| `last_synced_at` | utc_datetime | |
| `last_error` | text | |
| `notes` | text | free-form user notes; fed to the AI briefing |
| `archived_at` | utc_datetime | soft delete |

### `deck_cards`

`deck_id` (FK, cascade), `card_id` (FK), `quantity` (integer, default 1),
`board` (`:main` / `:commander` / `:maybe`). Unique on
`(deck_id, card_id, board)`.

### `consults`

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK |
| `deck_id` | uuid | FK → decks, cascade |
| `lens` | enum | `:speed_curve` / `:mana_ramp` / `:interaction` / `:consistency` / `:full` / `:finding` |
| `finding_code` | text | set when `lens == :finding` |
| `status` | enum | `:pending` / `:running` / `:done` / `:failed` |
| `briefing` | text | the exact prompt sent |
| `report_snapshot` | jsonb | the frozen report |
| `response` | jsonb | structured model output |
| `model` | text | |
| `error` | text | |
| `duration_ms` | integer | |

### `settings`

`key` (text, PK), `value` (jsonb), timestamps. Typed through
`Deckex.Settings.Registry`.

---

## 6. Import pipeline

```
User pastes a Moxfield URL (or a decklist)
        │
        ▼
Decks.import_from_url/1 → creates deck (:importing) → enqueue ImportDeckWorker
        │
        ├─ Moxfield.Client.fetch_deck/1        (:moxfield source)
        │    └─ on {:error, :blocked | :private} → deck :failed with a
        │       user-facing message offering the paste path
        │
        ▼
DecklistParser → [{quantity, name, board}]
        │
        ▼
Resolve names against the local catalogue (name_normalized)
        │
        ├─ all present → skip ahead
        └─ missing → deck :enriching → EnrichCardsWorker
                       └─ Scryfall POST /cards/collection, 75/batch, 2 req/s
                          not_found names surfaced as import warnings
        │
        ▼
Cards.Roles.classify/1 on every newly inserted card  (pure, instant, free)
        │
        ├─ high confidence → persisted, done
        └─ ambiguous/unmatched → deck :classifying → ClassifyCardsWorker
                                   └─ Claude, batched, result cached on the card
        │
        ▼
deck :ready — PubSub broadcast; the LiveView fills in progressively
```

Worker error semantics follow the playbook: `{:cancel, reason}` for permanent
failures (deck not found, deck private, not Commander-legal), `{:error, reason}`
for transient ones (network, rate limit), with backoff.

**No external HTTP call happens inside an open transaction** (playbook rule 4).
Fetch first, then write.

---

## 7. The analysis engine

### 7.1 Role classification: rules first, AI on the residue

The rule engine (`Cards.Roles`) is a pure function
`classify(%Card{}) :: [%RoleMatch{kind, confidence, evidence}]`. It matches on
`type_line`, `oracle_text`, `produced_mana` and `cmc`.

Worked examples that motivated this design:

| Card | Rule signal | Result |
|---|---|---|
| `Sol Ring` | `produced_mana: ["C"]`, cmc 1, Artifact | `:ramp`, high |
| `Command Tower` | `produced_mana: [W,U,B,R,G]`, Land | `:fixing`, high |
| `Counterspell` | oracle matches `"Counter target spell"` | `:counter`, high |
| `Cultivate` | `produced_mana: nil` — invisible to the mana rules; only oracle text `"Search your library for … land … onto the battlefield"` reveals it | `:ramp` + `:fixing`, high |
| `Smothering Tithe` | no direct signal; conditional, wordy | **residue → AI** |

`Cultivate` is exactly why pure `produced_mana` inspection is insufficient, and
`Smothering Tithe` is exactly why regex alone is insufficient. Hence the hybrid.

Only cards where **no rule matched** or **every match is low confidence** are
sent to the AI, batched. The result is written to `card_roles` with
`source: :ai` and cached **globally** — the catalogue is shared across every
deck, so the second deck importing Smothering Tithe pays nothing.

Every number in the UI can be traced to the roles behind it, and every role
shows its `source` and `evidence`.

### 7.2 Baselines

Every threshold the engine tests against lives in `Analysis.Baselines` as a
struct with these defaults, and every one is overridable per-deck from Ajustes.
These are **heuristics for 99-card Commander**, chosen to be defensible starting
points, not laws.

| Key | Default | Meaning |
|---|---|---|
| `avg_cmc_low` | 2.4 | Below this, the deck is fast; check it has a late game |
| `avg_cmc_high` | 3.5 | Upper edge of the healthy band |
| `avg_cmc_slow` | 3.8 | Above this without ramp, the deck is genuinely slow |
| `land_base` | 36 | Starting land count, before CMC/ramp adjustment |
| `land_min` / `land_max` | 33 / 40 | Hard rails for the adjusted target |
| `ramp_target` | 10 | Total ramp pieces |
| `ramp_cheap_target` | 4 | Of those, how many must cost ≤2 CMC |
| `early_play_target` | 12 | Nonland cards castable at ≤3 CMC |
| `late_game_floor` | 5 | Cards at 5+ CMC below which there is no late game |
| `top_heavy_share` | 0.20 | Share of nonlands at 6+ CMC that reads as top-heavy |
| `interaction_target` | 8 | Healthy interaction count |
| `interaction_floor` | 5 | Below this is a critical finding |
| `board_wipe_target` | 2 | Below this the deck cannot reset a board |
| `draw_target` | 8 | Card advantage pieces |
| `sources_single_pip` | 19 | Colour sources for a single coloured pip on curve |
| `sources_double_pip` | 25 | For `{B}{B}`-style costs |
| `sources_triple_pip` | 31 | For `{B}{B}{B}`-style costs |
| `tapland_share_max` | 0.25 | Share of lands entering tapped before it costs real tempo |

**Land target formula.** `land_base`, adjusted: `+1` per 0.25 that average CMC
exceeds `avg_cmc_high`, `-1` per 3 ramp pieces beyond `ramp_target`, clamped to
`[land_min, land_max]`. MDFC land backs count 0.5 toward the actual count.

### 7.3 Lens: Velocidade & Curva (`Analysis.Curve`)

Computes: CMC histogram bucketed `0,1,2,3,4,5,6,7+` excluding lands; average CMC
(reported both with and without lands); count of nonland cards castable at ≤3
CMC ("early plays"); count at ≥5 and ≥6 CMC; percentage of the nonland deck at
6+.

Findings emitted:

| Code | Condition |
|---|---|
| `curve.too_slow` | avg CMC > `avg_cmc_slow` **and** ramp count < `ramp_target` |
| `curve.no_early_plays` | early plays < `early_play_target` |
| `curve.top_heavy` | share of nonlands at 6+ CMC > `top_heavy_share` |
| `curve.no_late_game` | cards at 5+ CMC < `late_game_floor` and avg CMC < `avg_cmc_low` |

### 7.4 Lens: Mana & Ramp (`Analysis.Mana`)

Computes:

- **Land count**, counting MDFC-land backs as 0.5.
- **Effective land target**, derived from average CMC and ramp count rather than
  a flat number: a deck averaging 2.6 with 12 ramp pieces genuinely wants fewer
  lands than one averaging 3.9 with 6.
- **Sources vs. pip demand, per colour.** For each colour: count every card that
  can produce it (lands, rocks, dorks, "any colour" effects), and compare
  against the deck's heaviest pip requirement in that colour. This is the
  calculation that catches the classic failure — *eight cards demanding `{B}{B}`
  behind twelve black sources.*
- **Ramp by cost band**: pieces at ≤2 CMC, at 3, at 4+. Cheap ramp is what
  actually accelerates; a deck whose ramp all costs 4 is not a ramp deck.
- **Tapland count** — lands whose oracle text says they enter tapped.

**Source targets are a documented heuristic, not a law.** For a 99-card deck we
use the commonly cited Karsten-style framework — roughly 19 sources for a single
coloured pip on curve, 25 for a double pip, 31 for a triple. Every one of these
numbers lives in `Analysis.Baselines` and is **editable in Ajustes**. The app
states the number and its basis; the AI supplies the nuance.

Findings: `mana.land_count_low`, `mana.land_count_high`,
`mana.color_starved` (one per deficient colour, naming the demanding cards),
`mana.ramp_low`, `mana.ramp_too_slow`, `mana.tapland_heavy`.

### 7.5 Lens: Interação (`Analysis.Interaction`)

Counts `:counter`, `:spot_removal`, `:board_wipe`, `:protection` and
`:graveyard_hate`, each split by **speed** (instant-speed vs. sorcery-speed) and
by cost band. Six removal spells at sorcery speed do not hold a table the way
six at instant speed do, and a single total would hide that.

Findings: `interaction.total_low`, `interaction.no_board_wipes`,
`interaction.board_wipes_low`, `interaction.sorcery_speed_heavy`,
`interaction.no_protection`.

**`board_wipes_low` is separate from `no_board_wipes`** — added 2026-08-13 after
measuring a real deck. That deck held exactly one sweeper, so a finding that
only fires at zero stayed silent about the thing most likely to be losing it
games. Zero sweepers is critical; one is a warning; neither is fine.

### 7.6 Lens: Consistência & Fecho (`Analysis.Consistency`)

Counts `:draw`, `:tutor`, `:recursion`, and identifies `:wincon` cards. Computes
**redundancy**: which effects the deck holds exactly one copy of — its single
points of failure. Reports median `edhrec_rank` as a rough "how far off the
beaten path is this list" signal.

Findings: `consistency.draw_low`, `consistency.no_wincon`,
`consistency.single_point_of_failure`.

### 7.7 Findings

```elixir
%Finding{
  code: String.t(),           # "mana.color_starved"
  severity: :critical | :warning | :info,
  lens: :speed_curve | :mana_ramp | :interaction | :consistency,
  title: String.t(),          # pt-BR, user-facing
  detail: String.t(),         # pt-BR explanation
  evidence: map(),            # the raw numbers behind it
  card_names: [String.t()]    # the cards implicated
}
```

Findings are what turn measurement into the button the owner asked for. The deck
screen lists every finding the engine detected, and **each finding carries its
own "pedir diagnóstico à IA sobre isso"** — which builds a briefing scoped to
that one problem, including only the implicated cards. Different problem →
different prompt, different output schema, different card slice. The four lenses
remain independently invocable at any time, and a `:full` consult covers
everything.

---

## 8. Errors

`Deckex.Error` is a `defexception` struct with `:code`, `:message`, `:details`.
Codes and their user-facing pt-BR treatment:

| Code | UI treatment |
|---|---|
| `:moxfield_blocked` | "O Moxfield bloqueou a busca." + inline paste textarea |
| `:moxfield_private` | "Esse deck é privado." + inline paste textarea |
| `:moxfield_not_found` | "Não achei esse deck. Confere o link?" |
| `:scryfall_unavailable` | Retry with backoff; banner while degraded |
| `:cards_not_found` | Import completes; warning names each unresolved card |
| `:not_commander_legal` | Names the offending cards; import proceeds with a warning |
| `:ai_timeout` | Consult marked `:failed`, one-click re-run |
| `:ai_unavailable` | "O `claude` CLI não respondeu." + the exact command to test it |

Raising is reserved for genuine contract violations (a missing preload, an
impossible state) — never for expected failure.

---

## 9. UI — "A Mesa"

**Creative north star.** A playmat under low light. The table is dark and
slightly warm-green, like felt; the card art is the light on it. Magic's own
artwork is the most beautiful thing in this domain and the interface treats it
as the primary visual mass, not as decoration. Numbers are monospaced and dense,
because this is an instrument.

`DESIGN.md` at the repo root carries the full token set in YAML frontmatter,
matching the `beatgrid` format, so the design system is machine-readable.

**WUBRG is the entire semantic palette.** Every Magic player reads the five
colours instantly — no legend required. This creates one real design problem
worth stating: **black mana on a near-black table is invisible.** So the ramp is
lifted rather than literal:

| Mana | Token | Reasoning |
|---|---|---|
| W | `#f8f0d8` | Parchment, not pure white — pure white blows out against the dark table |
| U | `#4a90d9` | |
| B | `#8b7d94` | **Lifted grey-violet, not black** — pure black vanishes on the base |
| R | `#e05c48` | |
| G | `#4fa363` | |
| C | `#9aa0aa` | Colourless / generic |

Severity uses a separate ramp so it never collides with colour identity:
critical (coral), warning (amber), healthy (green).

### Screens

| Screen | Content |
|---|---|
| **Mesa** (`/`) | Grid of decks. Each tile is the commander's `art_crop`, the deck name, WUBRG identity pips, and a vital sign — the count of critical findings. |
| **Deck** (`/decks/:id`) | The list with card images, the mana curve chart, the four lens panels summarised, and the findings feed. |
| **Lente** (`/decks/:id/:lens`) | One diagnostic in full: the numbers, the implicated cards, the evidence trail behind each role, and the consult panel. |
| **Consultas** (`/decks/:id/consultas`) | Consult history. Each entry renders the structured AI response and exposes the exact briefing that was sent, with a copy button for taking it to your own terminal. |
| **Ajustes** (`/ajustes`) | Moxfield User-Agent, Claude model and timeout, budget ceiling, and every editable baseline. |

Import happens in a modal available from Mesa, with two tabs: **URL do
Moxfield** and **Colar lista**. Both are first-class.

Progressive states matter: import is a multi-stage async pipeline, and the deck
screen renders each stage as it lands via PubSub rather than blocking on a
spinner.

---

## 10. Testing

| Layer | Approach |
|---|---|
| `Analysis.*` | Pure unit tests, no database. Fast, and where coverage is cheapest and most valuable. |
| `Cards.Roles` | Table-driven tests over **real Scryfall JSON fixtures** — a curated set covering every role plus the known-hard cases: Cultivate, Sol Ring, Command Tower, Counterspell, Swords to Plowshares, Wrath of God, Cyclonic Rift, Dockside Extortionist, Smothering Tithe, Bloom Tender, Agadeem's Awakening (MDFC). |
| `DecklistParser` | Tests over real Moxfield export text, including MDFC `//` names, set codes, and the commander section. |
| Ports | Mox against the behaviours. **No test touches the network.** |
| Contexts | `Deckex.DataCase` + ExMachina factories. |
| LiveViews | `Phoenix.LiveViewTest`. |
| **Regression** | A **reference deck** — a real 100-card list committed as a fixture, with its expected metrics locked in. If a refactor breaks the colour-source calculation, this test fails loudly. |

## 11. Quality gate

```
mix lint      # format --check-formatted, deps.unlock --check-unused,
              # credo --strict, sobelow --config, dialyzer
mix precommit # compile --warnings-as-errors, deps.unlock --unused, format, test
```

Plus `.check.exs` for `ex_check`, `.credo.exs` (strict), `excoveralls` for
coverage, and a GitHub Actions workflow running the gate.

## 12. Repository documentation

| File | Purpose |
|---|---|
| `AGENTS.md` | Operational contract — the project-specific layer on top of the playbook. Wins on conflict. |
| `CLAUDE.md` | Points at `AGENTS.md`. |
| `DESIGN.md` | Design system with machine-readable token frontmatter. |
| `docs/playbook/` | The architecture playbook, copied from beatgrid. |
| `README.md` | pt-BR, canonical. |

---

## 13. Implementation milestones

Ordered so that each milestone is independently verifiable and the risky,
uncertain work happens early.

1. **Scaffold + quality gate + docs.** Phoenix app, Postgres, `mix lint` green
   on an empty project, playbook and design docs in place.
2. **Cards + Scryfall port.** Schema, mapper (including DFC handling),
   batched/throttled enrichment, fixtures.
3. **Roles engine.** Rules first, tested against the curated fixture set; then
   the AI residue path behind the port.
4. **Decks + Moxfield port + paste.** Parser, import pipeline, workers, error
   degradation to paste.
5. **Analysis core.** The four lenses and the findings catalogue, pure and fully
   unit-tested, including the reference-deck regression.
6. **Consults.** Briefing builder, per-lens output schemas, `AI.Client` port,
   consult worker and history.
7. **UI.** Design tokens and core components first, then Mesa → Deck → Lente →
   Consultas → Ajustes.

---

## 14. Decision log

| Decision | Rationale |
|---|---|
| Commander only | Sharp baselines beat hedged ones. Every number means something specific. |
| Moxfield URL sync, honest UA, paste fallback | Owner's explicit choice, made with the ToS situation stated. Implemented without evasion; the identifiable UA is the path to sanctioned access. |
| Hybrid rule/AI classification | Rules are free and instant for the obvious majority; AI covers the long tail. Cache is global, so cost approaches zero over time. |
| Oracle-level card rows | Printing is irrelevant to deck shape. Simpler keys, smaller catalogue. |
| Pure `Analysis` core | Fast, trivially testable, no stale-cache class of bugs. |
| Reports computed, never cached | Same reason. Consults freeze a snapshot for reproducibility, which is a different thing. |
| AI runs in-app with WebSearch | Owner's choice. The briefing is stored anyway, so the copy-to-terminal path costs nothing extra and remains available. |
| Baselines editable | They are heuristics. Making them configurable is honest about that and lets the owner tune to their playgroup. |
| Suggestions as a table, not prose | The answer is a list of decisions; a table lets each one carry its reason, the finding it addresses, its price, and a button. Prose cannot be clicked. |
| Prices from Scryfall, never from the model | Verified on 2026-08-13: `fable` quoted "~US$16", "~US$5", "~US$31" unprompted. The briefing now forbids stating prices, and the table sources them from the catalogue regardless. |
| `opus` as the default model | See the comparison below. Selectable per consult, so a cheaper model is one dropdown away. |

### Model comparison — 2026-08-13

One identical briefing (lens `:full`, Iroh das Lontra, 101 cards) sent to three
models. Criteria: colour-identity legality, grounding in the actual decklist,
specificity of the reasoning, and honesty about what it did not know.

| Model | Time | Cuts/adds | What it did |
|---|---|---|---|
| `fable` | 156s | 3/3 | Correct diagnosis, all suggestions legal. **Invented prices** in every reason. Cut Anger, which is defensible but thin. |
| `sonnet` | 228s | 4/4 | Correct diagnosis, sharpest single observation (Arid Mesa only fetches Mountain in this list). Suggested **Forest twice as two rows**, which reads as a duplicate. |
| `opus` | 250s | 5/5 | Paired every cut with the add that replaces it via `replaces`. The only one that read the commander's text and reasoned from it — Lessons are the engine because Iroh flashbacks them, so they stay. Gave budget alternatives, flagged that Chain Reaction kills your own board, and said plainly that it could not verify prices. Also noted `graveyard_hate` at 0 as out of scope but relevant. |

All three agreed on the diagnosis the engine had already measured — G starved at
23 sources against a target of 25, and a single board wipe. That agreement is
the useful result: the lenses are pointing at something real.

Two defects in deckex surfaced from reading the three answers side by side, and
both are fixed: the briefing now forbids price claims, and `add_card/3` refuses
a second copy of a singleton card so a repeated suggestion cannot build an
illegal decklist one click at a time.
| Commander Brackets, no power level | Brackets are countable rules (Game Changers, mass land denial, extra turns, early combos); a 1–10 score is a card-ranking algorithm, which §1 says we do not build. See `2026-08-14-brackets-design.md`. |
| The engine reports a bracket FLOOR | Two of the five criteria need card-pool knowledge. The engine counts what it can and prints the rest as questions for the `:bracket` lens. |
| Card facts fetched, never hardcoded | `game_changer`, legality and price all arrive on the Scryfall card object. A list of card names in this repo is wrong within months of the Panel's next revision. |
| The model is told not to guess at legality | Verified 2026-08-14. A decline leaves no row for the audit to check, so the prompt prevents the class at the source. |
