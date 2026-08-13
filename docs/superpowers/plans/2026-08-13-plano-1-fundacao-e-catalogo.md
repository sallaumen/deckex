# Plano 1 — Fundação e Catálogo de Cartas

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the deckex Phoenix application with a green quality gate, and
build a card catalogue that resolves Magic card names into locally-cached,
Scryfall-backed card records — correctly handling double-faced cards.

**Architecture:** Phoenix 1.8 umbrella-free app following the playbook in
`docs/playbook/`. `Deckex.Cards` is the first triad (context + schema + query
module). Scryfall is reached through a port: behaviour → facade resolving a
configured adapter → `Req`-backed HTTP adapter, with a Mox mock in test so no
test touches the network.

**Tech Stack:** Elixir 1.19.5 / OTP 27, Phoenix 1.8.8, LiveView 1.2, PostgreSQL
16 (Docker, host port 5435), Ecto 3.13, Oban, Req, Uniq (UUID v7), Credo,
Dialyxir, Sobelow, ExCheck, ExCoveralls, ExMachina, Mox.

**Spec:** `docs/superpowers/specs/2026-08-13-deckex-design.md` — this plan
implements milestones 1 and 2 of §13.

## Global Constraints

- **Elixir 1.19.5, Erlang/OTP 27** (`.tool-versions`), matching beatgrid and
  forrozin_page on this machine.
- **Code is English** — identifiers, module and function names, `@moduledoc` and
  `@doc`, commit messages. **User-facing strings are pt-BR.** Card names are
  never translated.
- **PostgreSQL host port is 5435.** 5432, 5433 and 5434 are already taken on
  this machine by other projects' containers — verified 2026-08-13.
- **Every aggregate is a triad:** context module (public API + mutations), Ecto
  schema (structure + changesets), `*Query` module (all reads). Edges never
  build Ecto queries.
- **Errors are data.** Fallible operations return `{:ok, _}` / `{:error, %Deckex.Error{}}`.
  Raise only for genuine contract violations.
- **Every external service is a port:** behaviour + facade + real adapter + Mox
  mock wired in `config/test.exs`. **No test may perform network I/O.**
- **UUID v7 primary keys** via `Uniq.UUID`, **`:utc_datetime` timestamps**
  everywhere.
- **Cards are stored at the oracle level** — one row per distinct card, keyed on
  `oracle_id`, not one row per printing.
- **`mix lint` must be green before every commit.**

---

### Task 1: Scaffold the application and the quality gate

**Files:**
- Create: the full `mix phx.new` output at the repository root
- Create: `docker-compose.yml`, `.tool-versions`, `.credo.exs`, `.check.exs`, `.sobelow-conf`
- Modify: `mix.exs`, `config/config.exs`, `config/dev.exs`, `config/test.exs`, `.gitignore`

**Interfaces:**
- Consumes: nothing — this is the first task.
- Produces: a compiling `:deckex` OTP app with modules `Deckex` and `DeckexWeb`,
  a running `Deckex.Repo`, and the mix aliases `mix lint` and `mix precommit`.

- [ ] **Step 1: Generate the Phoenix application**

The repository already contains `.git`, `.claude/` and `docs/`, so the generator
will ask to continue. It asks twice: once about the non-empty directory, once
about fetching dependencies. Answer yes to both.

```bash
cd /Users/tavano/projects/deckex
printf 'y\ny\n' | mix phx.new . --app deckex --module Deckex --no-mailer --no-gettext
```

Expected: files generated under `lib/`, `config/`, `assets/`, `test/`, and
`Dependencies fetched successfully`.

- [ ] **Step 2: Pin the toolchain**

Create `.tool-versions`:

```
elixir 1.19.5-otp-27
erlang 27.3.4.11
```

- [ ] **Step 3: Create the database container**

Create `docker-compose.yml`. Host port **5435** — 5432, 5433 and 5434 are taken
by other projects on this machine.

```yaml
services:
  db:
    image: postgres:16-alpine
    # This is a desktop machine and the app is used in short sessions; bring the
    # database back with Docker Desktop rather than starting every session with
    # a manual `compose up`. "unless-stopped" still honours a deliberate stop.
    restart: unless-stopped
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: deckex_dev
    # Host port 5435 (5432/5433/5434 are other projects on this machine).
    ports:
      - "5435:5432"
    volumes:
      - deckex_pg:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5

volumes:
  deckex_pg:
```

Start it:

```bash
docker compose up -d && sleep 5 && docker compose ps
```

Expected: the `db` service is `running` and healthy.

- [ ] **Step 4: Point Ecto at port 5435**

In `config/dev.exs`, inside `config :deckex, Deckex.Repo`, add `port: 5435`.
In `config/test.exs`, inside `config :deckex, Deckex.Repo`, add `port: 5435`.

- [ ] **Step 5: Add the dependencies**

In `mix.exs`, add to the `deps/0` list:

```elixir
      # Domain / infrastructure
      {:oban, "~> 2.19"},
      {:req, "~> 0.5"},
      {:uniq, "~> 0.6"},

      # Quality / dev tooling
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:ex_check, "~> 0.16", only: [:dev], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},

      # Test tooling
      {:ex_machina, "~> 2.8", only: :test},
      {:mox, "~> 1.2", only: :test}
```

- [ ] **Step 6: Configure the project for coverage and Dialyzer**

In `mix.exs`, inside `project/0`, add:

```elixir
      test_coverage: [tool: ExCoveralls],
      dialyzer: [
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts",
        plt_add_apps: [:ex_unit, :mix]
      ]
```

And add a `cli/0` function to the module:

```elixir
  def cli do
    [
      preferred_envs: [
        precommit: :test,
        coveralls: :test,
        "coveralls.html": :test
      ]
    ]
  end
```

- [ ] **Step 7: Add the quality-gate aliases**

In `mix.exs`, inside `aliases/0`, add these two entries:

```elixir
      # The quality gate (see AGENTS.md). Must be green before every commit.
      lint: [
        "format --check-formatted",
        "deps.unlock --check-unused",
        "credo --strict",
        "sobelow --config",
        "dialyzer"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
```

- [ ] **Step 8: Fetch dependencies and generate the tool configs**

```bash
mix deps.get && mix credo.gen.config && mix sobelow --config
```

Expected: `.credo.exs` and `.sobelow-conf` created.

In `.credo.exs`, set `strict: true` inside the `default` config map.

Create `.check.exs`:

```elixir
[
  parallel: true,
  skipped: false,
  tools: [
    {:compiler, command: "mix compile --warnings-as-errors", detect: [{:package, :elixir}]},
    {:formatter, command: "mix format --check-formatted", detect: [{:package, :elixir}]},
    {:credo, command: "mix credo --strict", detect: [{:package, :credo}]},
    {:dialyzer, command: "mix dialyzer", detect: [{:package, :dialyxir}]},
    {:ex_unit, command: "mix test", detect: [{:package, :ex_unit}]}
  ]
]
```

Append to `.gitignore`:

```
# Dialyzer PLTs
/priv/plts/
```

Create the PLT directory so Dialyzer has somewhere to write:

```bash
mkdir -p priv/plts && touch priv/plts/.gitkeep
```

- [ ] **Step 9: Wire Oban**

In `config/config.exs`, after the `config :deckex, ecto_repos:` block, add:

```elixir
# Repo-wide Ecto defaults: UTC timestamps everywhere + advisory migration lock.
config :deckex, Deckex.Repo,
  migration_timestamps: [type: :utc_datetime],
  migration_lock: :pg_advisory_lock

# Background jobs. `scryfall` is serialized (1) because the /cards/collection
# endpoint is capped at 2 requests/second and the adapter throttles internally —
# concurrent jobs would race that budget and earn a 429.
config :deckex, Oban,
  repo: Deckex.Repo,
  queues: [default: 10, scryfall: 1, ai: 2],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7, interval: :timer.minutes(30)},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30), interval: :timer.minutes(5)}
  ]
```

In `config/test.exs`, add:

```elixir
# Oban: don't run jobs automatically in tests — drive them with perform_job/2.
config :deckex, Oban, testing: :manual
```

