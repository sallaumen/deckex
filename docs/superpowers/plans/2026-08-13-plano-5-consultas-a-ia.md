# Plano 5 — Consultas à IA

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn a finding into a recommendation — hand the measured report to
Claude with web search enabled and get back concrete cards to cut and add, with
reasons, stored and auditable.

**Architecture:** `Deckex.Consults` freezes a report snapshot and the exact
prompt, then a worker calls the AI port. The briefing builder is pure: it takes
a `%Report{}` and a lens and returns Markdown, so what the model sees is
testable without a database or a subprocess.

**Tech Stack:** Elixir 1.19.5 / OTP 27, Ecto, Oban, the `claude` CLI in headless
JSON-schema mode with `--allowedTools WebSearch`.

**Spec:** `docs/superpowers/specs/2026-08-13-deckex-design.md` §3.4, §4.3 — this
plan implements milestone 6 of §13.

## Global Constraints

- **Code is English; user-facing strings are pt-BR.** Card names are never
  translated — they are what the model must return verbatim.
- **Every aggregate is a triad**; edges never build Ecto queries.
- **Errors are data:** `{:ok, _}` / `{:error, %Deckex.Error{}}`.
- **No external call inside an open transaction.** The AI call happens in a
  worker, after the consult row is committed.
- **No test performs network or subprocess I/O** — the AI port is Mox.
- **The exact prompt is stored.** A consult nobody can reproduce is a consult
  nobody can trust, and it is also what makes "copy this to your own terminal"
  free.
- **`mix lint` green BEFORE every commit.**

## File structure

| File | Responsibility |
|---|---|
| `lib/deckex/consults/consult.ex` | Schema: lens, status, briefing, snapshot, response |
| `lib/deckex/consults/consult_query.ex` | All reads |
| `lib/deckex/consults/briefing.ex` | Pure: `%Report{}` + lens → Markdown prompt |
| `lib/deckex/consults/schemas.ex` | The JSON schema the model must satisfy |
| `lib/deckex/consults.ex` | Context: request, list, retry |
| `lib/deckex/workers/consult_worker.ex` | The AI call, off the request path |
| `lib/deckex_web/live/deck_live.ex` | The button on each finding, and the results |

---

### Task 1: The `consults` table

**Files:**
- Create: `priv/repo/migrations/<timestamp>_create_consults.exs`
- Create: `lib/deckex/consults/consult.ex`
- Create: `lib/deckex/consults/consult_query.ex`
- Modify: `lib/deckex/analysis/report.ex`, `lib/deckex/analysis/finding.ex` (JSON encoding)
- Modify: `test/support/factory.ex`
- Test: `test/deckex/consults/consult_test.exs`

**Interfaces:**
- Consumes: `Deckex.Decks.Deck`, `Deckex.Analysis.Report`.
- Produces:
  - `%Deckex.Consults.Consult{deck_id, lens, finding_code, status, briefing, report_snapshot, response, model, error, duration_ms}`
  - `Deckex.Consults.Consult.changeset/2`
  - `Deckex.Consults.ConsultQuery.list_for_deck(%Deck{}) :: [%Consult{}]`
  - `Deckex.Consults.ConsultQuery.fetch(id) :: {:ok, %Consult{}} | {:error, %Deckex.Error{}}`
  - `Deckex.Factory.consult_factory/0`

- [ ] **Step 1: Generate and write the migration**

```bash
mix ecto.gen.migration create_consults
```

```elixir
defmodule Deckex.Repo.Migrations.CreateConsults do
  use Ecto.Migration

  def change do
    create table(:consults, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :deck_id, references(:decks, type: :uuid, on_delete: :delete_all), null: false
      add :lens, :string, null: false
      add :finding_code, :string
      add :status, :string, null: false

      # The exact prompt sent, and the report it was built from. A consult
      # nobody can reproduce is a consult nobody can trust.
      add :briefing, :text, null: false
      add :report_snapshot, :map, null: false

      add :response, :map
      add :model, :string
      add :error, :text
      add :duration_ms, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:consults, [:deck_id])
    create index(:consults, [:status])
  end
end
```

- [ ] **Step 2: Write the failing test**

Create `test/deckex/consults/consult_test.exs`:

