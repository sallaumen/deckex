# Plano 8 — Dossiê estratégico + auto-crítica Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A scout consult writes a strategic dossier per deck; every briefing injects it; every answer opens with the model's own reading (`leitura`), instructed to disagree with the dossier out loud.

**Architecture:** The scout is a new lens (`:scout`) on the existing consult machinery — frozen briefing, worker, states, history, PubSub all reused. Its success path additionally writes four prose fields to new columns on `decks`. `Briefing.build/4` stays pure: the caller passes the dossier in via opts. `Schemas.for_lens/1` finally differs per lens: `:scout` gets the dossier schema, everyone else gains a required `leitura`.

**Tech Stack:** Elixir 1.19 / Phoenix 1.8 / LiveView 1.2 / Ecto 3.13 / Oban / Mox. Spec: `docs/superpowers/specs/2026-08-14-meta-prompt-dossie-design.md`.

## Global Constraints

- **Language rule (hard):** code, `@doc`, commit messages in English; user-facing text pt-BR; card names never translated.
- **Errors are data:** `{:ok, _}` / `{:error, %Deckex.Error{}}`; raise only on contract violations.
- **Triad:** mutations in `Deckex.Decks` / `Deckex.Consults`; reads in `*Query`; edges never build Ecto queries.
- **No test touches the network** — Mox at the ports (`Deckex.AI.Mock`, `Deckex.Scryfall.Mock`).
- **Gate before every commit:** chain `mix format --check-formatted && mix test && git commit …` with `&&` so a red gate blocks the commit. Run `mix lint` at least at the end of the plan (Task 8).
- **Card writes take locks in `oracle_id` order** (AGENTS.md law) — this plan adds no card writes, do not add any.
- Seed test catalogues through `Deckex.CatalogueFixture`, once per test, in a single call — never a hand-rolled card insert.
- Dev server: port 4005, already running; Postgres on host port 5435.

---

### Task 1: Dossier columns and Deck schema fields

**Files:**
- Create: `priv/repo/migrations/20260814120000_add_dossier_to_decks.exs`
- Modify: `lib/deckex/decks/deck.ex` (fields list ~line 13, schema block ~lines 20–31)
- Test: `test/deckex/decks/deck_test.exs`

**Interfaces:**
- Consumes: nothing new.
- Produces: `%Deck{}` gains `dossier :: map | nil`, `dossier_source :: :scout | :manual | nil`, `dossier_stale :: boolean` (default `false`), `dossier_updated_at :: DateTime.t() | nil`. `Deck.changeset/2` casts all four. Later tasks rely on these exact field names.

- [ ] **Step 1: Write the failing test**

Append inside the existing `describe`-less body of `test/deckex/decks/deck_test.exs` (before the final `end`):

```elixir
  describe "dossier fields" do
    test "a new deck has no dossier and is not stale" do
      deck = insert(:deck)

      assert deck.dossier == nil
      assert deck.dossier_source == nil
      assert deck.dossier_stale == false
      assert deck.dossier_updated_at == nil
    end

    test "changeset accepts the dossier fields" do
      dossier = %{
        "plano" => "Spellslinger Temur.",
        "sinergias" => "Iroh dá flashback às Lessons.",
        "linhas_de_vitoria" => "Storm Kiln Artist + magias baratas.",
        "fraquezas" => "Depende inteiramente do cemitério."
      }

      deck =
        :deck
        |> insert()
        |> Deck.changeset(%{
          dossier: dossier,
          dossier_source: :scout,
          dossier_stale: false,
          dossier_updated_at: DateTime.utc_now(:second)
        })
        |> Repo.update!()

      assert deck.dossier["plano"] == "Spellslinger Temur."
      assert deck.dossier_source == :scout
    end
  end
```

Add `alias Deckex.Decks.Deck` at the top of the test file if not already present (it is — check first).

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/deckex/decks/deck_test.exs`
Expected: FAIL — `dossier` is not a field of `%Deck{}` (KeyError) or cast error.

- [ ] **Step 3: Write the migration**

```elixir
defmodule Deckex.Repo.Migrations.AddDossierToDecks do
  use Ecto.Migration

  def change do
    alter table(:decks) do
      add :dossier, :map
      add :dossier_source, :string
      add :dossier_stale, :boolean, default: false, null: false
      add :dossier_updated_at, :utc_datetime
    end
  end
end
```

- [ ] **Step 4: Add the schema fields**

In `lib/deckex/decks/deck.ex`, extend `@fields` with `dossier dossier_source dossier_stale dossier_updated_at` (keep the `~w(...)a` sigil style), and add to the schema block:

```elixir
    field :dossier, :map
    field :dossier_source, Ecto.Enum, values: [:scout, :manual]
    field :dossier_stale, :boolean, default: false
    field :dossier_updated_at, :utc_datetime
