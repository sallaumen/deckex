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
- **Analysis is pure.** `Deckex.Analysis` has no Repo, no HTTP, no process
  state. Reports are computed on demand, never cached.
- **Classification records its provenance.** Every `card_role` carries `source`
  (`:rule` / `:ai` / `:manual`) and `evidence`. A `:manual` role is never
  overwritten.

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

```bash
docker compose up -d
mix setup
mix phx.server
```

Note: after changing an already-applied migration, the test database keeps the
old schema (same timestamp = considered applied). Drop it:
`MIX_ENV=test mix ecto.drop`.