```elixir
defmodule Deckex.Consults.ConsultTest do
  use Deckex.DataCase, async: true

  alias Deckex.Consults.Consult
  alias Deckex.Consults.ConsultQuery
  alias Deckex.Error

  defp valid_attrs(deck) do
    %{
      deck_id: deck.id,
      lens: :mana_ramp,
      status: :pending,
      briefing: "Analise este deck.",
      report_snapshot: %{"curve" => %{"avg_cmc" => 2.8}}
    }
  end

  describe "changeset/2" do
    test "accepts a pending consult" do
      changeset = Consult.changeset(%Consult{}, valid_attrs(insert(:deck)))

      assert %Ecto.Changeset{valid?: true} = changeset
    end

    test "requires the deck, the lens, the status, the briefing and the snapshot" do
      errors = %Consult{} |> Consult.changeset(%{}) |> errors_on()

      for field <- [:deck_id, :lens, :status, :briefing, :report_snapshot] do
        assert %{^field => ["can't be blank"]} = errors
      end
    end

    test "rejects a lens outside the vocabulary" do
      changeset =
        Consult.changeset(%Consult{}, %{valid_attrs(insert(:deck)) | lens: :vibes})

      assert %{lens: ["is invalid"]} = errors_on(changeset)
    end

    test "stores the frozen report as a map" do
      deck = insert(:deck)

      assert {:ok, consult} =
               %Consult{} |> Consult.changeset(valid_attrs(deck)) |> Repo.insert()

      assert %{"curve" => %{"avg_cmc" => 2.8}} = consult.report_snapshot
    end
  end

  describe "ConsultQuery" do
    test "lists a deck's consults newest first" do
      deck = insert(:deck)
      _older = insert(:consult, deck: deck, briefing: "primeira")
      newer = insert(:consult, deck: deck, briefing: "segunda")

      assert [%{id: first} | _rest] = ConsultQuery.list_for_deck(deck)
      assert first == newer.id
    end

    test "does not leak another deck's consults" do
      deck = insert(:deck)
      insert(:consult, deck: insert(:deck))

      assert ConsultQuery.list_for_deck(deck) == []
    end

    test "fetch/1 returns a tagged tuple" do
      consult = insert(:consult)

      assert {:ok, %{id: id}} = ConsultQuery.fetch(consult.id)
      assert id == consult.id

      assert {:error, %Error{code: :consult_not_found}} =
               ConsultQuery.fetch(Ecto.UUID.generate())
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `mix test test/deckex/consults/consult_test.exs`
Expected: FAIL — `module Deckex.Consults.Consult is not available`.

- [ ] **Step 4: Add the error code and make the report JSON-encodable**

In `lib/deckex/error.ex`, add `| :consult_not_found` to the `@type code` union.

In `lib/deckex/analysis/finding.ex`, add above `defstruct`:

```elixir
  @derive Jason.Encoder
```

In `lib/deckex/analysis/report.ex`, add above `defstruct`:

```elixir
  @derive Jason.Encoder
```

- [ ] **Step 5: Write the schema**

Create `lib/deckex/consults/consult.ex`:

```elixir
defmodule Deckex.Consults.Consult do
  @moduledoc """
  One question put to the AI about one deck.

  The row stores the **exact briefing sent** and the **report it was built
  from**. That is what makes a consult reproducible — and it is also why
  "copy this prompt to your own terminal" costs nothing extra: the prompt is
  already here.
  """
  use Deckex.Schema

  import Ecto.Changeset

  alias Deckex.Decks.Deck

  @lenses [:speed_curve, :mana_ramp, :interaction, :consistency, :full, :finding]

  @type t :: %__MODULE__{}

  schema "consults" do
    field :lens, Ecto.Enum, values: @lenses
    field :finding_code, :string
    field :status, Ecto.Enum, values: [:pending, :running, :done, :failed]
    field :briefing, :string
    field :report_snapshot, :map
    field :response, :map
    field :model, :string
    field :error, :string
    field :duration_ms, :integer

    belongs_to :deck, Deck

    timestamps()
  end

  @doc "Every lens a consult can be scoped to."
  @spec lenses() :: [atom()]
  def lenses, do: @lenses

  @doc "Builds a changeset for a consult."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(consult, attrs) do
    consult
    |> cast(attrs, [
      :deck_id,
      :lens,
      :finding_code,
      :status,
      :briefing,
      :report_snapshot,
      :response,
      :model,
      :error,
      :duration_ms
    ])
    |> validate_required([:deck_id, :lens, :status, :briefing, :report_snapshot])
    |> foreign_key_constraint(:deck_id)
  end
end
```

- [ ] **Step 6: Write the query module**

Create `lib/deckex/consults/consult_query.ex`:

```elixir
defmodule Deckex.Consults.ConsultQuery do
  @moduledoc "All reads of consults."

  import Ecto.Query

  alias Deckex.Consults.Consult
  alias Deckex.Decks.Deck
  alias Deckex.Error
  alias Deckex.Repo

  @doc "A deck's consults, newest first."
  @spec list_for_deck(Deck.t()) :: [Consult.t()]
  def list_for_deck(%Deck{id: deck_id}) do
    Repo.all(from c in Consult, where: c.deck_id == ^deck_id, order_by: [desc: c.inserted_at])
  end

  @doc "Fetches a consult by id as a tagged tuple."
  @spec fetch(String.t()) :: {:ok, Consult.t()} | {:error, Error.t()}
  def fetch(id) do
    case Repo.get(Consult, id) do
      nil -> {:error, Error.new(:consult_not_found, "Não achei essa consulta.", %{id: id})}
      consult -> {:ok, consult}
    end
  end
end
```

- [ ] **Step 7: Add the factory**

In `test/support/factory.ex`, add `alias Deckex.Consults.Consult` and:

```elixir
  def consult_factory do
    %Consult{
      deck: build(:deck),
      lens: :mana_ramp,
      status: :pending,
      briefing: "Analise este deck.",
      report_snapshot: %{"curve" => %{"avg_cmc" => 2.8}}
    }
  end