```

- [ ] **Step 5: Migrate both envs and run the test**

Run: `mix ecto.migrate && MIX_ENV=test mix ecto.migrate && mix test test/deckex/decks/deck_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
mix format --check-formatted && mix test && git add -A && git commit -m "feat: add dossier columns to decks"
```

---

### Task 2: `Decks.put_dossier/2`, `Decks.edit_dossier/2`, staleness triggers

**Files:**
- Modify: `lib/deckex/decks.ex` (new functions after `remove_card/2` ~line 157; touch `add_card/3` ~line 110 and `remove_card/2` ~line 147)
- Test: `test/deckex/deck_editing_test.exs`

**Interfaces:**
- Consumes: Task 1's fields.
- Produces:
  - `Decks.put_dossier(%Deck{}, map) :: {:ok, Deck.t()}` — writes the scout's answer: sets `dossier`, `dossier_source: :scout`, `dossier_stale: false`, `dossier_updated_at: now`. No expected failure path (fields are built by us), but the tagged shape is kept for uniformity.
  - `Decks.edit_dossier(%Deck{}, %{String.t() => String.t()}) :: {:ok, Deck.t()}` — the owner's edit: same fields but `dossier_source: :manual`. The edit asserts current truth, so it also clears `dossier_stale`.
  - `add_card/3` and `remove_card/2` flip `dossier_stale: true` — only when a dossier exists.

- [ ] **Step 1: Write the failing tests**

Append a new `describe` block to `test/deckex/deck_editing_test.exs`:

```elixir
  describe "the dossier" do
    @dossier %{
      "plano" => "Spellslinger.",
      "sinergias" => "Flashback nas Lessons.",
      "linhas_de_vitoria" => "Tesouros do Storm Kiln.",
      "fraquezas" => "Cemitério é tudo."
    }

    test "put_dossier/2 stores the scout's reading and stamps it" do
      deck = deck()

      assert {:ok, updated} = Decks.put_dossier(deck, @dossier)

      assert updated.dossier["plano"] == "Spellslinger."
      assert updated.dossier_source == :scout
      assert updated.dossier_stale == false
      assert updated.dossier_updated_at != nil
    end

    test "edit_dossier/2 marks the text as the owner's and clears staleness" do
      {:ok, deck} = deck() |> Decks.put_dossier(@dossier)
      # add_card returns the DeckCard, not the deck — do not rebind `deck`.
      {:ok, _card} = Decks.add_card(deck, "Counterspell")
      {:ok, stale} = Decks.fetch_deck(deck.id)
      assert stale.dossier_stale

      assert {:ok, edited} = Decks.edit_dossier(stale, %{@dossier | "plano" => "Meu plano."})

      assert edited.dossier["plano"] == "Meu plano."
      assert edited.dossier_source == :manual
      assert edited.dossier_stale == false
    end

    test "adding a card marks an existing dossier stale" do
      {:ok, deck} = deck() |> Decks.put_dossier(@dossier)

      {:ok, _card} = Decks.add_card(deck, "Counterspell")

      {:ok, fresh} = Decks.fetch_deck(deck.id)
      assert fresh.dossier_stale
    end

    test "removing a card marks an existing dossier stale" do
      {:ok, deck} = deck() |> Decks.put_dossier(@dossier)

      {:ok, :removed} = Decks.remove_card(deck, "Sol Ring")

      {:ok, fresh} = Decks.fetch_deck(deck.id)
      assert fresh.dossier_stale
    end

    test "editing a deck with no dossier does not invent a stale flag" do
      deck = deck()

      {:ok, _card} = Decks.add_card(deck, "Counterspell")

      {:ok, fresh} = Decks.fetch_deck(deck.id)
      refute fresh.dossier_stale
    end
  end
```

Note: `deck/0` and `Decks.add_card(deck, "Counterspell")` already exist in this file — the setup seeds `sol_ring forest counterspell`. `%{@dossier | ...}` works because all keys exist. `add_card` on a singleton refuses a second copy, so each test adds Counterspell at most once.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/deckex/deck_editing_test.exs`
Expected: FAIL — `Decks.put_dossier/2 is undefined`.

- [ ] **Step 3: Implement**

In `lib/deckex/decks.ex`, after `remove_card/2`:

```elixir
  @doc """
  Stores the scout's reading of the deck.

  Cannot fail for an expected reason — the map comes from a schema-validated
  model answer — so the tagged shape is uniformity, not an error channel.
  """
  @spec put_dossier(Deck.t(), map()) :: {:ok, Deck.t()}
  def put_dossier(%Deck{} = deck, %{} = dossier) do
    {:ok, write_dossier!(deck, dossier, :scout)}
  end

  @doc """
  The owner's edit of the dossier.

  Also clears staleness: an edit asserts current truth, which is exactly what
  the stale flag says is missing.
  """
  @spec edit_dossier(Deck.t(), map()) :: {:ok, Deck.t()}
  def edit_dossier(%Deck{} = deck, %{} = dossier) do
    {:ok, write_dossier!(deck, Map.take(dossier, dossier_fields()), :manual)}
  end

  @doc "The four prose fields a dossier carries, in display order."
  @spec dossier_fields() :: [String.t()]
  def dossier_fields, do: ["plano", "sinergias", "linhas_de_vitoria", "fraquezas"]

  defp write_dossier!(deck, dossier, source) do
    deck
    |> Deck.changeset(%{
      dossier: dossier,
      dossier_source: source,
      dossier_stale: false,
      dossier_updated_at: DateTime.utc_now(:second)
    })
    |> Repo.update!()
  end

  # An edit changes what the dossier describes. Flag it; never re-run anything
  # automatically — a consult costs money and minutes, so spending is always
  # the owner's click.
  defp mark_dossier_stale(%Deck{dossier: nil}), do: :ok

  defp mark_dossier_stale(%Deck{} = deck) do
    deck |> Deck.changeset(%{dossier_stale: true}) |> Repo.update!()

    :ok
  end
```

Wire the triggers. In `add_card/3`, after the singleton check succeeds and before returning:

```elixir
    with {:ok, card} <- resolve_one(name),
         :ok <- check_singleton(deck, card, board) do
      # Classify on the way in. A card added without roles is invisible to every
      # lens — the interaction count would not move when you add a counterspell,
      # which is precisely the feedback the button exists to give.
      {:ok, _roles} = Cards.classify_card(card)
      :ok = mark_dossier_stale(deck)

      {:ok, upsert_deck_card!(deck, card, board, quantity)}
    end
```

In `remove_card/2`, after `drop_one!(deck_card)`:

```elixir
      drop_one!(deck_card)
      :ok = mark_dossier_stale(deck)

      {:ok, :removed}
```