In `lib/deckex/application.ex`, add `{Oban, Application.fetch_env!(:deckex, Oban)}`
to the children list, immediately after `Deckex.Repo`.

Oban ships its own tables and will not start without them, so generate its
migration:

```bash
mix ecto.gen.migration add_oban_jobs_table
```

Write its contents:

```elixir
defmodule Deckex.Repo.Migrations.AddObanJobsTable do
  use Ecto.Migration

  def up, do: Oban.Migration.up(version: 12)

  # Keep the down migration at version 1 so a rollback removes everything Oban
  # created, not just the most recent version's changes.
  def down, do: Oban.Migration.down(version: 1)
end
```

- [ ] **Step 10: Create the database and run the gate**

```bash
mix ecto.create && mix ecto.migrate && mix compile --warnings-as-errors && mix test
```

Expected: database created, compilation clean with no warnings, all generated
tests pass.

```bash
mix lint
```

Expected: green. The first `mix dialyzer` run builds the PLT and takes several
minutes — this is normal and happens once. If Credo reports issues in
Phoenix-generated files, fix them rather than disabling the check.

- [ ] **Step 11: Commit**

```bash
git add -A
git commit -m "chore: scaffold Phoenix app with quality gate

Phoenix 1.8 + LiveView + Postgres on port 5435, Oban wired, and the
lint/precommit gate (format, credo --strict, sobelow, dialyzer)."
```

---

### Task 2: Base schema module and the domain error struct

**Files:**
- Create: `lib/deckex/schema.ex`
- Create: `lib/deckex/error.ex`
- Test: `test/deckex/error_test.exs`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `use Deckex.Schema` — sets `@primary_key {:id, Uniq.UUID, version: 7, autogenerate: true}`,
    `@foreign_key_type Uniq.UUID`, `@timestamps_opts [type: :utc_datetime]`.
  - `Deckex.Error.new(code :: atom(), message :: String.t(), details :: map()) :: %Deckex.Error{}`
    with fields `:code`, `:message`, `:details`.

- [ ] **Step 1: Write the failing test**

Create `test/deckex/error_test.exs`:

```elixir
defmodule Deckex.ErrorTest do
  use ExUnit.Case, async: true

  alias Deckex.Error

  describe "new/3" do
    test "carries a code, a message and details" do
      error = Error.new(:moxfield_blocked, "O Moxfield bloqueou a busca.", %{status: 403})

      assert %Error{code: :moxfield_blocked, details: %{status: 403}} = error
      assert error.message == "O Moxfield bloqueou a busca."
    end

    test "defaults details to an empty map" do
      assert %Error{details: %{}} = Error.new(:ai_timeout, "A IA não respondeu.")
    end

    test "is a raisable exception whose message is the domain message" do
      error = Error.new(:scryfall_unavailable, "Scryfall fora do ar.")

      assert Exception.message(error) == "Scryfall fora do ar."
      assert_raise Error, "Scryfall fora do ar.", fn -> raise error end
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/deckex/error_test.exs`
Expected: FAIL — `module Deckex.Error is not available`.

- [ ] **Step 3: Write the base schema module**

Create `lib/deckex/schema.ex`:

```elixir
defmodule Deckex.Schema do
  @moduledoc """
  Base schema for every table in the application: UUID v7 primary keys and UTC
  timestamps. `use Deckex.Schema` instead of `Ecto.Schema` directly so the key
  strategy is declared once rather than copied into every schema — and so
  foreign keys automatically agree with the primary keys they point at.
  """

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema

      @primary_key {:id, Uniq.UUID, version: 7, autogenerate: true}
      @foreign_key_type Uniq.UUID
      @timestamps_opts [type: :utc_datetime]
    end
  end
end
```

- [ ] **Step 4: Write the error struct**

Create `lib/deckex/error.ex`:

```elixir
defmodule Deckex.Error do
  @moduledoc """
  The domain error. Every operation that can fail for an *expected* reason
  returns `{:error, %Deckex.Error{}}` rather than raising — errors are data.

  Raising is reserved for genuine contract violations (a missing preload, an
  impossible state), which should crash loudly instead of being handled.
  """

  @typedoc "Every expected failure in the system has one of these codes."
  @type code ::
          :moxfield_blocked
          | :moxfield_private
          | :moxfield_not_found
          | :scryfall_unavailable
          | :cards_not_found
          | :not_commander_legal
          | :ai_timeout
          | :ai_unavailable

  @type t :: %__MODULE__{code: code(), message: String.t(), details: map()}

  defexception [:code, :message, details: %{}]

  @doc """
  Builds a domain error. `message` is user-facing and therefore pt-BR; `details`
  carries whatever the caller needs for logging or for rendering a richer UI.
  """
  @spec new(code(), String.t(), map()) :: t()
  def new(code, message, details \\ %{}) when is_atom(code) and is_binary(message) do
    %__MODULE__{code: code, message: message, details: details}
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/deckex/error_test.exs`
Expected: PASS, 3 tests.

- [ ] **Step 6: Run the gate and commit**

```bash
mix lint && git add lib/deckex/schema.ex lib/deckex/error.ex test/deckex/error_test.exs
git commit -m "feat: add base schema and domain error struct"
```

---

### Task 3: Card name normalization

Decklists and Scryfall disagree about how a card is written. This module
collapses every spelling to one lookup key, and it is used by both the Scryfall
mapper (Task 5) and the decklist parser (a later plan).