```

- [ ] **Step 8: Migrate, test, gate, commit**

```bash
mix ecto.migrate && mix test test/deckex/consults/consult_test.exs
```

Expected: PASS — 7 tests.

```bash
mix lint && git add -A && git commit -m "feat: add the consults table

A consult stores the exact briefing sent and the report it was built from: one
nobody can reproduce is one nobody can trust."
```

---

### Task 2: The briefing

The prompt is the product here. It is pure — a `%Report{}` and a lens in,
Markdown out — so what the model sees is testable without a database.

**Files:**
- Create: `lib/deckex/consults/briefing.ex`
- Test: `test/deckex/consults/briefing_test.exs`

**Interfaces:**
- Consumes: `%Deckex.Analysis.Report{}`, `%Deckex.Analysis.DeckSnapshot{}`.
- Produces:
  - `Deckex.Consults.Briefing.build(%Report{}, %DeckSnapshot{}, lens :: atom(), opts :: keyword()) :: String.t()`
    where `opts` accepts `:finding_code` (scope to one finding) and
    `:budget_usd` (a ceiling mentioned to the model).

- [ ] **Step 1: Write the failing test**

Create `test/deckex/consults/briefing_test.exs`:

```elixir
defmodule Deckex.Consults.BriefingTest do
  use ExUnit.Case, async: true

  alias Deckex.Analysis
  alias Deckex.AnalysisFixture
  alias Deckex.Consults.Briefing

  defp deck do
    lands =
      for i <- 1..30 do
        AnalysisFixture.entry(
          produced_mana: ["G"],
          name: "Forest #{i}",
          type_line: "Basic Land — Forest",
          cmc: "0.0",
          mana_cost: nil
        )
      end

    spells =
      for i <- 1..20 do
        AnalysisFixture.entry(name: "Feitiço #{i}", cmc: "3.0", mana_cost: "{2}{G}")
      end

    AnalysisFixture.snapshot(lands ++ spells,
      color_identity: ["G"],
      deck_name: "Deck Verde",
      commanders: [AnalysisFixture.entry(name: "Comandante Teste", mana_cost: "{3}{G}")]
    )
  end

  defp briefing(lens, opts \\ []) do
    snapshot = deck()

    Briefing.build(Analysis.report(snapshot), snapshot, lens, opts)
  end

  describe "build/4" do
    test "names the deck, the commander and the colour identity" do
      text = briefing(:full)

      assert text =~ "Deck Verde"
      assert text =~ "Comandante Teste"
      assert text =~ "G"
    end

    test "includes the full decklist so the model can suggest cuts" do
      text = briefing(:full)

      assert text =~ "Feitiço 1"
      assert text =~ "Forest 1"
    end

    test "includes the measurements for the lens asked about" do
      text = briefing(:mana_ramp)

      assert text =~ "terrenos" or text =~ "Terrenos"
      assert text =~ "fontes" or text =~ "sources"
    end

    test "includes the findings with their evidence" do
      text = briefing(:full)

      # This deck has no interaction at all, so that finding must be in there.
      assert text =~ "interaction."
    end

    test "scopes to one finding when asked" do
      text = briefing(:finding, finding_code: "interaction.no_board_wipes")

      assert text =~ "interaction.no_board_wipes"
      refute text =~ "consistency.no_wincon"
    end

    test "asks for cuts and adds explicitly" do
      text = briefing(:full)

      assert text =~ "cut"
      assert text =~ "add"
    end

    test "tells the model to keep the colour identity" do
      assert briefing(:full) =~ "colour identity"
    end

    test "mentions a budget when one is given" do
      assert briefing(:full, budget_usd: 50) =~ "50"
    end

    test "says nothing about budget when none is given" do
      refute briefing(:full) =~ "budget"
    end

    test "is deterministic" do
      snapshot = deck()
      report = Analysis.report(snapshot)

      assert Briefing.build(report, snapshot, :full) ==
               Briefing.build(report, snapshot, :full)
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/deckex/consults/briefing_test.exs`
Expected: FAIL — `module Deckex.Consults.Briefing is not available`.

- [ ] **Step 3: Write the briefing builder**

Create `lib/deckex/consults/briefing.ex`:

```elixir
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

    Work the findings above. For each one, name specific cards to **cut** from
    the list and specific cards to **add**, and say why in one sentence each.

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
  defp lens_keys(_full_or_finding), do: [:curve, :mana, :interaction, :consistency]

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
        "#{entry.quantity} #{entry.card.name} — #{entry.card.mana_cost || "no cost"} — #{entry.card.type_line}"
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
```

- [ ] **Step 4: Run the test, gate, commit**

Run: `mix test test/deckex/consults/briefing_test.exs`
Expected: PASS — 10 tests.

```bash
mix lint && git add -A && git commit -m "feat: build the AI briefing from a report