(Import needs nothing: `import_from_text/2` always inserts a **new** deck, whose dossier is NULL — the spec's third trigger is satisfied vacuously. There is no overwrite-in-place import path today.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/deckex/deck_editing_test.exs`
Expected: PASS, including the pre-existing tests.

- [ ] **Step 5: Commit**

```bash
mix format --check-formatted && mix test && git add -A && git commit -m "feat: dossier mutations and staleness triggers on deck edits"
```

---

### Task 3: The `:scout` lens and the response schemas

**Files:**
- Modify: `lib/deckex/consults/consult.ex` (`@lenses`, ~line 16)
- Modify: `lib/deckex/consults/schemas.ex` (whole module body)
- Test: `test/deckex/consults/schemas_test.exs` (create if absent; check first — schema assertions may live in `consults_test.exs` today)

**Interfaces:**
- Consumes: nothing new.
- Produces: `:scout` is a valid `Consult` lens. `Schemas.for_lens(:scout)` returns an object schema requiring exactly `["plano", "sinergias", "linhas_de_vitoria", "fraquezas"]`. `Schemas.for_lens(any_other_lens)` requires `["leitura", "diagnosis", "cuts", "adds"]`. `Consults.lens_labels/0` is deliberately **unchanged** — the scout has its own button, not a dropdown entry.

- [ ] **Step 1: Write the failing tests**

Create `test/deckex/consults/schemas_test.exs`:

```elixir
defmodule Deckex.Consults.SchemasTest do
  use ExUnit.Case, async: true

  alias Deckex.Consults.Schemas

  test "the scout writes the four dossier fields and nothing else" do
    schema = Schemas.for_lens(:scout)

    assert schema["required"] == ["plano", "sinergias", "linhas_de_vitoria", "fraquezas"]
    refute Map.has_key?(schema["properties"], "cuts")
    refute Map.has_key?(schema["properties"], "adds")
  end

  # The reading comes before the prescription. JSON schemas cannot order
  # generation — the briefing's rules do — but the requirement lives here.
  test "every consulting lens must open with its own reading" do
    for lens <- [:full, :speed_curve, :mana_ramp, :interaction, :consistency, :matchup, :budget, :upgrade, :finding] do
      schema = Schemas.for_lens(lens)

      assert "leitura" in schema["required"], "#{lens} lacks leitura"
      assert schema["required"] == ["leitura", "diagnosis", "cuts", "adds"]
      assert schema["properties"]["leitura"]["description"] =~ "discordar"
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/deckex/consults/schemas_test.exs`
Expected: FAIL — `:scout` returns the generic schema; `leitura` absent.

- [ ] **Step 3: Implement**

In `lib/deckex/consults/consult.ex`, add `:scout` to `@lenses` (append to the list).

Rewrite `lib/deckex/consults/schemas.ex`:

```elixir
defmodule Deckex.Consults.Schemas do
  @moduledoc """
  The JSON schema a consult's answer must satisfy.

  Two shapes now. The scout writes the strategic dossier — four prose fields,
  no cuts, no adds: a scout that suggests cards has become a consultant, and
  the consultant already exists. Every other lens shares the diagnosis/cuts/
  adds shape, opened by a required `leitura`: the model's own reading of the
  deck, confronted with the dossier when one was injected. The mandated
  disagreement makes `leitura` double as a stale-dossier detector.
  """

  @spec for_lens(atom()) :: map()
  def for_lens(:scout) do
    %{
      "type" => "object",
      "properties" => %{
        "plano" => %{
          "type" => "string",
          "description" =>
            "One paragraph, pt-BR: what this deck is trying to do and how the commander enables it. Card names untranslated."
        },
        "sinergias" => %{
          "type" => "string",
          "description" =>
            "One paragraph, pt-BR: the specific interactions that give this deck its identity, naming the cards involved."
        },
        "linhas_de_vitoria" => %{
          "type" => "string",
          "description" => "One paragraph, pt-BR: how this deck actually closes a game."
        },
        "fraquezas" => %{
          "type" => "string",
          "description" =>
            "One paragraph, pt-BR: only weaknesses the measurements above do NOT show — e.g. a dependency, a single point of failure the numbers cannot see."
        }
      },
      "required" => ["plano", "sinergias", "linhas_de_vitoria", "fraquezas"]
    }
  end

  def for_lens(_lens) do
    %{
      "type" => "object",
      "properties" => %{
        "leitura" => %{
          "type" => "string",
          "description" =>
            "2-4 frases, pt-BR: sua leitura do plano deste deck, confrontada com o dossiê acima (se houver). Se você discordar do dossiê, diga onde e por quê."
        },
        "diagnosis" => %{
          "type" => "string",
          "description" => "One paragraph in pt-BR on what is actually wrong."
        },
        "cuts" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "card" => %{"type" => "string", "description" => "Exact card name, untranslated."},
              "reason" => %{"type" => "string", "description" => "One sentence, pt-BR."},
              "addresses" => %{
                "type" => "string",
                "description" => "The finding code this cut serves, e.g. mana.color_starved."
              }
            },
            "required" => ["card", "reason"]
          }
        },
        "adds" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "card" => %{"type" => "string", "description" => "Exact card name, untranslated."},
              "reason" => %{"type" => "string", "description" => "One sentence, pt-BR."},
              "addresses" => %{
                "type" => "string",
                "description" =>
                  "The finding code this add serves, e.g. interaction.board_wipes_low."
              },
              "replaces" => %{
                "type" => "string",
                "description" => "The cut this add pairs with, if any."
              }
            },
            "required" => ["card", "reason"]
          }
        },
        "notes" => %{
          "type" => "string",
          "description" => "Anything the lists could not carry, pt-BR."
        }
      },
      "required" => ["leitura", "diagnosis", "cuts", "adds"]
    }
  end
end
```

- [ ] **Step 4: Run tests — the new file AND the consults suite**

Run: `mix test test/deckex/consults/schemas_test.exs test/deckex/consults_test.exs`
Expected: `schemas_test` PASSES. `consults_test` has one FAILURE: `"stores the model's answer and marks the consult done"` asserts `schema["required"] == ["diagnosis", "cuts", "adds"]`. Update that assertion to `["leitura", "diagnosis", "cuts", "adds"]`. Re-run; all PASS.

- [ ] **Step 5: Commit**

```bash
mix format --check-formatted && mix test && git add -A && git commit -m "feat: scout lens with dossier schema, leitura required everywhere else"
```

---

### Task 4: Briefing — dossier injection, scout task block, per-lens rules

**Files:**
- Modify: `lib/deckex/consults/briefing.ex`
- Create: `test/deckex/consults/briefing_test.exs` — no direct briefing test exists today (the briefing is only exercised through `Consults.request/3`); this file is DB-free on purpose, like the analysis tests

**Interfaces:**
- Consumes: nothing from earlier tasks (pure module; the dossier arrives as data).
- Produces: `Briefing.build(report, snapshot, lens, opts)` honours two new opts: `opts[:dossier] :: map | nil` and `opts[:dossier_stale] :: boolean`. With a dossier, a `## Leitura estratégica (dossiê do deck)` block lands **after the findings, before the decklist**. `:scout` gets its own task block and a minimal rules block. Task 5 passes the opts.

- [ ] **Step 1: Write the failing tests**

Create `test/deckex/consults/briefing_test.exs`. The module is pure — no
`DataCase`, no Repo — built on `Deckex.AnalysisFixture.entry/1` and
`snapshot/2`, which construct structs directly:

```elixir
defmodule Deckex.Consults.BriefingTest do
  use ExUnit.Case, async: true

  alias Deckex.Analysis
  alias Deckex.AnalysisFixture
  alias Deckex.Consults.Briefing

  # One snapshot shared by report and build — a briefing whose report was
  # measured from a different snapshot asserts nothing.
  defp snapshot do
    AnalysisFixture.snapshot([AnalysisFixture.entry(name: "Sol Ring")])
  end

  defp build(lens, opts) do
    snap = snapshot()

    Briefing.build(Analysis.report(snap), snap, lens, opts)
  end

  describe "the dossier in the briefing" do
    @dossier %{
      "plano" => "Spellslinger Temur com Iroh.",
      "sinergias" => "Iroh dá flashback às Lessons.",
      "linhas_de_vitoria" => "Storm Kiln Artist.",
      "fraquezas" => "Cemitério é tudo."
    }

    test "a dossier lands between the findings and the decklist" do
      briefing = build(:full, dossier: @dossier)

      assert briefing =~ "## Leitura estratégica (dossiê do deck)"
      assert briefing =~ "Iroh dá flashback às Lessons."

      dossier_at = position(briefing, "## Leitura estratégica")
      assert dossier_at > position(briefing, "## Findings")
      assert dossier_at < position(briefing, "## The full decklist")
    end

    test "no dossier, no block — everything else intact" do
      briefing = build(:full, [])

      refute briefing =~ "Leitura estratégica"
      assert briefing =~ "## Measurements"
    end

    test "a stale dossier says so" do
      briefing = build(:full, dossier: @dossier, dossier_stale: true)

      assert briefing =~ "the deck has changed since this dossier was written"
    end

    test "with a dossier, the rules demand leitura first and out-loud disagreement" do
      briefing = build(:full, dossier: @dossier)

      assert briefing =~ "Write `leitura` first"
    end

    test "the scout is told to read, not to fix" do
      briefing = build(:scout, [])

      assert briefing =~ "Do not propose any change"
      assert briefing =~ "scout, not the consultant"
      refute briefing =~ "**cut**"
    end

    test "the scout never receives a dossier, even when one is passed" do
      briefing = build(:scout, dossier: @dossier)

      refute briefing =~ "Leitura estratégica"
    end

    defp position(string, marker) do
      {at, _len} = :binary.match(string, marker)
      at
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/deckex/consults/`
Expected: new tests FAIL (no dossier block, scout gets the generic task block).

- [ ] **Step 3: Implement**

In `lib/deckex/consults/briefing.ex`:

1. In `build/4`, insert `#{dossier_block(lens, opts)}` between `#{findings_block(findings)}` and `#{decklist_block(snapshot)}`, and replace the literal rules trailer (everything from `Rules you must respect:` through the final pt-BR line) with `#{rules_block(lens, report, opts)}`.

2. Add the blocks:

```elixir
  # The part of the prompt no template can write. The scout itself never sees
  # one — it must read the deck fresh, not be anchored by its own predecessor.
  defp dossier_block(:scout, _opts), do: ""
  defp dossier_block(_lens, opts), do: dossier_lines(opts[:dossier], opts[:dossier_stale])

  defp dossier_lines(nil, _stale), do: ""

  defp dossier_lines(dossier, stale) do
    stale_line =
      if stale,
        do: "\nCaution: the deck has changed since this dossier was written — weigh it accordingly.",
        else: ""

    """
    ## Leitura estratégica (dossiê do deck)

    - Plano: #{dossier["plano"]}
    - Sinergias: #{dossier["sinergias"]}
    - Linhas de vitória: #{dossier["linhas_de_vitoria"]}
    - Fraquezas que os números não veem: #{dossier["fraquezas"]}
    #{stale_line}
    This dossier is the owner's current understanding of the deck. Trust it as
    context — and when the list itself says otherwise, contradict it explicitly
    in `leitura`.
    """
  end
```

3. Add the scout task block **above** the catch-all `task_block(_lens, _opts)` clause (clause order matters):

```elixir
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
```

4. Add the rules block (the non-scout body is today's rules verbatim, plus the `leitura` line):

```elixir
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
      upgrades.#{budget_line(opts[:budget_usd])}
    - **Never state a price.** The app shows the current Scryfall price next to
      every suggestion, so a number from you can only disagree with it. Say
      "cheap" or "expensive" if it matters to the argument; leave the figure out.
    - Search the web for current Commander staples where it helps. The
      measurements above are facts about this deck; the card pool is what you
      know and can look up.

    Answer in **Portuguese (pt-BR)**, but never translate a card name.
    """
  end

  defp dossier_clause(nil), do: ""
  defp dossier_clause(_dossier), do: ", confronted with the dossier above"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/deckex/consults/`
Expected: PASS. If a pre-existing briefing test asserted the exact rules text, update it to match the extracted block — content is unchanged for non-scout lenses except the new `leitura` line.

- [ ] **Step 5: Commit**

```bash
mix format --check-formatted && mix test && git add -A && git commit -m "feat: inject the dossier into briefings, give the scout its own task"
```

---

### Task 5: Wire the pipeline — request injects, scout success writes

**Files:**
- Modify: `lib/deckex/consults.ex` (`start/4` ~line 85, `briefing_opts/1` ~line 100, `succeed/3` ~line 148)
- Test: `test/deckex/consults_test.exs`

**Interfaces:**
- Consumes: `Decks.put_dossier/2` (Task 2), `Schemas.for_lens(:scout)` (Task 3), `Briefing.build` opts (Task 4).
- Produces: `Consults.request(deck, :scout)` runs end to end; a finished scout has written `deck.dossier`. Non-scout requests carry the deck's dossier into the frozen briefing. The LiveView (Task 6) only ever calls `Consults.request/3`.

- [ ] **Step 1: Write the failing tests**

Append to `test/deckex/consults_test.exs`:

```elixir
  describe "the scout" do
    @scout_answer {:ok,
                   %{
                     "plano" => "Spellslinger Temur.",
                     "sinergias" => "Sol Ring acelera tudo.",
                     "linhas_de_vitoria" => "Valor incremental.",
                     "fraquezas" => "Sem win condition clara."
                   }}

    test "a finished scout writes the dossier onto the deck" do
      deck = deck()
      {:ok, consult} = Consults.request(deck, :scout)

      expect(Deckex.AI.Mock, :complete, fn prompt, schema, _opts ->
        assert prompt =~ "scout, not the consultant"
        assert schema["required"] == ["plano", "sinergias", "linhas_de_vitoria", "fraquezas"]

        @scout_answer
      end)

      assert {:ok, done} = Consults.run(consult)
      assert done.status == :done

      {:ok, fresh} = Decks.fetch_deck(deck.id)
      assert fresh.dossier["plano"] == "Spellslinger Temur."
      assert fresh.dossier_source == :scout
      assert fresh.dossier_stale == false
    end

    test "a failed scout leaves the deck untouched" do
      deck = deck()
      {:ok, consult} = Consults.request(deck, :scout)

      expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts ->
        {:error, Error.new(:ai_timeout, "estourou")}
      end)

      assert {:error, %Error{}} = Consults.run(consult)

      {:ok, fresh} = Decks.fetch_deck(deck.id)
      assert fresh.dossier == nil
    end

    test "a consult on a deck with a dossier carries it in the briefing" do
      deck = deck()
      {:ok, deck} = Decks.put_dossier(deck, @scout_answer |> elem(1))

      {:ok, consult} = Consults.request(deck, :full)

      assert consult.briefing =~ "Leitura estratégica"
      assert consult.briefing =~ "Sol Ring acelera tudo."
    end

    test "a consult on a deck without a dossier still works" do
      {:ok, consult} = Consults.request(deck(), :full)

      refute consult.briefing =~ "Leitura estratégica"
    end
  end
```

(`deck/0`, `Error`, `import Mox` and `stub_catalogue/0` already exist in this file. The scout tests do not need `stub_catalogue` — a dossier answer has no `cuts`/`adds`, so `Suggestions.names/1` returns `[]` and `Cards.resolve_names([])` short-circuits without touching the port.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/deckex/consults_test.exs`
Expected: FAIL — briefing lacks the dossier, `run/1` does not write the deck.

- [ ] **Step 3: Implement**

In `lib/deckex/consults.ex`:

1. `start/4` — the deck is in scope; extend `briefing_opts`:

```elixir
  defp start(deck, lens, models, opts) do
    snapshot = Decks.snapshot(deck)
    report = Analysis.report(snapshot, Settings.baselines())
    briefing = Briefing.build(report, snapshot, lens, briefing_opts(deck, opts))
    ...
```

```elixir
  defp briefing_opts(deck, opts) do
    opts
    |> Keyword.put_new(:budget_usd, Settings.budget_usd())
    |> Keyword.put(:dossier, deck.dossier)
    |> Keyword.put(:dossier_stale, deck.dossier_stale)
  end
```

(`Briefing.build` already ignores the dossier opts for `:scout` — Task 4.)

2. `succeed/3` — write the dossier before cataloguing:

```elixir
  defp succeed(consult, response, started) do
    done =
      update!(consult, %{
        status: :done,
        response: response,
        duration_ms: System.monotonic_time(:millisecond) - started,
        error: nil
      })

    done |> deliver_dossier() |> catalogue()
  end

  # A scout's answer IS the dossier. Writing it here — in the background job
  # that already ran — is what lets the deck page only ever read.
  defp deliver_dossier(%Consult{lens: :scout} = consult) do
    {:ok, deck} = Decks.fetch_deck(consult.deck_id)
    {:ok, _deck} = Decks.put_dossier(deck, consult.response)

    consult
  end

  defp deliver_dossier(%Consult{} = consult), do: consult
```

Check that `Decks.fetch_deck/1` exists and returns `{:ok, %Deck{}}` (it does — `DeckLive.mount/3` uses it).

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/deckex/consults_test.exs && mix test`
Expected: PASS, full suite green.

- [ ] **Step 5: Commit**

```bash
mix format --check-formatted && mix test && git add -A && git commit -m "feat: scout consults write the dossier; every briefing carries it"
```

---

### Task 6: DeckLive — dossier card, events, and honest refreshes

**Files:**
- Modify: `lib/deckex_web/live/deck_live.ex` (mount ~line 23, `assign_deck` ~line 33, `handle_info` ~line 80, `apply_edit` ~line 97, `refresh_consults` ~line 105; render: wide column, directly **above** the `<section :if={@consults != []}>` at ~line 339)
- Test: `test/deckex_web/live/deck_dossier_test.exs` (create)

**Interfaces:**
- Consumes: `Consults.request(deck, :scout)`, `Decks.edit_dossier/2`, `Decks.dossier_fields/0`, `Decks.fetch_deck/1`, deck dossier fields.
- Produces: events `"gerar-dossie"` (no params) and `"salvar-dossie"` (`%{"dossier" => %{"plano" => _, ...}}`). Assign `@scout_running?`. Used only inside this LiveView.

- [ ] **Step 1: Fix the refresh plumbing first (no new UI yet)**

Three defects this feature would otherwise trip over, all in this file:

1. **Duplicate PubSub subscriptions.** `assign_deck/2` subscribes, and `apply_edit/3` calls `assign_deck` — every deck edit re-subscribes, and Phoenix PubSub delivers once per subscription. Move the subscribe into `mount/3`:

```elixir
  def mount(%{"id" => id}, _session, socket) do
    case Decks.fetch_deck(id) do
      {:ok, deck} ->
        if connected?(socket), do: Events.subscribe_consults(deck.id)

        {:ok, assign_deck(socket, deck)}
      ...
```

and delete the `if connected?...subscribe` line from `assign_deck/2`.

2. **Stale deck struct after edits.** `apply_edit` success re-assigns the *old* struct; it now carries a wrong `dossier_stale`. Re-fetch:

```elixir
  defp apply_edit(socket, {:ok, _result}, message) do
    {:ok, fresh} = Decks.fetch_deck(socket.assigns.deck.id)

    socket |> assign_deck(fresh) |> put_flash(:info, message)
  end
```

3. **A finished scout must reach the page.** `handle_info` only refreshed consults; the dossier lives on the deck:

```elixir
  def handle_info({:consult_updated, _id}, socket) do
    {:ok, fresh} = Decks.fetch_deck(socket.assigns.deck.id)

    {:noreply, assign_deck(socket, fresh)}
  end
```

In `refresh_consults/1`, add to the `assign`:

```elixir
      scout_running?: Enum.any?(consults, &(&1.lens == :scout and &1.status in [:pending, :running]))
```

- [ ] **Step 2: Write the failing tests**

Create `test/deckex_web/live/deck_dossier_test.exs`:

```elixir
defmodule DeckexWeb.DeckDossierTest do
  use DeckexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Deckex.CatalogueFixture
  alias Deckex.Consults
  alias Deckex.Decks

  @dossier %{
    "plano" => "Spellslinger Temur.",
    "sinergias" => "Iroh dá flashback às Lessons.",
    "linhas_de_vitoria" => "Storm Kiln Artist.",
    "fraquezas" => "Cemitério é tudo."
  }

  setup do
    CatalogueFixture.seed!(~w(sol_ring forest))

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n4 Forest", %{name: "Deck do Dossiê", source: :paste})

    %{deck: deck}
  end

  test "without a dossier, the card offers to generate one", %{conn: conn, deck: deck} do
    {:ok, live, html} = live(conn, ~p"/decks/#{deck.id}")

    assert html =~ "Dossiê"
    assert html =~ "Gerar dossiê"

    live |> element("button[phx-click='gerar-dossie']") |> render_click()

    assert Enum.any?(Consults.list_for_deck(deck), &(&1.lens == :scout))
  end

  test "with a dossier, the four fields render with their source", %{conn: conn, deck: deck} do
    {:ok, _deck} = Decks.put_dossier(deck, @dossier)

    {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

    assert html =~ "Iroh dá flashback às Lessons."
    assert html =~ "escrito pelo scout"
    refute html =~ "desatualizado"
  end

  test "a stale dossier wears the badge", %{conn: conn, deck: deck} do
    {:ok, deck} = Decks.put_dossier(deck, @dossier)
    {:ok, _card} = Decks.add_card(deck, "Forest")

    {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

    assert html =~ "desatualizado"
  end

  test "editing the dossier makes it the owner's", %{conn: conn, deck: deck} do
    {:ok, _deck} = Decks.put_dossier(deck, @dossier)

    {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

    html =
      live
      |> form("#dossier-form", dossier: %{@dossier | "plano" => "Plano meu."})
      |> render_submit()

    assert html =~ "editado por você"

    {:ok, fresh} = Decks.fetch_deck(deck.id)
    assert fresh.dossier["plano"] == "Plano meu."
    assert fresh.dossier_source == :manual
  end

  test "re-running over a manual dossier asks first", %{conn: conn, deck: deck} do
    {:ok, deck} = Decks.put_dossier(deck, @dossier)
    {:ok, _deck} = Decks.edit_dossier(deck, @dossier)

    {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

    assert live
           |> element("button[phx-click='gerar-dossie'][data-confirm]")
           |> has_element?()
  end
end
```

Run: `mix test test/deckex_web/live/deck_dossier_test.exs`
Expected: FAIL — no dossier card exists.

- [ ] **Step 3: Implement the dossier card**

In the render, directly above `<section :if={@consults != []}>` (inside the wide column's `<div class="space-y-8">`):

```heex
          <section>
            <div class="mb-3 flex items-center gap-3">
              <h2 class="text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
                Dossiê
              </h2>
              <span
                :if={@deck.dossier && @deck.dossier_stale}
                class="font-mono text-micro text-sev-warning"
              >
                desatualizado — o deck mudou depois que ele foi escrito
              </span>
            </div>

            <div class="rounded-xl border border-hairline-soft bg-surface p-6">
              <div :if={is_nil(@deck.dossier) && !@scout_running?} class="text-center">
                <p class="text-body text-ink-secondary">
                  A leitura estratégica que os números não fazem: plano, sinergias,
                  linhas de vitória e fraquezas. Entra em toda consulta.
                </p>
                <div class="mt-4">
                  <.button type="button" phx-click="gerar-dossie" variant="primary">
                    Gerar dossiê
                  </.button>
                </div>
              </div>

              <p :if={@scout_running?} class="font-mono text-caption text-ink-faint">
                scout lendo o deck…
              </p>

              <div :if={@deck.dossier && !@scout_running?} class="space-y-4">
                <div :for={field <- Decks.dossier_fields()}>
                  <h3 class="mb-1 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
                    {dossier_label(field)}
                  </h3>
                  <p class="text-body text-ink-secondary">{@deck.dossier[field]}</p>
                </div>

                <div class="flex flex-wrap items-center justify-between gap-3 border-t border-hairline-soft pt-4">
                  <span class="font-mono text-micro text-ink-faint">
                    {dossier_source_label(@deck.dossier_source)}
                    · {Calendar.strftime(@deck.dossier_updated_at, "%d/%m %H:%M")}
                  </span>

                  <button
                    type="button"
                    phx-click="gerar-dossie"
                    data-confirm={
                      @deck.dossier_source == :manual &&
                        "Isso substitui a sua edição pelo texto do scout. Continuar?"
                    }
                    class="text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
                  >
                    Rerodar o scout
                  </button>
                </div>

                <details>
                  <summary class="cursor-pointer text-caption text-ink-faint hover:text-ink">
                    Editar dossiê
                  </summary>
                  <.form
                    for={%{}}
                    as={:dossier}
                    id="dossier-form"
                    phx-submit="salvar-dossie"
                    class="mt-3 space-y-3"
                  >
                    <div :for={field <- Decks.dossier_fields()}>
                      <label
                        for={"dossier-#{field}"}
                        class="mb-1 block text-label font-semibold uppercase tracking-[0.1em] text-ink-faint"
                      >
                        {dossier_label(field)}
                      </label>
                      <textarea
                        id={"dossier-#{field}"}
                        name={"dossier[#{field}]"}
                        rows="3"
                        class="w-full rounded-md border border-hairline-soft bg-inlay px-3 py-2 text-caption text-ink"
                      >{@deck.dossier[field]}</textarea>
                    </div>
                    <.button type="submit">Salvar</.button>
                  </.form>
                </details>
              </div>
            </div>
          </section>
```

Handlers and helpers (beside the other `handle_event` clauses and at the bottom with the other private helpers):

```elixir
  def handle_event("gerar-dossie", _params, socket) do
    {:noreply, start_consult(socket, :scout, [])}
  end

  def handle_event("salvar-dossie", %{"dossier" => params}, socket) do
    {:ok, _deck} = Decks.edit_dossier(socket.assigns.deck, params)
    {:ok, fresh} = Decks.fetch_deck(socket.assigns.deck.id)

    {:noreply, socket |> assign_deck(fresh) |> put_flash(:info, "Dossiê salvo.")}
  end
```

```elixir
  defp dossier_label("plano"), do: "Plano"
  defp dossier_label("sinergias"), do: "Sinergias"
  defp dossier_label("linhas_de_vitoria"), do: "Linhas de vitória"
  defp dossier_label("fraquezas"), do: "Fraquezas que os números não veem"

  defp dossier_source_label(:scout), do: "escrito pelo scout"
  defp dossier_source_label(:manual), do: "editado por você"
```

Watch the two standing UI laws: no HEEx attribute with a `\n`-carrying string literal (the formatter mangles it — use functions), and every Tailwind class must name a real token (`DesignTokensTest` will fail the build otherwise; the classes above only use existing tokens and `@builtins`).

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/deckex_web/live/deck_dossier_test.exs && mix test test/deckex_web/`
Expected: PASS, including the pre-existing LiveView suites.

- [ ] **Step 5: Commit**

```bash
mix format --check-formatted && mix test && git add -A && git commit -m "feat: the dossier card — generate, edit, stale badge, honest refreshes"
```

---

### Task 7: The consult card learns `leitura` and tolerates the scout

**Files:**
- Modify: `lib/deckex_web/live/deck_live.ex` (consult article, ~lines 364–370)
- Test: `test/deckex_web/live/deck_consult_test.exs`

**Interfaces:**
- Consumes: `consult.response["leitura"]` (Task 3's schema), scout consults in `@consults` (Task 5).
- Produces: rendering only.

- [ ] **Step 1: Write the failing tests**

Append to `test/deckex_web/live/deck_consult_test.exs` (reuse its existing setup and Mox pattern):

```elixir
  test "a consult's leitura renders above the diagnosis", %{conn: conn, deck: deck} do
    {:ok, consult} = Consults.request(deck, :full)

    stub(Deckex.Scryfall.Mock, :fetch_by_names, fn names ->
      {:ok, %{found: [], not_found: names}}
    end)

    expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts ->
      {:ok,
       %{
         "leitura" => "Leio um deck de spellslinger com fecho fraco.",
         "diagnosis" => "Falta fecho.",
         "cuts" => [],
         "adds" => []
       }}
    end)

    {:ok, _done} = Consults.run(consult)

    {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

    assert html =~ "Leio um deck de spellslinger com fecho fraco."
  end

  test "an old answer without leitura still renders", %{conn: conn, deck: deck} do
    {:ok, consult} = Consults.request(deck, :full)

    {:ok, _old} =
      consult
      |> Ecto.Changeset.change(%{
        status: :done,
        response: %{"diagnosis" => "Sem leitura, era outra época.", "cuts" => [], "adds" => []}
      })
      |> Deckex.Repo.update()

    {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

    assert html =~ "Sem leitura, era outra época."
  end

  test "a finished scout renders as a consult without crashing", %{conn: conn, deck: deck} do
    {:ok, consult} = Consults.request(deck, :scout)

    expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts ->
      {:ok,
       %{
         "plano" => "Ramp e cartas.",
         "sinergias" => "Sol Ring com tudo.",
         "linhas_de_vitoria" => "Valor.",
         "fraquezas" => "Nenhuma visível."
       }}
    end)

    {:ok, _done} = Consults.run(consult)

    {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

    assert html =~ "scout"
  end
```

Run: `mix test test/deckex_web/live/deck_consult_test.exs`
Expected: the `leitura` test FAILS (text absent); the scout test may fail on a nil `diagnosis` render — that is the second defect this task fixes.

- [ ] **Step 2: Implement**

In the consult article (current lines 366–367), guard the diagnosis and add `leitura` above it:

```heex
                <div :if={consult.response} class="space-y-3">
                  <p
                    :if={consult.response["leitura"]}
                    class="border-l-2 border-hairline-strong pl-3 text-caption italic text-ink-muted"
                  >
                    {consult.response["leitura"]}
                  </p>

                  <p :if={consult.response["diagnosis"]} class="text-caption text-ink">
                    {consult.response["diagnosis"]}
                  </p>
```

(`border-l-2` is structural Tailwind — add it to `DesignTokensTest`'s `@builtins` if the guard complains; check the test output before deciding.)

- [ ] **Step 3: Run tests to verify they pass**

Run: `mix test test/deckex_web/live/`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
mix format --check-formatted && mix test && git add -A && git commit -m "feat: render the model's leitura, tolerate scout answers in the list"
```

---

### Task 8: Real-deck regression, full gate, browser proof

**Files:**
- Modify: `test/deckex/analysis/real_deck_test.exs`
- No production code expected.

**Interfaces:** consumes everything; produces the proof.

- [ ] **Step 1: Write the regression test**

Append to `test/deckex/analysis/real_deck_test.exs` (it already imports the Iroh decklist and builds a report — reuse `import_and_measure/0` or its pieces as the file allows; the point is a real 100-card snapshot):

```elixir
  test "a briefing for the real deck carries the dossier between findings and decklist" do
    report = import_and_measure()

    dossier = %{
      "plano" => "Spellslinger Temur: Iroh recompra instants e sorceries.",
      "sinergias" => "Iroh dá flashback às Lessons não-Lesson por {1}.",
      "linhas_de_vitoria" => "Storm Kiln Artist e cópias.",
      "fraquezas" => "Um Bojuka Bog desliga metade do plano."
    }

    deck = Deckex.Repo.one!(Deckex.Decks.Deck)
    snapshot = Deckex.Decks.snapshot(deck)

    briefing = Deckex.Consults.Briefing.build(report, snapshot, :full, dossier: dossier)

    {dossier_at, _} = :binary.match(briefing, "## Leitura estratégica")
    {findings_at, _} = :binary.match(briefing, "## Findings")
    {decklist_at, _} = :binary.match(briefing, "## The full decklist")

    assert findings_at < dossier_at
    assert dossier_at < decklist_at
    assert briefing =~ "Bojuka Bog"
  end
```

Adapt the deck retrieval to what `import_and_measure/0` returns — if it only returns the report, fetch the deck it created (`Deckex.Repo.one!(Deckex.Decks.Deck)` works because the test creates exactly one).

- [ ] **Step 2: Run the file, then the world**

Run: `mix test test/deckex/analysis/real_deck_test.exs && mix test && mix lint`
Expected: all green — `format`, `credo --strict`, `sobelow`, `dialyzer` included.

- [ ] **Step 3: Verify in the browser (dev server on port 4005)**

Follow the preview verification workflow: open `/decks/<id>` for the Iroh deck, confirm the dossier card renders its empty state, click nothing that spends money without the owner. Read the console for errors. Screenshot the card.

- [ ] **Step 4: Commit**

```bash
mix format --check-formatted && mix test && git add -A && git commit -m "test: real-deck briefing regression with an injected dossier"
```

---

## Self-review notes (already applied)

- **Spec coverage:** §2→Task 1–2; §3→Tasks 3, 5; §4→Task 4; §5→Tasks 3, 7; §6→Task 2 (import trigger documented as vacuous — new decks start with a NULL dossier; no overwrite-import exists); §7→Task 6; §8→Tasks 2, 5; §9→every task + Task 8.
- **Type consistency:** dossier maps are **string-keyed everywhere** (JSONB round-trip); `dossier_fields/0` returns strings; `Ecto.Enum` handles the `:scout`/`:manual` atoms at the column boundary.
- **Known deviations from spec, both deliberate:** the leitura-first ordering is enforced by the briefing rules (JSON object keys carry no order — the spec itself concedes this); the stale-while-running race is accepted and documented in the spec.