**Files:**
- Create: `lib/deckex/cards/name.ex`
- Test: `test/deckex/cards/name_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces: `Deckex.Cards.Name.normalize(String.t()) :: String.t()`.

- [ ] **Step 1: Write the failing test**

Create `test/deckex/cards/name_test.exs`:

```elixir
defmodule Deckex.Cards.NameTest do
  use ExUnit.Case, async: true

  alias Deckex.Cards.Name

  doctest Deckex.Cards.Name

  describe "normalize/1" do
    test "downcases" do
      assert Name.normalize("Sol Ring") == "sol ring"
    end

    test "keeps only the front face of a double-faced name" do
      assert Name.normalize("Agadeem's Awakening // Agadeem, the Undercrypt") ==
               "agadeem's awakening"
    end

    test "resolves the front-face-only spelling to the same key" do
      full = Name.normalize("Agadeem's Awakening // Agadeem, the Undercrypt")
      front_only = Name.normalize("Agadeem's Awakening")

      assert full == front_only
    end

    test "strips a trailing set code and collector number" do
      assert Name.normalize("Cultivate (M21) 177") == "cultivate"
      assert Name.normalize("Sol Ring (LTC)") == "sol ring"
    end

    test "strips accents so typed names match" do
      assert Name.normalize("Juzám Djinn") == "juzam djinn"
      assert Name.normalize("Márton Stromgald") == "marton stromgald"
    end

    test "trims surrounding whitespace" do
      assert Name.normalize("  Sol Ring  ") == "sol ring"
    end

    test "leaves apostrophes and commas alone — they are part of the name" do
      assert Name.normalize("Gaea's Cradle") == "gaea's cradle"
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/deckex/cards/name_test.exs`
Expected: FAIL — `module Deckex.Cards.Name is not available`.

- [ ] **Step 3: Write the implementation**

Create `lib/deckex/cards/name.ex`:

```elixir
defmodule Deckex.Cards.Name do
  @moduledoc """
  Card-name normalization.

  The same card reaches us written several ways: `Cultivate`,
  `Cultivate (M21) 177`, `Agadeem's Awakening`, and
  `Agadeem's Awakening // Agadeem, the Undercrypt` all mean one card.
  `normalize/1` collapses them into the single key stored in
  `cards.name_normalized`, so a decklist line and a Scryfall response resolve to
  the same row.
  """

  # Combining diacritical marks, left behind by NFD decomposition.
  @combining_marks ~r/[\x{0300}-\x{036F}]/u

  # A trailing " (SET) 123" / " (SET)" printed by most decklist exporters.
  @set_code ~r/\s*\([^)]*\)\s*\d*\s*$/

  @doc """
  Normalizes a card name to its lookup key: front face only, no set code or
  collector number, accent-stripped, downcased, trimmed.

      iex> Deckex.Cards.Name.normalize("Agadeem's Awakening // Agadeem, the Undercrypt")
      "agadeem's awakening"

      iex> Deckex.Cards.Name.normalize("Cultivate (M21) 177")
      "cultivate"
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(name) when is_binary(name) do
    name
    |> front_face()
    |> String.replace(@set_code, "")
    |> strip_accents()
    |> String.downcase()
    |> String.trim()
  end

  defp front_face(name), do: name |> String.split("//") |> hd()

  defp strip_accents(name) do
    name
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(@combining_marks, "")
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/deckex/cards/name_test.exs`
Expected: PASS — 7 tests plus 2 doctests.

- [ ] **Step 5: Run the gate and commit**

```bash
mix lint && git add lib/deckex/cards/name.ex test/deckex/cards/name_test.exs
git commit -m "feat: normalize card names to a single lookup key"
```

---

### Task 4: The `cards` table and schema

**Files:**
- Create: `priv/repo/migrations/<timestamp>_create_cards.exs`
- Create: `lib/deckex/cards/card.ex`
- Create: `test/support/factory.ex`
- Modify: `test/support/data_case.ex` (import the factory)
- Test: `test/deckex/cards/card_test.exs`

**Interfaces:**
- Consumes: `use Deckex.Schema` (Task 2), `Deckex.Cards.Name.normalize/1` (Task 3).
- Produces:
  - `%Deckex.Cards.Card{}` with fields `:id, :oracle_id, :scryfall_id, :name,
    :name_normalized, :mana_cost, :cmc, :type_line, :oracle_text, :colors,
    :color_identity, :produced_mana, :keywords, :edhrec_rank, :rarity, :layout,
    :card_faces, :image_normal_url, :image_art_crop_url, :commander_legal,
    :price_usd, :prices_updated_at, :scryfall_uri, :fetched_at`.
  - `Deckex.Cards.Card.changeset(%Card{}, map()) :: Ecto.Changeset.t()`
  - `Deckex.Factory.card_factory/0` building a valid card.

- [ ] **Step 1: Generate the migration**

```bash
mix ecto.gen.migration create_cards
```

Write its contents:

```elixir
defmodule Deckex.Repo.Migrations.CreateCards do
  use Ecto.Migration

  def change do
    create table(:cards, primary_key: false) do
      add :id, :uuid, primary_key: true

      # oracle_id is the business key: one row per distinct card, NOT per
      # printing. scryfall_id is only the printing we happened to pull the
      # image from.
      add :oracle_id, :uuid, null: false
      add :scryfall_id, :uuid, null: false

      add :name, :string, null: false
      add :name_normalized, :string, null: false
      add :mana_cost, :string
      add :cmc, :decimal, null: false
      add :type_line, :string, null: false
      add :oracle_text, :text
      add :colors, {:array, :string}, null: false, default: []
      add :color_identity, {:array, :string}, null: false, default: []
      add :produced_mana, {:array, :string}, null: false, default: []
      add :keywords, {:array, :string}, null: false, default: []
      add :edhrec_rank, :integer
      add :rarity, :string
      add :layout, :string, null: false
      add :card_faces, {:array, :map}, null: false, default: []
      add :image_normal_url, :string
      add :image_art_crop_url, :string
      add :commander_legal, :boolean, null: false, default: false

      # Price is the one mutable field on an otherwise immutable record. It is
      # advisory only — refreshed opportunistically, never trusted for logic.
      add :price_usd, :decimal
      add :prices_updated_at, :utc_datetime

      add :scryfall_uri, :string
      add :fetched_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cards, [:oracle_id])
    create unique_index(:cards, [:name_normalized])
    create index(:cards, [:edhrec_rank])
  end
end
```

- [ ] **Step 2: Write the failing test**

Create `test/deckex/cards/card_test.exs`:

```elixir
defmodule Deckex.Cards.CardTest do
  use Deckex.DataCase, async: true

  alias Deckex.Cards.Card

  defp valid_attrs do
    %{
      oracle_id: Ecto.UUID.generate(),
      scryfall_id: Ecto.UUID.generate(),
      name: "Sol Ring",
      name_normalized: "sol ring",
      mana_cost: "{1}",
      cmc: Decimal.new("1.0"),
      type_line: "Artifact",
      oracle_text: "{T}: Add {C}{C}.",
      layout: "normal",
      produced_mana: ["C"],
      commander_legal: true,
      fetched_at: DateTime.utc_now(:second)
    }
  end

  describe "changeset/2" do
    test "accepts a complete card" do
      assert %Ecto.Changeset{valid?: true} = Card.changeset(%Card{}, valid_attrs())
    end

    test "requires the identifying and structural fields" do
      errors = %Card{} |> Card.changeset(%{}) |> errors_on()

      for field <- [
            :oracle_id,
            :scryfall_id,
            :name,
            :name_normalized,
            :cmc,
            :type_line,
            :layout,
            :fetched_at
          ] do
        assert %{^field => ["can't be blank"]} = errors
      end
    end

    test "rejects a second card with the same oracle_id" do
      attrs = valid_attrs()
      assert {:ok, _} = %Card{} |> Card.changeset(attrs) |> Repo.insert()

      duplicate =
        attrs
        |> Map.put(:name, "Sol Ring (reprint)")
        |> Map.put(:name_normalized, "sol ring reprint")
        |> Map.put(:scryfall_id, Ecto.UUID.generate())

      assert {:error, changeset} = %Card{} |> Card.changeset(duplicate) |> Repo.insert()
      assert %{oracle_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "rejects a second card with the same normalized name" do
      assert {:ok, _} = %Card{} |> Card.changeset(valid_attrs()) |> Repo.insert()

      duplicate =
        valid_attrs()
        |> Map.put(:oracle_id, Ecto.UUID.generate())
        |> Map.put(:scryfall_id, Ecto.UUID.generate())

      assert {:error, changeset} = %Card{} |> Card.changeset(duplicate) |> Repo.insert()
      assert %{name_normalized: ["has already been taken"]} = errors_on(changeset)
    end

    test "stores double-faced card faces as a list of maps" do
      attrs =
        valid_attrs()
        |> Map.put(:layout, "modal_dfc")
        |> Map.put(:card_faces, [
          %{"name" => "Agadeem's Awakening", "mana_cost" => "{X}{B}{B}{B}"},
          %{"name" => "Agadeem, the Undercrypt", "mana_cost" => ""}
        ])

      assert {:ok, card} = %Card{} |> Card.changeset(attrs) |> Repo.insert()
      assert [%{"name" => "Agadeem's Awakening"}, %{"name" => _}] = card.card_faces
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `mix test test/deckex/cards/card_test.exs`
Expected: FAIL — `module Deckex.Cards.Card is not available`.

- [ ] **Step 4: Write the schema**

Create `lib/deckex/cards/card.ex`:

```elixir
defmodule Deckex.Cards.Card do
  @moduledoc """
  A Magic card, cached from Scryfall.

  Stored at the **oracle** level: one row per distinct card, keyed on
  `oracle_id`, not one row per printing. Deck analysis does not care which
  printing of Sol Ring you own, so `scryfall_id` is retained only as the
  representative printing the image came from.

  Cards are effectively immutable. The exception is `price_usd`, refreshed
  opportunistically and treated as advisory.
  """
  use Deckex.Schema

  import Ecto.Changeset

  @fields ~w(oracle_id scryfall_id name name_normalized mana_cost cmc type_line
             oracle_text colors color_identity produced_mana keywords edhrec_rank
             rarity layout card_faces image_normal_url image_art_crop_url
             commander_legal price_usd prices_updated_at scryfall_uri fetched_at)a

  @required ~w(oracle_id scryfall_id name name_normalized cmc type_line layout
               fetched_at)a

  @type t :: %__MODULE__{}

  schema "cards" do
    field :oracle_id, Ecto.UUID
    field :scryfall_id, Ecto.UUID
    field :name, :string
    field :name_normalized, :string
    field :mana_cost, :string
    field :cmc, :decimal
    field :type_line, :string
    field :oracle_text, :string
    field :colors, {:array, :string}, default: []
    field :color_identity, {:array, :string}, default: []
    field :produced_mana, {:array, :string}, default: []
    field :keywords, {:array, :string}, default: []
    field :edhrec_rank, :integer
    field :rarity, :string
    field :layout, :string
    field :card_faces, {:array, :map}, default: []
    field :image_normal_url, :string
    field :image_art_crop_url, :string
    field :commander_legal, :boolean, default: false
    field :price_usd, :decimal
    field :prices_updated_at, :utc_datetime
    field :scryfall_uri, :string
    field :fetched_at, :utc_datetime

    timestamps()
  end

  @doc "Builds a changeset from Scryfall-derived attributes."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(card, attrs) do
    card
    |> cast(attrs, @fields)
    |> validate_required(@required)
    |> unique_constraint(:oracle_id)
    |> unique_constraint(:name_normalized)
  end
end
```

- [ ] **Step 5: Migrate and run the test**

```bash
mix ecto.migrate && mix test test/deckex/cards/card_test.exs
```

Expected: migration applied, 5 tests PASS.

- [ ] **Step 6: Add the test factory**

Create `test/support/factory.ex`:

```elixir
defmodule Deckex.Factory do
  @moduledoc "ExMachina factories. See https://hexdocs.pm/ex_machina."
  use ExMachina.Ecto, repo: Deckex.Repo

  alias Deckex.Cards.Card
  alias Deckex.Cards.Name

  def card_factory do
    name = sequence(:card_name, &"Test Card #{&1}")

    %Card{
      oracle_id: Ecto.UUID.generate(),
      scryfall_id: Ecto.UUID.generate(),
      name: name,
      name_normalized: Name.normalize(name),
      mana_cost: "{2}{G}",
      cmc: Decimal.new("3.0"),
      type_line: "Sorcery",
      oracle_text: "Draw a card.",
      colors: ["G"],
      color_identity: ["G"],
      produced_mana: [],
      keywords: [],
      layout: "normal",
      card_faces: [],
      commander_legal: true,
      fetched_at: DateTime.utc_now(:second)
    }
  end
end
```

Verify `elixirc_paths(:test)` in `mix.exs` includes `"test/support"` — the
Phoenix generator adds this. If missing, add it.

The generated `Deckex.DataCase` does not know about the factory, so `insert/2`
would be undefined in every test that uses it. In `test/support/data_case.ex`,
add `import Deckex.Factory` to the `quote` block inside `__using__`, next to the
existing imports:

```elixir
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Deckex.DataCase
      import Deckex.Factory
```

- [ ] **Step 7: Run the full suite and the gate, then commit**

```bash
mix test && mix lint
```

Expected: all green.

```bash
git add priv/repo/migrations lib/deckex/cards/card.ex test/support/factory.ex test/deckex/cards/card_test.exs
git commit -m "feat: add cards table and schema

Oracle-level storage: one row per distinct card keyed on oracle_id, not one
per printing."
```

---

### Task 5: Scryfall mapper — translating card JSON, including double-faced cards

This is the task where the real complexity lives. On `modal_dfc` / `transform` /
`split` / `adventure` layouts, Scryfall puts `mana_cost`, `colors` and
`image_uris` **on the faces**, leaving them absent at the top level — while
`cmc`, `type_line`, `color_identity` and `produced_mana` stay at the top.
Verified against the live API on 2026-08-13.

**Files:**
- Create: `test/support/fixtures/scryfall/*.json` (5 files)
- Create: `test/support/scryfall_fixture.ex`
- Create: `lib/deckex/cards/scryfall_mapper.ex`
- Test: `test/deckex/cards/scryfall_mapper_test.exs`

**Interfaces:**
- Consumes: `Deckex.Cards.Name.normalize/1` (Task 3), `Deckex.Cards.Card.changeset/2` (Task 4).
- Produces: `Deckex.Cards.ScryfallMapper.to_attrs(map()) :: map()` returning a
  map with exactly the keys `Card.changeset/2` casts.
- Produces: `Deckex.ScryfallFixture.load!(String.t()) :: map()`.

- [ ] **Step 1: Download the fixtures from the live API**

These are real responses, committed so tests never touch the network.

```bash
mkdir -p test/support/fixtures/scryfall
UA='deckex/0.1 (personal deck analysis tool)'
fetch() {
  curl -sS -H "User-Agent: $UA" -H 'Accept: application/json' \
    --get --data-urlencode "exact=$1" \
    'https://api.scryfall.com/cards/named' -o "test/support/fixtures/scryfall/$2.json"
  sleep 0.5
}
fetch 'Sol Ring' sol_ring
fetch 'Cultivate' cultivate
fetch 'Command Tower' command_tower
fetch 'Counterspell' counterspell
fetch "Agadeem's Awakening // Agadeem, the Undercrypt" agadeems_awakening
ls -la test/support/fixtures/scryfall/
```

Expected: 5 JSON files, each a few KB. Verify the MDFC one has no top-level
`image_uris`:

```bash
python3 -c "import json;c=json.load(open('test/support/fixtures/scryfall/agadeems_awakening.json'));print('top image_uris:', bool(c.get('image_uris')), '| faces:', len(c.get('card_faces',[])))"
```

Expected: `top image_uris: False | faces: 2`

- [ ] **Step 2: Write the fixture loader**

Create `test/support/scryfall_fixture.ex`:

```elixir
defmodule Deckex.ScryfallFixture do
  @moduledoc """
  Loads real Scryfall card responses committed under
  `test/support/fixtures/scryfall/`. Using real payloads rather than
  hand-written maps is deliberate: the shape of a double-faced card is exactly
  the kind of detail a hand-written fixture gets wrong.
  """

  @dir Path.join([__DIR__, "fixtures", "scryfall"])

  @doc "Loads a fixture by basename, e.g. `load!(\"sol_ring\")`."
  @spec load!(String.t()) :: map()
  def load!(name) do
    @dir
    |> Path.join("#{name}.json")
    |> File.read!()
    |> Jason.decode!()
  end
end
```

- [ ] **Step 3: Write the failing test**

Create `test/deckex/cards/scryfall_mapper_test.exs`:

```elixir
defmodule Deckex.Cards.ScryfallMapperTest do
  use ExUnit.Case, async: true

  alias Deckex.Cards.Card
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.ScryfallFixture

  describe "to_attrs/1 on a normal card" do
    setup do
      %{attrs: ScryfallFixture.load!("sol_ring") |> ScryfallMapper.to_attrs()}
    end

    test "maps identity and cost", %{attrs: attrs} do
      assert attrs.name == "Sol Ring"
      assert attrs.name_normalized == "sol ring"
      assert attrs.mana_cost == "{1}"
      assert Decimal.equal?(attrs.cmc, Decimal.new("1"))
      assert attrs.type_line == "Artifact"
      assert attrs.layout == "normal"
    end

    test "maps the mana it produces", %{attrs: attrs} do
      assert attrs.produced_mana == ["C"]
    end

    test "maps commander legality and the EDHREC rank", %{attrs: attrs} do
      assert attrs.commander_legal == true
      assert is_integer(attrs.edhrec_rank)
    end

    test "maps images from the top level", %{attrs: attrs} do
      assert attrs.image_normal_url =~ "scryfall"
      assert attrs.image_art_crop_url =~ "scryfall"
    end

    test "produces attributes a Card changeset accepts", %{attrs: attrs} do
      assert %Ecto.Changeset{valid?: true} = Card.changeset(%Card{}, attrs)
    end
  end

  describe "to_attrs/1 on a land with an empty mana cost" do
    test "normalizes the empty string to nil" do
      attrs = ScryfallFixture.load!("command_tower") |> ScryfallMapper.to_attrs()

      assert attrs.mana_cost == nil
      assert attrs.type_line == "Land"
      assert Enum.sort(attrs.produced_mana) == ["B", "G", "R", "U", "W"]
    end
  end

  describe "to_attrs/1 on a card whose ramp is invisible to produced_mana" do
    test "keeps the oracle text that is the only ramp signal" do
      attrs = ScryfallFixture.load!("cultivate") |> ScryfallMapper.to_attrs()

      assert attrs.produced_mana == []
      assert attrs.oracle_text =~ "Search your library"
      assert attrs.oracle_text =~ "onto the battlefield"
    end
  end

  describe "to_attrs/1 on a modal double-faced card" do
    setup do
      %{attrs: ScryfallFixture.load!("agadeems_awakening") |> ScryfallMapper.to_attrs()}
    end

    test "takes the mana cost from the front face, since the top level has none",
         %{attrs: attrs} do
      assert attrs.mana_cost == "{X}{B}{B}{B}"
    end

    test "takes colors from the front face, since the top level has none", %{attrs: attrs} do
      assert attrs.colors == ["B"]
    end

    test "takes images from the front face, since the top level has none", %{attrs: attrs} do
      assert attrs.image_normal_url =~ "scryfall"
      assert attrs.image_art_crop_url =~ "scryfall"
    end

    test "keeps cmc, type_line and produced_mana from the top level", %{attrs: attrs} do
      assert Decimal.equal?(attrs.cmc, Decimal.new("3"))
      assert attrs.type_line == "Sorcery // Land"
      assert attrs.produced_mana == ["B"]
    end

    test "normalizes the name to the front face only", %{attrs: attrs} do
      assert attrs.name_normalized == "agadeem's awakening"
    end

    test "retains both faces for later analysis", %{attrs: attrs} do
      assert [%{"name" => "Agadeem's Awakening"}, %{"name" => "Agadeem, the Undercrypt"}] =
               attrs.card_faces
    end

    test "produces attributes a Card changeset accepts", %{attrs: attrs} do
      assert %Ecto.Changeset{valid?: true} = Card.changeset(%Card{}, attrs)
    end
  end

  describe "to_attrs/1 price handling" do
    test "maps the USD price as a decimal and stamps when it was read" do
      attrs = ScryfallFixture.load!("cultivate") |> ScryfallMapper.to_attrs()

      assert %Decimal{} = attrs.price_usd
      assert %DateTime{} = attrs.prices_updated_at
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `mix test test/deckex/cards/scryfall_mapper_test.exs`
Expected: FAIL — `module Deckex.Cards.ScryfallMapper is not available`.

- [ ] **Step 5: Write the mapper**

Create `lib/deckex/cards/scryfall_mapper.ex`:

```elixir
defmodule Deckex.Cards.ScryfallMapper do
  @moduledoc """
  Translates a Scryfall card object into `Deckex.Cards.Card` attributes.

  Double-faced layouts are the reason this module exists. On `modal_dfc`,
  `transform`, `split` and `adventure` cards, Scryfall omits `mana_cost`,
  `colors` and `image_uris` at the top level and puts them on the faces — while
  `cmc`, `type_line`, `color_identity` and `produced_mana` stay at the top.
  Reading the wrong level yields a card with no cost and no image, which is
  exactly the sort of bug that only shows up on the handful of MDFCs in a deck.
  Every read below falls back from the top level to the front face.
  """

  alias Deckex.Cards.Name

  @doc "Maps a Scryfall card object to attributes for `Card.changeset/2`."
  @spec to_attrs(map()) :: map()
  def to_attrs(card) when is_map(card) do
    front = front_face(card)
    images = card["image_uris"] || front["image_uris"] || %{}
    now = DateTime.utc_now(:second)

    %{
      oracle_id: card["oracle_id"] || front["oracle_id"],
      scryfall_id: card["id"],
      name: card["name"],
      name_normalized: Name.normalize(card["name"]),
      mana_cost: blank_to_nil(card["mana_cost"] || front["mana_cost"]),
      cmc: to_decimal(card["cmc"]),
      type_line: card["type_line"] || front["type_line"],
      oracle_text: card["oracle_text"] || front["oracle_text"],
      colors: card["colors"] || front["colors"] || [],
      color_identity: card["color_identity"] || [],
      produced_mana: card["produced_mana"] || [],
      keywords: card["keywords"] || [],
      edhrec_rank: card["edhrec_rank"],
      rarity: card["rarity"],
      layout: card["layout"],
      card_faces: card["card_faces"] || [],
      image_normal_url: images["normal"],
      image_art_crop_url: images["art_crop"],
      commander_legal: get_in(card, ["legalities", "commander"]) == "legal",
      price_usd: to_decimal(get_in(card, ["prices", "usd"])),
      prices_updated_at: now,
      scryfall_uri: card["scryfall_uri"],
      fetched_at: now
    }
  end

  defp front_face(%{"card_faces" => [front | _rest]}) when is_map(front), do: front
  defp front_face(_card), do: %{}

  # A land's mana_cost is "" rather than absent; store nil so "has no cost" is
  # one value everywhere instead of two.
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp to_decimal(nil), do: nil
  defp to_decimal(value) when is_binary(value), do: Decimal.new(value)
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)
end
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `mix test test/deckex/cards/scryfall_mapper_test.exs`
Expected: PASS — 14 tests.

- [ ] **Step 7: Run the gate and commit**

```bash
mix lint && git add lib/deckex/cards/scryfall_mapper.ex test/support/scryfall_fixture.ex test/support/fixtures test/deckex/cards/scryfall_mapper_test.exs
git commit -m "feat: map Scryfall card objects, handling double-faced layouts

On MDFC/transform/split/adventure cards, mana_cost, colors and image_uris live
on the faces, not the top level. Verified against the live API."
```

---

### Task 6: The Scryfall port

**Files:**
- Create: `lib/deckex/scryfall/client.ex` (behaviour)
- Create: `lib/deckex/scryfall.ex` (facade)
- Create: `lib/deckex/scryfall/http.ex` (adapter)
- Create: `test/support/mocks.ex`
- Modify: `config/config.exs`, `config/test.exs`
- Test: `test/deckex/scryfall/http_test.exs`

**Interfaces:**
- Consumes: `Deckex.Error.new/3` (Task 2).
- Produces:
  - `@callback fetch_by_names([String.t()]) :: {:ok, %{found: [map()], not_found: [String.t()]}} | {:error, Deckex.Error.t()}`
  - `Deckex.Scryfall.fetch_by_names/1` — the facade every caller uses.
  - `Deckex.Scryfall.Mock` — the Mox mock, wired as the adapter in test.

- [ ] **Step 1: Write the behaviour**

Create `lib/deckex/scryfall/client.ex`:

```elixir
defmodule Deckex.Scryfall.Client do
  @moduledoc """
  Port for the Scryfall API. The real adapter is `Deckex.Scryfall.Http`; tests
  use `Deckex.Scryfall.Mock`. Callers go through the `Deckex.Scryfall` facade
  rather than naming an adapter directly.
  """

  @doc """
  Resolves card names to Scryfall card objects.

  Returns the raw objects that resolved plus the names that did not, so the
  caller can report unresolved cards by name instead of silently dropping them.
  """
  @callback fetch_by_names([String.t()]) ::
              {:ok, %{found: [map()], not_found: [String.t()]}}
              | {:error, Deckex.Error.t()}
end
```

- [ ] **Step 2: Write the facade**

Create `lib/deckex/scryfall.ex`:

```elixir
defmodule Deckex.Scryfall do
  @moduledoc """
  Facade for the Scryfall port. Resolves the configured adapter once at compile
  time so the domain never names a concrete implementation.
  """
  @behaviour Deckex.Scryfall.Client

  @adapter Application.compile_env(
             :deckex,
             [Deckex.Scryfall.Client, :adapter],
             Deckex.Scryfall.Http
           )

  @impl Deckex.Scryfall.Client
  defdelegate fetch_by_names(names), to: @adapter
end
```

- [ ] **Step 3: Write the failing adapter test**

Create `test/deckex/scryfall/http_test.exs`:

```elixir
defmodule Deckex.Scryfall.HttpTest do
  # async: false — Req.Test stubs are process-owned and the throttle config is
  # global.
  use ExUnit.Case, async: false

  alias Deckex.Error
  alias Deckex.Scryfall.Http

  describe "fetch_by_names/1" do
    test "returns empty results without calling out for an empty list" do
      assert {:ok, %{found: [], not_found: []}} = Http.fetch_by_names([])
    end

    test "posts names as identifiers and returns the found cards" do
      Req.Test.stub(Http, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"identifiers" => [%{"name" => "Sol Ring"}]} = Jason.decode!(body)

        Req.Test.json(conn, %{"data" => [%{"name" => "Sol Ring"}], "not_found" => []})
      end)

      assert {:ok, %{found: [%{"name" => "Sol Ring"}], not_found: []}} =
               Http.fetch_by_names(["Sol Ring"])
    end

    test "reports unresolved names by name" do
      Req.Test.stub(Http, fn conn ->
        Req.Test.json(conn, %{
          "data" => [],
          "not_found" => [%{"name" => "Not A Real Card"}]
        })
      end)

      assert {:ok, %{found: [], not_found: ["Not A Real Card"]}} =
               Http.fetch_by_names(["Not A Real Card"])
    end

    test "chunks into batches of 75, the endpoint's documented maximum" do
      Req.Test.stub(Http, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        %{"identifiers" => identifiers} = Jason.decode!(body)
        send(self(), {:batch, length(identifiers)})

        Req.Test.json(conn, %{"data" => [], "not_found" => []})
      end)

      names = Enum.map(1..80, &"Card #{&1}")
      assert {:ok, %{found: []}} = Http.fetch_by_names(names)

      assert_received {:batch, 75}
      assert_received {:batch, 5}
    end

    test "merges results across batches" do
      Req.Test.stub(Http, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        %{"identifiers" => identifiers} = Jason.decode!(body)
        found = Enum.map(identifiers, &%{"name" => &1["name"]})

        Req.Test.json(conn, %{"data" => found, "not_found" => []})
      end)

      names = Enum.map(1..80, &"Card #{&1}")
      assert {:ok, %{found: found}} = Http.fetch_by_names(names)
      assert length(found) == 80
    end

    test "turns a non-200 response into a domain error" do
      Req.Test.stub(Http, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)

      assert {:error, %Error{code: :scryfall_unavailable, details: %{status: 503}}} =
               Http.fetch_by_names(["Sol Ring"])
    end

    test "turns a transport failure into a domain error" do
      Req.Test.stub(Http, fn _conn -> raise Req.TransportError, reason: :econnrefused end)

      assert {:error, %Error{code: :scryfall_unavailable}} = Http.fetch_by_names(["Sol Ring"])
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `mix test test/deckex/scryfall/http_test.exs`
Expected: FAIL — `module Deckex.Scryfall.Http is not available`.

- [ ] **Step 5: Write the adapter**

Create `lib/deckex/scryfall/http.ex`:

```elixir
defmodule Deckex.Scryfall.Http do
  @moduledoc """
  Scryfall adapter over `Req`.

  Two published limits shape this module. `POST /cards/collection` accepts at
  most **75 identifiers per request**, and that endpoint is capped at **2
  requests/second** — tighter than the 10/s the rest of the API allows. So names
  are chunked by 75 and every request after the first waits out the throttle
  window. A 100-card Commander deck therefore costs two requests.

  Scryfall also requires a descriptive `User-Agent` and an explicit `Accept`
  header on every request; both are set here.
  """
  @behaviour Deckex.Scryfall.Client

  alias Deckex.Error

  @endpoint "https://api.scryfall.com/cards/collection"
  @batch_size 75
  @throttle_ms 500
  @user_agent "deckex/0.1 (personal Commander deck analysis tool)"

  @impl Deckex.Scryfall.Client
  def fetch_by_names([]), do: {:ok, %{found: [], not_found: []}}

  def fetch_by_names(names) when is_list(names) do
    names
    |> Enum.chunk_every(@batch_size)
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{found: [], not_found: []}}, &fetch_batch/2)
  end

  defp fetch_batch({chunk, index}, {:ok, acc}) do
    if index > 0, do: Process.sleep(throttle_ms())

    case post_collection(chunk) do
      {:ok, batch} -> {:cont, {:ok, merge(acc, batch)}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp post_collection(names) do
    identifiers = Enum.map(names, &%{name: &1})

    case Req.post(request(), json: %{identifiers: identifiers}) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, %{found: body["data"] || [], not_found: not_found_names(body)}}

      {:ok, %Req.Response{status: status}} ->
        {:error,
         Error.new(
           :scryfall_unavailable,
           "A Scryfall respondeu #{status}. Tenta de novo em instantes.",
           %{status: status}
         )}

      {:error, reason} ->
        {:error,
         Error.new(
           :scryfall_unavailable,
           "Não consegui falar com a Scryfall.",
           %{reason: inspect(reason)}
         )}
    end
  end

  defp not_found_names(body) do
    body
    |> Map.get("not_found", [])
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
  end

  defp merge(acc, batch) do
    %{
      found: acc.found ++ batch.found,
      not_found: acc.not_found ++ batch.not_found
    }
  end

  defp request do
    [
      url: @endpoint,
      headers: [{"user-agent", @user_agent}, {"accept", "application/json"}],
      receive_timeout: 15_000,
      retry: false
    ]
    |> Keyword.merge(config(:req_options, []))
    |> Req.new()
  end

  defp throttle_ms, do: config(:throttle_ms, @throttle_ms)

  defp config(key, default) do
    :deckex |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
```

- [ ] **Step 6: Wire the adapter selection and the Mox mock**

In `config/config.exs`, before the endpoint configuration, add:

```elixir
# Integration ports (ports & adapters). Tests override these with Mox mocks.
config :deckex, Deckex.Scryfall.Client, adapter: Deckex.Scryfall.Http
```

Create `test/support/mocks.ex`:

```elixir
# Mox mocks for the integration ports. Each is selected as the adapter in
# config/test.exs so the domain talks to the mock instead of the real service.
Mox.defmock(Deckex.Scryfall.Mock, for: Deckex.Scryfall.Client)
```

In `config/test.exs`, add:

```elixir
# Integration ports → Mox mocks (see test/support/mocks.ex).
config :deckex, Deckex.Scryfall.Client, adapter: Deckex.Scryfall.Mock

# When the real adapter is exercised directly (test/deckex/scryfall/http_test.exs)
# it routes through Req.Test instead of the network, and does not really sleep.
config :deckex, Deckex.Scryfall.Http,
  req_options: [plug: {Req.Test, Deckex.Scryfall.Http}],
  throttle_ms: 0
```

Mox needs no bootstrapping in `test_helper.exs` — it starts as an OTP
application. Individual test modules opt in with `import Mox` and
`setup :verify_on_exit!`.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `mix test test/deckex/scryfall/http_test.exs`
Expected: PASS — 7 tests.

- [ ] **Step 8: Run the gate and commit**

```bash
mix test && mix lint
git add lib/deckex/scryfall.ex lib/deckex/scryfall test/support/mocks.ex test/deckex/scryfall config test/test_helper.exs
git commit -m "feat: add Scryfall port with batching and throttling

75 identifiers per request, 2 req/s — the documented limits of
POST /cards/collection. Tests route through Req.Test, never the network."
```

---

### Task 7: `Deckex.Cards.resolve_names/1` — the catalogue

The payoff: hand it a list of card names, get back `Card` structs. Cards already
known are read from Postgres; the rest are fetched from Scryfall in one batched
call and inserted. This is what every later import will call.

**Files:**
- Create: `lib/deckex/cards.ex` (context)
- Create: `lib/deckex/cards/card_query.ex` (all reads)
- Test: `test/deckex/cards_test.exs`

**Interfaces:**
- Consumes: `Deckex.Cards.Card` (Task 4), `Deckex.Cards.Name.normalize/1` (Task 3),
  `Deckex.Cards.ScryfallMapper.to_attrs/1` (Task 5), `Deckex.Scryfall.fetch_by_names/1` (Task 6).
- Produces:
  - `Deckex.Cards.resolve_names([String.t()]) :: {:ok, %{cards: [Card.t()], not_found: [String.t()]}} | {:error, Deckex.Error.t()}`
  - `Deckex.Cards.CardQuery.list_by_normalized_names([String.t()]) :: [Card.t()]`
  - `Deckex.Cards.CardQuery.get_by_name(String.t()) :: Card.t() | nil`

- [ ] **Step 1: Write the failing test**

Create `test/deckex/cards_test.exs`:

```elixir
defmodule Deckex.CardsTest do
  use Deckex.DataCase, async: true

  import Mox

  alias Deckex.Cards
  alias Deckex.Error
  alias Deckex.ScryfallFixture

  setup :verify_on_exit!

  describe "resolve_names/1" do
    test "returns an empty result for an empty list without calling Scryfall" do
      assert {:ok, %{cards: [], not_found: []}} = Cards.resolve_names([])
    end

    test "reads a known card from the database without calling Scryfall" do
      card = insert(:card, name: "Sol Ring", name_normalized: "sol ring")

      assert {:ok, %{cards: [found], not_found: []}} = Cards.resolve_names(["Sol Ring"])
      assert found.id == card.id
    end

    test "matches a known card regardless of how the name is written" do
      insert(:card, name: "Cultivate", name_normalized: "cultivate")

      assert {:ok, %{cards: [_], not_found: []}} = Cards.resolve_names(["Cultivate (M21) 177"])
    end

    test "fetches an unknown card from Scryfall and stores it" do
      expect(Deckex.Scryfall.Mock, :fetch_by_names, fn ["Sol Ring"] ->
        {:ok, %{found: [ScryfallFixture.load!("sol_ring")], not_found: []}}
      end)

      assert {:ok, %{cards: [card], not_found: []}} = Cards.resolve_names(["Sol Ring"])
      assert card.name == "Sol Ring"
      assert card.produced_mana == ["C"]

      # Now cached: a second call must not hit the port again. verify_on_exit!
      # fails the test if the mock is called a second time.
      assert {:ok, %{cards: [_]}} = Cards.resolve_names(["Sol Ring"])
    end

    test "asks Scryfall only for the names it does not already have" do
      insert(:card, name: "Sol Ring", name_normalized: "sol ring")

      expect(Deckex.Scryfall.Mock, :fetch_by_names, fn names ->
        assert names == ["Cultivate"]
        {:ok, %{found: [ScryfallFixture.load!("cultivate")], not_found: []}}
      end)

      assert {:ok, %{cards: cards, not_found: []}} =
               Cards.resolve_names(["Sol Ring", "Cultivate"])

      assert length(cards) == 2
    end

    test "reports names Scryfall could not resolve instead of dropping them" do
      expect(Deckex.Scryfall.Mock, :fetch_by_names, fn _names ->
        {:ok, %{found: [], not_found: ["Not A Real Card"]}}
      end)

      assert {:ok, %{cards: [], not_found: ["Not A Real Card"]}} =
               Cards.resolve_names(["Not A Real Card"])
    end

    test "deduplicates repeated names before calling the port" do
      expect(Deckex.Scryfall.Mock, :fetch_by_names, fn names ->
        assert names == ["Sol Ring"]
        {:ok, %{found: [ScryfallFixture.load!("sol_ring")], not_found: []}}
      end)

      assert {:ok, %{cards: [_single]}} = Cards.resolve_names(["Sol Ring", "Sol Ring"])
    end

    test "stores a double-faced card with the front face's cost" do
      expect(Deckex.Scryfall.Mock, :fetch_by_names, fn _names ->
        {:ok, %{found: [ScryfallFixture.load!("agadeems_awakening")], not_found: []}}
      end)

      assert {:ok, %{cards: [card]}} = Cards.resolve_names(["Agadeem's Awakening"])
      assert card.mana_cost == "{X}{B}{B}{B}"
      assert card.type_line == "Sorcery // Land"
    end

    test "upserts instead of duplicating when the oracle_id already exists" do
      fixture = ScryfallFixture.load!("sol_ring")

      # Same card, stored under a stale normalized name: the name lookup misses,
      # so we go to the port and then collide on oracle_id on the way in.
      insert(:card,
        oracle_id: fixture["oracle_id"],
        name: "Sol Ring (stale)",
        name_normalized: "sol ring stale",
        price_usd: nil
      )

      expect(Deckex.Scryfall.Mock, :fetch_by_names, fn ["Sol Ring"] ->
        {:ok, %{found: [fixture], not_found: []}}
      end)

      assert {:ok, %{cards: [card], not_found: []}} = Cards.resolve_names(["Sol Ring"])

      assert card.oracle_id == fixture["oracle_id"]
      # The upsert refreshed the advisory price rather than creating a second row.
      assert card.price_usd != nil
      assert Repo.aggregate(Deckex.Cards.Card, :count) == 1
    end

    test "propagates a Scryfall failure as a domain error" do
      expect(Deckex.Scryfall.Mock, :fetch_by_names, fn _names ->
        {:error, Error.new(:scryfall_unavailable, "fora do ar")}
      end)

      assert {:error, %Error{code: :scryfall_unavailable}} = Cards.resolve_names(["Sol Ring"])
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/deckex/cards_test.exs`
Expected: FAIL — `module Deckex.Cards is not available`.

- [ ] **Step 3: Write the query module**

Create `lib/deckex/cards/card_query.ex`:

```elixir
defmodule Deckex.Cards.CardQuery do
  @moduledoc """
  All reads of the card catalogue. Query logic lives here rather than in the
  context or an edge, so it is discoverable, reusable and unit-testable. Every
  function ends in a `Repo` call and returns data, never an `Ecto.Query`.
  """

  import Ecto.Query

  alias Deckex.Cards.Card
  alias Deckex.Cards.Name
  alias Deckex.Repo

  @doc "Lists the cards whose normalized names are in `names`."
  @spec list_by_normalized_names([String.t()]) :: [Card.t()]
  def list_by_normalized_names([]), do: []

  def list_by_normalized_names(names) when is_list(names) do
    Repo.all(from c in Card, where: c.name_normalized in ^names)
  end

  @doc "Fetches one card by any spelling of its name."
  @spec get_by_name(String.t()) :: Card.t() | nil
  def get_by_name(name) when is_binary(name) do
    Repo.get_by(Card, name_normalized: Name.normalize(name))
  end
end
```

- [ ] **Step 4: Write the context**

Create `lib/deckex/cards.ex`:

```elixir
defmodule Deckex.Cards do
  @moduledoc """
  The card catalogue: the local, permanent cache of Scryfall card data.

  `resolve_names/1` is the entry point every import uses. Cards already known
  are read from Postgres; only genuinely new ones cost a Scryfall request. Since
  a card is immutable and the catalogue is global, the cost of importing decks
  falls towards zero as the collection grows.
  """

  alias Deckex.Cards.Card
  alias Deckex.Cards.CardQuery
  alias Deckex.Cards.Name
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.Error
  alias Deckex.Repo
  alias Deckex.Scryfall

  defdelegate get_by_name(name), to: CardQuery
  defdelegate list_by_normalized_names(names), to: CardQuery

  @doc """
  Resolves card names to `Card` structs, fetching and caching whatever is
  missing.

  Returns the resolved cards plus the names Scryfall could not resolve — those
  are reported to the user by name, never silently dropped.
  """
  @spec resolve_names([String.t()]) ::
          {:ok, %{cards: [Card.t()], not_found: [String.t()]}} | {:error, Error.t()}
  def resolve_names([]), do: {:ok, %{cards: [], not_found: []}}

  def resolve_names(names) when is_list(names) do
    # Deduplicate on the normalized key, but keep one original spelling per key
    # — Scryfall is queried with a real name, not our lookup key.
    wanted = Enum.uniq_by(names, &Name.normalize/1)
    known = CardQuery.list_by_normalized_names(Enum.map(wanted, &Name.normalize/1))
    known_keys = MapSet.new(known, & &1.name_normalized)

    missing = Enum.reject(wanted, &MapSet.member?(known_keys, Name.normalize(&1)))

    with {:ok, %{found: found, not_found: not_found}} <- fetch_missing(missing),
         {:ok, inserted} <- insert_all(found) do
      {:ok, %{cards: known ++ inserted, not_found: not_found}}
    end
  end

  defp fetch_missing([]), do: {:ok, %{found: [], not_found: []}}
  defp fetch_missing(names), do: Scryfall.fetch_by_names(names)

  defp insert_all(scryfall_cards) do
    Enum.reduce_while(scryfall_cards, {:ok, []}, fn scryfall_card, {:ok, acc} ->
      case insert_card(scryfall_card) do
        {:ok, card} -> {:cont, {:ok, [card | acc]}}
        {:error, changeset} -> {:halt, invalid_card_error(scryfall_card, changeset)}
      end
    end)
    |> case do
      {:ok, cards} -> {:ok, Enum.reverse(cards)}
      {:error, _reason} = error -> error
    end
  end

  defp insert_card(scryfall_card) do
    attrs = ScryfallMapper.to_attrs(scryfall_card)

    %Card{}
    |> Card.changeset(attrs)
    # Upsert rather than plain insert, for two reasons. A concurrent import may
    # have inserted this card between our read and this write, and re-fetching a
    # card we already hold is the natural moment to refresh the advisory price
    # and the EDHREC rank — the only fields that legitimately change.
    #
    # Note `on_conflict: :nothing` would NOT work here: UUID primary keys are
    # generated client-side, so a skipped insert still returns a struct carrying
    # an id that was never written, and the caller would hold a phantom card.
    |> Repo.insert(
      on_conflict: {:replace, [:price_usd, :prices_updated_at, :edhrec_rank, :updated_at]},
      conflict_target: :oracle_id,
      returning: true
    )
  end

  defp invalid_card_error(scryfall_card, changeset) do
    {:error,
     Error.new(
       :cards_not_found,
       "A Scryfall devolveu uma carta que não consegui gravar.",
       %{name: scryfall_card["name"], errors: inspect(changeset.errors)}
     )}
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/deckex/cards_test.exs`
Expected: PASS — 10 tests.

- [ ] **Step 6: Verify against the real API once, manually**

This is the only step in the plan that touches the network, and it is a manual
sanity check rather than a test. It confirms the port, mapper and context agree
with reality.

```bash
MIX_ENV=dev mix run -e '
  {:ok, %{cards: cards, not_found: nf}} =
    Deckex.Cards.resolve_names(["Sol Ring", "Cultivate", "Agadeem'"'"'s Awakening"])

  Enum.each(cards, fn c ->
    IO.puts("#{c.name} | #{c.mana_cost} | cmc #{c.cmc} | #{c.type_line}")
  end)

  IO.inspect(nf, label: "not_found")
'
```

Expected output:

```
Sol Ring | {1} | cmc 1.0 | Artifact
Cultivate | {2}{G} | cmc 3.0 | Sorcery
Agadeem's Awakening | {X}{B}{B}{B} | cmc 3.0 | Sorcery // Land
not_found: []
```

Run it a second time and confirm it is instant — that is the cache working.

- [ ] **Step 7: Run the full suite and the gate, then commit**

```bash
mix test && mix lint
```

Expected: all green.

```bash
git add lib/deckex/cards.ex lib/deckex/cards/card_query.ex test/deckex/cards_test.exs
git commit -m "feat: resolve card names against a cached Scryfall catalogue

Known cards come from Postgres; only new ones cost a request. Unresolved
names are reported, never dropped."
```

---

### Task 8: Project documentation

**Files:**
- Create: `AGENTS.md`, `CLAUDE.md`, `README.md`
- Copy: `docs/playbook/` from beatgrid

**Interfaces:**
- Consumes: everything built above (it documents it).
- Produces: no code.

- [ ] **Step 1: Copy the architecture playbook**

```bash
mkdir -p docs/playbook
cp /Users/tavano/projects/beatgrid/docs/playbook/*.md docs/playbook/
ls docs/playbook/
```

Expected: 12 files, `00-README.md` through `11-libraries-and-tooling.md`.

- [ ] **Step 2: Write `AGENTS.md`**

Create `AGENTS.md`:

```markdown
# AGENTS.md — deckex conventions (ground truth)

The operational contract for anyone, human or AI, writing code here. It adopts
the **Elixir/Phoenix Architecture & Quality Playbook** in [`docs/playbook/`](docs/playbook/)
wholesale and records the project-specific decisions on top of it. When this
file and the playbook disagree, **this file wins**.

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
  `price_usd`, which is advisory.
- **Read the front face.** On `modal_dfc` / `transform` / `split` / `adventure`
  layouts, `mana_cost`, `colors` and `image_uris` live on the faces while `cmc`,
  `type_line` and `produced_mana` stay at the top. `ScryfallMapper` is the only
  place that knows this — do not re-derive it elsewhere.
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

`mix lint` must be green before every commit:
`format --check-formatted`, `deps.unlock --check-unused`, `credo --strict`,
`sobelow --config`, `dialyzer`.

`mix precommit` runs `compile --warnings-as-errors`, `deps.unlock --unused`,
`format`, `test`.

## Local setup

PostgreSQL runs in Docker on **host port 5435** (5432/5433/5434 belong to other
projects on this machine).

```bash
docker compose up -d
mix setup
mix phx.server
```
```

- [ ] **Step 3: Write `CLAUDE.md`**

Create `CLAUDE.md`:

```markdown
# CLAUDE.md

Read [`AGENTS.md`](AGENTS.md). It is the ground truth for this repository —
conventions, architecture, and the project-specific laws.

The design spec is [`docs/superpowers/specs/2026-08-13-deckex-design.md`](docs/superpowers/specs/2026-08-13-deckex-design.md).
The architecture playbook is [`docs/playbook/`](docs/playbook/).
```

- [ ] **Step 4: Write `README.md`**

Create `README.md`:

```markdown
# deckex

Análise de decks de Commander (EDH). Você importa a lista, o app mede a forma do
deck — curva, mana, interação, consistência — e leva esses números pra uma IA
com busca na web, que sugere o que cortar e o que colocar.

O app **não** decide se uma carta é boa. Ele mede o seu deck e deixa a IA, que
conhece o pool de cartas inteiro, fazer a parte de opinião.

## Rodando

Precisa de Elixir 1.19.5 / OTP 27 e Docker.

```bash
docker compose up -d   # Postgres na porta 5435
mix setup
mix phx.server
```

Abre http://localhost:4000.

## Importando um deck

**Colando a lista** é o caminho principal e funciona sempre, inclusive para
decks privados: no Moxfield, abra o deck → Export → copie → cole no app.

**Sync pela URL** está implementado, mas o Moxfield responde 403 (Cloudflare)
para clientes não aprovados. Se você conseguir um User-Agent aprovado com o
support@moxfield.com, cole ele em Ajustes e o sync passa a funcionar.

## Qualidade

```bash
mix lint       # format, credo --strict, sobelow, dialyzer
mix precommit  # compile --warnings-as-errors, format, test
```
```

- [ ] **Step 5: Commit**

```bash
git add AGENTS.md CLAUDE.md README.md docs/playbook
git commit -m "docs: add AGENTS.md, CLAUDE.md, README and the architecture playbook"
```

---

## What this plan delivers

At the end of Task 8, running `mix test && mix lint` is green and:

```elixir
Deckex.Cards.resolve_names(["Sol Ring", "Cultivate", "Agadeem's Awakening"])
```

returns three cached `Card` structs with correct costs, types, produced mana,
images, prices and EDHREC ranks — including the double-faced card — having spent
exactly one Scryfall request, and zero on every subsequent call.

## Next plans

| Plan | Spec milestone | Delivers |
|---|---|---|
| 2 | 3 | Role classification: the rule engine, then the AI residue behind the port |
| 3 | 4 | `Deckex.Decks`, the decklist parser, the Moxfield port, the import pipeline |
| 4 | 5 | `Deckex.Analysis` — the four lenses, the findings catalogue, the reference-deck regression test |
| 5 | 6 | `Deckex.Consults` — briefings, per-lens schemas, the Claude CLI port |
| 6 | 7 | The UI: design tokens, then Mesa → Deck → Lente → Consultas → Ajustes |