The prompt carries the full decklist and the colour identity: a model asked to
suggest cuts must know what is there, and a suggestion outside the identity is
illegal rather than merely bad."
```

---

### Task 3: The output schema

**Files:**
- Create: `lib/deckex/consults/schemas.ex`
- Test: `test/deckex/consults/schemas_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces: `Deckex.Consults.Schemas.for_lens(atom()) :: map()`

- [ ] **Step 1: Write the failing test**

Create `test/deckex/consults/schemas_test.exs`:

```elixir
defmodule Deckex.Consults.SchemasTest do
  use ExUnit.Case, async: true

  alias Deckex.Consults.Schemas

  describe "for_lens/1" do
    test "requires a diagnosis and the two lists" do
      schema = Schemas.for_lens(:full)

      assert schema["required"] == ["diagnosis", "cuts", "adds"]
    end

    test "a cut names a card and a reason" do
      cut = get_in(Schemas.for_lens(:full), ["properties", "cuts", "items"])

      assert cut["required"] == ["card", "reason"]
    end

    test "an add names a card, a reason and what it replaces" do
      add = get_in(Schemas.for_lens(:full), ["properties", "adds", "items"])

      assert "card" in add["required"]
      assert "reason" in add["required"]
      assert Map.has_key?(add["properties"], "replaces")
    end

    test "every lens gets a schema" do
      for lens <- [:speed_curve, :mana_ramp, :interaction, :consistency, :full, :finding] do
        assert %{"type" => "object"} = Schemas.for_lens(lens)
      end
    end

    test "the schema survives a JSON round trip" do
      schema = Schemas.for_lens(:mana_ramp)

      assert schema == schema |> Jason.encode!() |> Jason.decode!()
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/deckex/consults/schemas_test.exs`
Expected: FAIL — `module Deckex.Consults.Schemas is not available`.

- [ ] **Step 3: Write the schemas**

Create `lib/deckex/consults/schemas.ex`:

```elixir
defmodule Deckex.Consults.Schemas do
  @moduledoc """
  The JSON schema a consult's answer must satisfy.

  Every lens gets the same **shape** — a diagnosis, cards to cut, cards to add
  — because that is what the user does with the answer regardless of which
  question was asked. What differs per lens is the *prompt*, not the schema;
  `for_lens/1` exists so that stops being true the day it needs to.
  """

  @spec for_lens(atom()) :: map()
  def for_lens(_lens) do
    %{
      "type" => "object",
      "properties" => %{
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
              "reason" => %{"type" => "string", "description" => "One sentence, pt-BR."}
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
      "required" => ["diagnosis", "cuts", "adds"]
    }
  end
end
```

- [ ] **Step 4: Run the test, gate, commit**

Run: `mix test test/deckex/consults/schemas_test.exs`
Expected: PASS — 5 tests.

```bash
mix lint && git add -A && git commit -m "feat: add the consult output schema"
```

---

### Task 4: The context and the worker

**Files:**
- Create: `lib/deckex/consults.ex`
- Create: `lib/deckex/workers/consult_worker.ex`
- Modify: `lib/deckex/events.ex` (a consult topic)
- Test: `test/deckex/consults_test.exs`

**Interfaces:**
- Consumes: `Briefing.build/4` (Task 2), `Schemas.for_lens/1` (Task 3),
  `Consult`/`ConsultQuery` (Task 1), `Deckex.AI.complete/3`,
  `Deckex.Decks.snapshot/1`, `Deckex.Analysis.report/2`.
- Produces:
  - `Deckex.Consults.request(%Deck{}, lens :: atom(), opts :: keyword()) :: {:ok, %Consult{}} | {:error, %Deckex.Error{}}`
    where `opts` accepts `:finding_code`
  - `Deckex.Consults.list_for_deck(%Deck{}) :: [%Consult{}]`
  - `Deckex.Consults.run(%Consult{}) :: {:ok, %Consult{}} | {:error, %Deckex.Error{}}`
  - `Deckex.Workers.ConsultWorker.enqueue(consult_id :: String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}`
  - `Deckex.Events.subscribe_consults(deck_id) :: :ok`, `Deckex.Events.broadcast_consult(%Consult{}) :: :ok`

- [ ] **Step 1: Write the failing test**

Create `test/deckex/consults_test.exs`:

```elixir
defmodule Deckex.ConsultsTest do
  use Deckex.DataCase, async: true

  import Mox

  alias Deckex.CatalogueFixture
  alias Deckex.Consults
  alias Deckex.Decks
  alias Deckex.Error
  alias Deckex.Workers.ConsultWorker

  setup :verify_on_exit!

  defp deck do
    CatalogueFixture.seed!(~w(sol_ring forest counterspell))

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n1 Counterspell\n4 Forest", %{
        name: "Deck de Consulta",
        source: :paste
      })

    deck
  end

  defp answer do
    {:ok,
     %{
       "diagnosis" => "Falta interação.",
       "cuts" => [%{"card" => "Sol Ring", "reason" => "exemplo"}],
       "adds" => [%{"card" => "Swords to Plowshares", "reason" => "remoção barata"}]
     }}
  end

  describe "request/3" do
    test "freezes the briefing and the report, then queues the call" do
      deck = deck()

      assert {:ok, consult} = Consults.request(deck, :mana_ramp)

      assert consult.status == :pending
      assert consult.lens == :mana_ramp
      assert consult.briefing =~ "Deck de Consulta"
      assert is_map(consult.report_snapshot)

      assert_enqueued(worker: ConsultWorker)
    end

    test "scopes to one finding when given a code" do
      deck = deck()

      assert {:ok, consult} =
               Consults.request(deck, :finding, finding_code: "interaction.no_board_wipes")

      assert consult.finding_code == "interaction.no_board_wipes"
      assert consult.briefing =~ "interaction.no_board_wipes"
    end

    test "lists a deck's consults" do
      deck = deck()
      {:ok, _consult} = Consults.request(deck, :full)

      assert [%{lens: :full}] = Consults.list_for_deck(deck)
    end
  end

  describe "run/1" do
    test "stores the model's answer and marks the consult done" do
      deck = deck()
      {:ok, consult} = Consults.request(deck, :full)

      expect(Deckex.AI.Mock, :complete, fn prompt, schema, opts ->
        assert prompt =~ "Commander"
        assert schema["required"] == ["diagnosis", "cuts", "adds"]
        # The whole point: the model may look things up.
        assert opts[:allowed_tools] == ["WebSearch"]

        answer()
      end)

      assert {:ok, done} = Consults.run(consult)

      assert done.status == :done
      assert done.response["diagnosis"] == "Falta interação."
      assert done.duration_ms >= 0
      assert done.model != nil
    end

    test "records a failure instead of losing it" do
      deck = deck()
      {:ok, consult} = Consults.request(deck, :full)

      expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts ->
        {:error, Error.new(:ai_timeout, "estourou")}
      end)

      assert {:error, %Error{code: :ai_timeout}} = Consults.run(consult)

      assert [%{status: :failed, error: stored}] = Consults.list_for_deck(deck)
      assert stored =~ "estourou"
    end

    test "sends the stored briefing verbatim — never a rebuilt one" do
      deck = deck()
      {:ok, consult} = Consults.request(deck, :full)

      expect(Deckex.AI.Mock, :complete, fn prompt, _schema, _opts ->
        assert prompt == consult.briefing

        answer()
      end)

      assert {:ok, _done} = Consults.run(consult)
    end
  end

  describe "ConsultWorker" do
    test "runs the consult it is given" do
      deck = deck()
      {:ok, consult} = Consults.request(deck, :full)

      expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts -> answer() end)

      assert :ok = perform_job(ConsultWorker, %{consult_id: consult.id})
      assert [%{status: :done}] = Consults.list_for_deck(deck)
    end

    test "cancels when the consult has vanished" do
      assert {:cancel, _reason} =
               perform_job(ConsultWorker, %{consult_id: Ecto.UUID.generate()})
    end

    test "retries a timeout rather than cancelling" do
      deck = deck()
      {:ok, consult} = Consults.request(deck, :full)

      expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts ->
        {:error, Error.new(:ai_timeout, "estourou")}
      end)

      assert {:error, %Error{code: :ai_timeout}} =
               perform_job(ConsultWorker, %{consult_id: consult.id})
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/deckex/consults_test.exs`
Expected: FAIL — `module Deckex.Consults is not available`.

- [ ] **Step 3: Add the consult PubSub topic**

In `lib/deckex/events.ex`, add `alias Deckex.Consults.Consult` and:

```elixir
  @typedoc "Broadcast when a consult changes state."
  @type consult_updated :: {:consult_updated, consult_id :: String.t()}

  @doc "Subscribes the calling process to one deck's consult activity."
  @spec subscribe_consults(String.t()) :: :ok | {:error, term()}
  def subscribe_consults(deck_id), do: Phoenix.PubSub.subscribe(@pubsub, consult_topic(deck_id))

  @doc "Announces that a consult changed."
  @spec broadcast_consult(Consult.t()) :: :ok | {:error, term()}
  def broadcast_consult(%Consult{deck_id: deck_id, id: id}) do
    Phoenix.PubSub.broadcast(@pubsub, consult_topic(deck_id), {:consult_updated, id})
  end

  defp consult_topic(deck_id), do: "deck:#{deck_id}:consults"
```

- [ ] **Step 4: Write the context**

Create `lib/deckex/consults.ex`:

```elixir
defmodule Deckex.Consults do
  @moduledoc """
  Asking the AI what to do about a deck.

  `request/3` measures the deck, freezes both the report and the exact prompt,
  and queues the call. `run/1` sends **the stored briefing verbatim** — never a
  rebuilt one — because a consult whose prompt drifted from what was recorded is
  a consult that cannot be trusted or reproduced.
  """

  alias Deckex.AI
  alias Deckex.Analysis
  alias Deckex.Consults.Briefing
  alias Deckex.Consults.Consult
  alias Deckex.Consults.ConsultQuery
  alias Deckex.Consults.Schemas
  alias Deckex.Decks
  alias Deckex.Decks.Deck
  alias Deckex.Error
  alias Deckex.Events
  alias Deckex.Repo
  alias Deckex.Workers.ConsultWorker

  defdelegate list_for_deck(deck), to: ConsultQuery
  defdelegate fetch(id), to: ConsultQuery

  @doc """
  Measures `deck`, freezes the report and the prompt, and queues the AI call.

  This cannot fail for an expected reason — every field is built here, not
  supplied by a user — so it raises rather than returning a tagged error. The
  `{:ok, _}` wrapper is kept because the caller composes with `Consults.run/1`,
  which genuinely can fail.
  """
  @spec request(Deck.t(), atom(), keyword()) :: {:ok, Consult.t()}
  def request(%Deck{} = deck, lens, opts \\ []) do
    snapshot = Decks.snapshot(deck)
    report = Analysis.report(snapshot)
    consult = insert!(deck, lens, Briefing.build(report, snapshot, lens, opts), report, opts)

    {:ok, _job} = ConsultWorker.enqueue(consult.id)
    Events.broadcast_consult(consult)

    {:ok, consult}
  end

  @doc """
  Sends a consult's stored briefing to the model and records the answer.
  """
  @spec run(Consult.t()) :: {:ok, Consult.t()} | {:error, Error.t()}
  def run(%Consult{} = consult) do
    running = update!(consult, %{status: :running})
    started = System.monotonic_time(:millisecond)

    # WebSearch is the point of the whole feature: the app supplies measured
    # facts about this deck, the model supplies knowledge about every card.
    case AI.complete(running.briefing, Schemas.for_lens(running.lens), allowed_tools: ["WebSearch"]) do
      {:ok, response} -> {:ok, succeed(running, response, started)}
      {:error, %Error{} = error} -> fail(running, error)
    end
  end

  defp insert!(deck, lens, briefing, report, opts) do
    %Consult{}
    |> Consult.changeset(%{
      deck_id: deck.id,
      lens: lens,
      finding_code: opts[:finding_code],
      status: :pending,
      briefing: briefing,
      report_snapshot: freeze(report)
    })
    |> Repo.insert!()
  end

  # Through JSON and back, so the stored snapshot is exactly what a reader will
  # get out of the column — no structs, no atoms.
  defp freeze(report), do: report |> Jason.encode!() |> Jason.decode!()

  defp succeed(consult, response, started) do
    update!(consult, %{
      status: :done,
      response: response,
      model: AI.model(),
      duration_ms: System.monotonic_time(:millisecond) - started,
      error: nil
    })
  end

  defp fail(consult, %Error{} = error) do
    update!(consult, %{status: :failed, error: error.message})

    {:error, error}
  end

  defp update!(consult, attrs) do
    updated = consult |> Consult.changeset(attrs) |> Repo.update!()

    Events.broadcast_consult(updated)

    updated
  end
end
```

- [ ] **Step 5: Write the worker**

Create `lib/deckex/workers/consult_worker.ex`:

```elixir
defmodule Deckex.Workers.ConsultWorker do
  @moduledoc """
  Runs one consult off the request path.

  A vanished consult is permanent (`:cancel`); an AI timeout is transient and
  retries. Anything else has already been recorded on the row, so the job does
  not need to retry to preserve it.
  """
  use Oban.Worker, queue: :ai, max_attempts: 3

  alias Deckex.Consults

  @doc "Enqueues the AI call for a consult."
  @spec enqueue(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(consult_id) when is_binary(consult_id) do
    %{consult_id: consult_id} |> new() |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"consult_id" => consult_id}}) do
    case Consults.fetch(consult_id) do
      {:ok, consult} -> run(consult)
      {:error, error} -> {:cancel, error.message}
    end
  end

  defp run(consult) do
    case Consults.run(consult) do
      {:ok, _done} -> :ok
      {:error, %{code: :ai_timeout} = error} -> {:error, error}
      {:error, error} -> {:cancel, error.message}
    end
  end
end
```

- [ ] **Step 6: Run the test, gate, commit**

Run: `mix test test/deckex/consults_test.exs`
Expected: PASS — 9 tests.

```bash
mix lint && git add -A && git commit -m "feat: request and run AI consults

run/1 sends the stored briefing verbatim rather than rebuilding it: a consult
whose prompt drifted from what was recorded cannot be reproduced."
```

---

### Task 5: The button on every finding

**Files:**
- Modify: `lib/deckex_web/live/deck_live.ex`
- Test: `test/deckex_web/live/deck_consult_test.exs`

**Interfaces:**
- Consumes: `Consults.request/3`, `Consults.list_for_deck/1` (Task 4),
  `Events.subscribe_consults/1` (Task 4).
- Produces: no new modules.

- [ ] **Step 1: Write the failing test**

Create `test/deckex_web/live/deck_consult_test.exs`:

```elixir
defmodule DeckexWeb.DeckConsultTest do
  use DeckexWeb.ConnCase, async: true

  import Mox
  import Phoenix.LiveViewTest

  alias Deckex.CatalogueFixture
  alias Deckex.Consults
  alias Deckex.Decks

  setup :verify_on_exit!

  setup do
    CatalogueFixture.seed!(~w(sol_ring forest counterspell))

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n1 Counterspell\n4 Forest", %{
        name: "Deck da Consulta",
        source: :paste
      })

    %{deck: deck}
  end

  test "every finding offers a consult", %{conn: conn, deck: deck} do
    {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

    assert live |> element("button[phx-value-code='interaction.no_board_wipes']") |> has_element?()
  end

  test "asking about a finding creates a scoped consult", %{conn: conn, deck: deck} do
    {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

    live
    |> element("button[phx-value-code='interaction.no_board_wipes']")
    |> render_click()

    assert [%{lens: :finding, finding_code: "interaction.no_board_wipes"}] =
             Consults.list_for_deck(deck)
  end

  test "the whole deck can be consulted at once", %{conn: conn, deck: deck} do
    {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

    live |> element("button[phx-click='consult-full']") |> render_click()

    assert [%{lens: :full}] = Consults.list_for_deck(deck)
  end

  test "a finished consult renders its cuts and adds", %{conn: conn, deck: deck} do
    {:ok, consult} = Consults.request(deck, :full)

    expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts ->
      {:ok,
       %{
         "diagnosis" => "Falta interação nesse deck.",
         "cuts" => [%{"card" => "Sol Ring", "reason" => "exemplo de corte"}],
         "adds" => [%{"card" => "Swords to Plowshares", "reason" => "remoção barata"}]
       }}
    end)

    {:ok, _done} = Consults.run(consult)

    {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

    assert html =~ "Falta interação nesse deck."
    assert html =~ "Swords to Plowshares"
    assert html =~ "remoção barata"
  end

  test "the exact prompt is available to copy", %{conn: conn, deck: deck} do
    {:ok, _consult} = Consults.request(deck, :full)

    {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

    assert html =~ "Ver o prompt"
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/deckex_web/live/deck_consult_test.exs`
Expected: FAIL — the buttons do not exist.

- [ ] **Step 3: Load and subscribe to consults in the LiveView**

In `lib/deckex_web/live/deck_live.ex`, add `alias Deckex.Consults` and
`alias Deckex.Events`, then replace `assign_deck/2` with:

```elixir
  defp assign_deck(socket, deck) do
    if connected?(socket), do: Events.subscribe_consults(deck.id)

    snapshot = Decks.snapshot(deck)

    assign(socket,
      deck: deck,
      snapshot: snapshot,
      report: Analysis.report(snapshot),
      consults: Consults.list_for_deck(deck),
      page_title: deck.name
    )
  end
```

and add the event handlers after `mount/3`:

```elixir
  @impl Phoenix.LiveView
  def handle_event("consult-finding", %{"code" => code}, socket) do
    {:noreply, start_consult(socket, :finding, finding_code: code)}
  end

  def handle_event("consult-full", _params, socket) do
    {:noreply, start_consult(socket, :full)}
  end

  @impl Phoenix.LiveView
  def handle_info({:consult_updated, _id}, socket) do
    {:noreply, assign(socket, consults: Consults.list_for_deck(socket.assigns.deck))}
  end

  # Consults.request/3 raises rather than returning a tagged error — every
  # field it writes is built here, so a failure is a bug, not a user problem.
  defp start_consult(socket, lens, opts \\ []) do
    {:ok, _consult} = Consults.request(socket.assigns.deck, lens, opts)

    socket
    |> put_flash(:info, "Consulta enviada. A resposta aparece aqui quando chegar.")
    |> assign(consults: Consults.list_for_deck(socket.assigns.deck))
  end
```

- [ ] **Step 4: Add the button to each finding**

In `lib/deckex_web/live/deck_live.ex`, replace the `<.finding>` call with:

```elixir
            <.finding
              :for={finding <- @report.findings}
              severity={finding.severity}
              title={finding.title}
              code={finding.code}
              cards={finding.card_names}
            >
              <:detail>{finding.detail}</:detail>
              <:actions>
                <button
                  type="button"
                  phx-click="consult-finding"
                  phx-value-code={finding.code}
                  class="text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
                >
                  Pedir diagnóstico
                </button>
              </:actions>
            </.finding>
```

and put a whole-deck button under the findings heading:

```elixir
          <div class="mb-3 flex items-center justify-between">
            <h2 class="text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
              Achados
            </h2>

            <button
              type="button"
              phx-click="consult-full"
              class="text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
            >
              Consultar o deck inteiro
            </button>
          </div>
```

replacing the plain `<h2>Achados</h2>` that was there.

- [ ] **Step 5: Render the consults**

In `lib/deckex_web/live/deck_live.ex`, add this section immediately after the
findings `<div class="space-y-2.5">…</div>` inside the aside:

```elixir
          <section :if={@consults != []} class="mt-8">
            <h2 class="mb-3 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
              Consultas
            </h2>

            <div class="space-y-3">
              <article
                :for={consult <- @consults}
                class="rounded-lg border border-hairline-soft bg-surface p-4"
              >
                <header class="mb-2 flex items-center justify-between gap-3">
                  <span class="font-mono text-caption text-ink-faint">
                    {consult.finding_code || consult.lens}
                  </span>
                  <span class={[
                    "font-mono text-caption",
                    consult.status == :done && "text-sev-healthy",
                    consult.status == :failed && "text-sev-critical",
                    consult.status in [:pending, :running] && "text-ink-faint"
                  ]}>
                    {consult_status(consult.status)}
                  </span>
                </header>

                <p :if={consult.error} class="text-body-sm text-ink-secondary">{consult.error}</p>

                <div :if={consult.response} class="space-y-3">
                  <p class="text-body-sm text-ink">{consult.response["diagnosis"]}</p>

                  <div :if={consult.response["cuts"] != []}>
                    <p class="mb-1 text-label uppercase tracking-[0.1em] text-ink-faint">Cortar</p>
                    <ul class="space-y-1">
                      <li :for={cut <- consult.response["cuts"] || []} class="text-caption">
                        <span class="text-ink">{cut["card"]}</span>
                        <span class="text-ink-muted">— {cut["reason"]}</span>
                      </li>
                    </ul>
                  </div>

                  <div :if={consult.response["adds"] != []}>
                    <p class="mb-1 text-label uppercase tracking-[0.1em] text-ink-faint">Colocar</p>
                    <ul class="space-y-1">
                      <li :for={add <- consult.response["adds"] || []} class="text-caption">
                        <span class="text-ink">{add["card"]}</span>
                        <span class="text-ink-muted">— {add["reason"]}</span>
                      </li>
                    </ul>
                  </div>
                </div>

                <details class="mt-3">
                  <summary class="cursor-pointer text-caption text-ink-faint hover:text-ink">
                    Ver o prompt
                  </summary>
                  <pre class="mt-2 max-h-64 overflow-auto rounded-md bg-inlay p-3 font-mono text-micro text-ink-muted"><%= consult.briefing %></pre>
                </details>
              </article>
            </div>
          </section>
```

and add the status label helper next to the other private functions:

```elixir
  defp consult_status(:pending), do: "na fila"
  defp consult_status(:running), do: "pensando…"
  defp consult_status(:done), do: "pronto"
  defp consult_status(:failed), do: "falhou"
```

- [ ] **Step 6: Run the test, gate, commit**

Run: `mix test test/deckex_web/live/deck_consult_test.exs`
Expected: PASS — 5 tests.

```bash
mix lint && git add -A && git commit -m "feat: ask the AI about a finding from the deck screen

Each finding carries its own consult button, so the question the model gets is
scoped to the one thing the user clicked. The exact prompt is behind a
disclosure -- it is stored anyway, and it is what you paste into your own
terminal."
```

---

### Task 6: One real consult, end to end

Not a test — a manual verification that the whole chain works against the real
`claude` CLI, and a chance to read what the model actually says about a real
deck.

**Files:** none.

- [ ] **Step 1: Confirm the CLI is there**

```bash
which claude && claude --version
```

Expected: a path and a version.

- [ ] **Step 2: Run a consult on the imported deck**

```bash
cd /Users/tavano/projects/deckex
MIX_ENV=dev mix run -e '
  Logger.configure(level: :error)
  deck = List.first(Deckex.Decks.list_decks())
  {:ok, consult} = Deckex.Consults.request(deck, :full)
  {:ok, done} = Deckex.Consults.run(consult)

  IO.puts("status: #{done.status} · #{done.duration_ms}ms · #{done.model}")
  IO.puts("\n#{done.response["diagnosis"]}\n")

  IO.puts("CORTAR:")
  Enum.each(done.response["cuts"] || [], fn c -> IO.puts("  - #{c["card"]}: #{c["reason"]}") end)

  IO.puts("\nCOLOCAR:")
  Enum.each(done.response["adds"] || [], fn a -> IO.puts("  + #{a["card"]}: #{a["reason"]}") end)
'
```

Expected: a diagnosis in Portuguese, with card names untranslated, naming cards
that are actually in the deck for cuts and cards inside the colour identity for
adds. **Read it.** If it suggests a card outside the identity, the briefing's
rule needs strengthening and that is a real finding about the prompt.

- [ ] **Step 3: Check it in the browser**

Open `http://localhost:4005`, click into the deck, and confirm the consult
renders with its cuts and adds, and that "Ver o prompt" shows the briefing.

- [ ] **Step 4: Run the full suite and the gate**

```bash
mix test && mix lint
```

---

## What this plan delivers

The loop closes. The app measures the deck, names what is wrong, and — on one
click — hands those measurements to a model that can search the current card
pool and answer with specific cards to cut and add.

## Next

| Plan | Delivers |
|---|---|
| 6 | Ajustes: the Moxfield User-Agent, the Claude model, and every baseline, editable |
| — | A CSP, and self-hosted fonts (see `.sobelow-conf`) |
