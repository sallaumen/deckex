# Plano 6 — Ajustes e Escolha de Modelo

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the knobs editable — the Claude model, the Moxfield User-Agent,
the consult budget and every analysis baseline — and let one briefing be run
across several models so the best one can be chosen from evidence.

**Architecture:** `Deckex.Settings` is a typed key/value store: a registry
declares each key's type, default and options, so a setting is validated rather
than trusted. `Deckex.Analysis` stays pure — Settings *builds* a `%Baselines{}`
and the caller passes it in. A consult records the model it was asked for, so
`compare/3` can run one identical briefing across models.

**Tech Stack:** Elixir 1.19.5 / OTP 27, Ecto, Oban, LiveView, the `claude` CLI
(`fable` · `opus` · `sonnet` aliases).

**Spec:** `docs/superpowers/specs/2026-08-13-deckex-design.md` §3.5, §7.2, §9 —
this closes milestone 7's Ajustes screen.

## Global Constraints

- **Code is English; user-facing strings are pt-BR.** Card names never
  translated.
- **`Deckex.Analysis` stays pure.** It must never read Settings, the Repo or
  config. Baselines arrive as an argument.
- **Every aggregate is a triad**; edges never build Ecto queries.
- **Errors are data:** `{:ok, _}` / `{:error, %Deckex.Error{}}`.
- **A setting is validated against its registry entry**, never written blind.
- **No test performs network or subprocess I/O.**
- **`mix lint` green BEFORE every commit** — and the commit must be chained
  with `&&` so a red gate actually blocks it.

## File structure

| File | Responsibility |
|---|---|
| `lib/deckex/settings/setting.ex` | Schema: one key, one JSON value |
| `lib/deckex/settings/registry.ex` | The known keys: type, default, options, label |
| `lib/deckex/settings/setting_query.ex` | All reads |
| `lib/deckex/settings.ex` | Context: get, put, baselines, model |
| `lib/deckex_web/live/settings_live.ex` | The Ajustes screen |

---

### Task 1: The settings store

**Files:**
- Create: `priv/repo/migrations/<timestamp>_create_settings.exs`
- Create: `lib/deckex/settings/setting.ex`
- Create: `lib/deckex/settings/registry.ex`
- Create: `lib/deckex/settings/setting_query.ex`
- Create: `lib/deckex/settings.ex`
- Test: `test/deckex/settings_test.exs`

**Interfaces:**
- Consumes: `use Deckex.Schema`, `Deckex.Error.new/3`, `%Deckex.Analysis.Baselines{}`.
- Produces:
  - `Deckex.Settings.Registry.entries() :: [%{key: atom(), type: atom(), default: term(), label: String.t(), options: [term()] | nil, group: atom()}]`
  - `Deckex.Settings.Registry.fetch(atom()) :: {:ok, map()} | :error`
  - `Deckex.Settings.get(atom()) :: term()`
  - `Deckex.Settings.put(atom(), term()) :: {:ok, term()} | {:error, %Deckex.Error{}}`
  - `Deckex.Settings.all() :: %{atom() => term()}`
  - `Deckex.Settings.model() :: String.t()`
  - `Deckex.Settings.baselines() :: %Deckex.Analysis.Baselines{}`

- [ ] **Step 1: Generate and write the migration**

```bash
mix ecto.gen.migration create_settings
```

```elixir
defmodule Deckex.Repo.Migrations.CreateSettings do
  use Ecto.Migration

  def change do
    create table(:settings, primary_key: false) do
      add :key, :string, primary_key: true
      # jsonb, so a setting can be a string, a number or a whole baselines map
      # without a column per type.
      add :value, :map, null: false

      timestamps(type: :utc_datetime)
    end
  end
end
```

- [ ] **Step 2: Write the failing test**

Create `test/deckex/settings_test.exs`:

```elixir
defmodule Deckex.SettingsTest do
  use Deckex.DataCase, async: true

  alias Deckex.Analysis.Baselines
  alias Deckex.Error
  alias Deckex.Settings
  alias Deckex.Settings.Registry

  describe "Registry" do
    test "declares the model with its options" do
      assert {:ok, entry} = Registry.fetch(:claude_model)

      assert entry.type == :string
      assert "sonnet" in entry.options
      assert "opus" in entry.options
    end

    test "declares the Moxfield User-Agent" do
      assert {:ok, %{type: :string}} = Registry.fetch(:moxfield_user_agent)
    end

    test "declares the baselines as one map" do
      assert {:ok, %{type: :baselines}} = Registry.fetch(:baselines)
    end

    test "does not know an invented key" do
      assert :error = Registry.fetch(:banana)
    end

    test "every entry carries a pt-BR label and a group" do
      for entry <- Registry.entries() do
        assert is_binary(entry.label)
        assert entry.label != ""
        assert entry.group in [:ai, :moxfield, :analysis]
      end
    end
  end

  describe "get/1" do
    test "falls back to the registry default when nothing is stored" do
      assert Settings.get(:claude_model) == "sonnet"
    end

    test "returns what was stored" do
      {:ok, _value} = Settings.put(:claude_model, "opus")

      assert Settings.get(:claude_model) == "opus"
    end

    test "raises on a key the registry does not declare" do
      assert_raise ArgumentError, fn -> Settings.get(:banana) end
    end
  end

  describe "put/2" do
    test "rejects a value outside the declared options" do
      assert {:error, %Error{code: :invalid_setting}} =
               Settings.put(:claude_model, "gpt-quatro")
    end

    test "rejects a value of the wrong type" do
      assert {:error, %Error{code: :invalid_setting}} = Settings.put(:claude_model, 42)
    end

    test "rejects an unknown key" do
      assert {:error, %Error{code: :invalid_setting}} = Settings.put(:banana, "x")
    end

    test "overwrites rather than duplicating" do
      {:ok, _first} = Settings.put(:claude_model, "opus")
      {:ok, _second} = Settings.put(:claude_model, "fable")

      assert Settings.get(:claude_model) == "fable"
    end
  end

  describe "all/0" do
    test "returns every key, stored or default" do
      {:ok, _value} = Settings.put(:claude_model, "opus")

      all = Settings.all()

      assert all[:claude_model] == "opus"
      assert all[:moxfield_user_agent] != nil
    end
  end

  describe "baselines/0" do
    test "returns the documented defaults when nothing is overridden" do
      assert %Baselines{land_base: 36, ramp_target: 10} = Settings.baselines()
    end

    test "applies an override without touching the rest" do
      {:ok, _value} = Settings.put(:baselines, %{"land_base" => 38})

      baselines = Settings.baselines()

      assert baselines.land_base == 38
      assert baselines.ramp_target == 10
    end

    test "ignores an override for a field Baselines does not have" do
      {:ok, _value} = Settings.put(:baselines, %{"banana" => 1})

      assert %Baselines{} = Settings.baselines()
    end
  end

  describe "model/0" do
    test "is the configured model" do
      {:ok, _value} = Settings.put(:claude_model, "opus")

      assert Settings.model() == "opus"
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `mix test test/deckex/settings_test.exs`
Expected: FAIL — `module Deckex.Settings.Registry is not available`.

- [ ] **Step 4: Add the error code**

In `lib/deckex/error.ex`, add `| :invalid_setting` to the `@type code` union.

- [ ] **Step 5: Write the registry**

Create `lib/deckex/settings/registry.ex`:

```elixir
defmodule Deckex.Settings.Registry do
  @moduledoc """
  The settings this application knows about.

  A key not declared here cannot be read or written. That is the point: a
  key/value table with no registry is a place where typos live forever, and
  where "what can I actually change?" has no answer but grep.

  `options` being non-nil means the value is constrained to that list.
  """

  @type entry :: %{
          key: atom(),
          type: :string | :integer | :number | :baselines,
          default: term(),
          label: String.t(),
          hint: String.t() | nil,
          options: [term()] | nil,
          group: :ai | :moxfield | :analysis
        }

  @entries [
    %{
      key: :claude_model,
      type: :string,
      default: "sonnet",
      label: "Modelo do Claude",
      hint: "Usado nas consultas e na classificação de cartas.",
      options: ["fable", "sonnet", "opus", "haiku"],
      group: :ai
    },
    %{
      key: :consult_budget_usd,
      type: :integer,
      default: 0,
      label: "Teto por carta (US$)",
      hint: "Zero significa sem teto. Vai no prompt como orientação, não como regra dura.",
      options: nil,
      group: :ai
    },
    %{
      key: :usd_to_brl,
      type: :number,
      default: 5.4,
      label: "Dólar em reais",
      hint: "Usado só para mostrar o preço das cartas em R$. A Scryfall cota em USD.",
      options: nil,
      group: :analysis
    },
    %{
      key: :moxfield_user_agent,
      type: :string,
      default: "deckex/0.1 (personal deck analysis tool)",
      label: "User-Agent do Moxfield",
      hint: "Cole aqui o que o support@moxfield.com aprovar. Até lá, o sync devolve 403.",
      options: nil,
      group: :moxfield
    },
    %{
      key: :baselines,
      type: :baselines,
      default: %{},
      label: "Baselines da análise",
      hint: "Heurísticas de Commander, não leis. Vazio significa usar os padrões.",
      options: nil,
      group: :analysis
    }
  ]

  @doc "Every declared setting."
  @spec entries() :: [entry()]
  def entries, do: @entries

  @doc "The entry for `key`, or `:error` if it is not declared."
  @spec fetch(atom()) :: {:ok, entry()} | :error
  def fetch(key) do
    case Enum.find(@entries, &(&1.key == key)) do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

  @doc "The entries in one group, in declaration order."
  @spec group(atom()) :: [entry()]
  def group(name), do: Enum.filter(@entries, &(&1.group == name))
end
```

- [ ] **Step 6: Write the schema and query module**

Create `lib/deckex/settings/setting.ex`:

```elixir
defmodule Deckex.Settings.Setting do
  @moduledoc """
  One stored setting.

  The primary key is the setting's own name — there is exactly one row per key
  by construction, so "which value wins" is never a question.

  The value is wrapped in a map (`%{"v" => value}`) because a jsonb column holds
  an object, not a bare scalar, and a wrapper is simpler than a column per type.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:key, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime]

  @type t :: %__MODULE__{}

  schema "settings" do
    field :value, :map

    timestamps()
  end

  @doc "Builds a changeset for a stored setting."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value])
    |> validate_required([:key, :value])
  end
end
```

Create `lib/deckex/settings/setting_query.ex`:

```elixir
defmodule Deckex.Settings.SettingQuery do
  @moduledoc "All reads of stored settings."

  alias Deckex.Repo
  alias Deckex.Settings.Setting

  @doc "Every stored setting, as a map of key string to raw value."
  @spec all() :: %{String.t() => term()}
  def all do
    Setting
    |> Repo.all()
    |> Map.new(fn %{key: key, value: %{"v" => value}} -> {key, value} end)
  end

  @doc "One stored setting's value, or nil."
  @spec get(atom()) :: term() | nil
  def get(key) do
    case Repo.get(Setting, to_string(key)) do
      nil -> nil
      %{value: %{"v" => value}} -> value
    end
  end
end
```

- [ ] **Step 7: Write the context**

Create `lib/deckex/settings.ex`:

```elixir
defmodule Deckex.Settings do
  @moduledoc """
  The knobs: which model to ask, what to tell Moxfield we are, and where the
  analysis baselines sit.

  **`baselines/0` returns a struct, it does not inject one.** `Deckex.Analysis`
  is pure by contract and must never reach for a database; the caller loads the
  baselines here and passes them in. That is why this module builds a
  `%Baselines{}` rather than the lens asking for one.
  """

  alias Deckex.Analysis.Baselines
  alias Deckex.Error
  alias Deckex.Repo
  alias Deckex.Settings.Registry
  alias Deckex.Settings.Setting
  alias Deckex.Settings.SettingQuery

  @doc """
  The current value of `key` — stored if set, the registry default otherwise.

  Raises on an undeclared key: that is a typo in code, not a user mistake.
  """
  @spec get(atom()) :: term()
  def get(key) do
    case Registry.fetch(key) do
      {:ok, entry} -> SettingQuery.get(key) || entry.default
      :error -> raise ArgumentError, "unknown setting #{inspect(key)}"
    end
  end

  @doc "Every declared setting's current value."
  @spec all() :: %{atom() => term()}
  def all do
    stored = SettingQuery.all()

    Map.new(Registry.entries(), fn entry ->
      {entry.key, Map.get(stored, to_string(entry.key), entry.default)}
    end)
  end

  @doc "Stores `value` for `key` after checking it against the registry."
  @spec put(atom(), term()) :: {:ok, term()} | {:error, Error.t()}
  def put(key, value) do
    with {:ok, entry} <- fetch_entry(key),
         :ok <- validate(entry, value) do
      %Setting{}
      |> Setting.changeset(%{key: to_string(key), value: %{"v" => value}})
      |> Repo.insert!(on_conflict: {:replace, [:value, :updated_at]}, conflict_target: :key)

      {:ok, value}
    end
  end

  @doc "The model to ask."
  @spec model() :: String.t()
  def model, do: get(:claude_model)

  @doc "The per-card budget to mention in a briefing, or nil for no ceiling."
  @spec budget_usd() :: pos_integer() | nil
  def budget_usd do
    case get(:consult_budget_usd) do
      budget when is_integer(budget) and budget > 0 -> budget
      _no_ceiling -> nil
    end
  end

  @doc """
  The analysis baselines with any stored overrides applied.

  Unknown keys in the override map are ignored rather than raising: a baseline
  removed from the struct should not brick the settings screen.
  """
  @spec baselines() :: Baselines.t()
  def baselines do
    fields = Baselines.default() |> Map.from_struct() |> Map.keys() |> MapSet.new()

    :baselines
    |> get()
    |> Enum.reduce(Baselines.default(), fn {field, value}, baselines ->
      key = safe_atom(field, fields)

      if key, do: Map.put(baselines, key, value), else: baselines
    end)
  end

  defp fetch_entry(key) do
    case Registry.fetch(key) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, invalid("Não conheço a configuração #{inspect(key)}.", %{key: key})}
    end
  end

  defp validate(%{type: :string, options: nil}, value) when is_binary(value), do: :ok

  defp validate(%{type: :string, options: options} = entry, value) when is_binary(value) do
    if value in options do
      :ok
    else
      {:error,
       invalid(
         "#{entry.label}: “#{value}” não é uma opção válida.",
         %{key: entry.key, options: options}
       )}
    end
  end

  defp validate(%{type: :integer} = entry, value) when is_integer(value) and value >= 0 do
    _ = entry

    :ok
  end

  defp validate(%{type: :number} = entry, value) when is_number(value) and value > 0 do
    _ = entry

    :ok
  end

  defp validate(%{type: :baselines} = entry, value) when is_map(value) do
    _ = entry

    :ok
  end

  defp validate(entry, value) do
    {:error,
     invalid("#{entry.label}: valor inválido.", %{key: entry.key, value: inspect(value)})}
  end

  defp invalid(message, details), do: Error.new(:invalid_setting, message, details)

  # String.to_existing_atom would raise on a field removed from Baselines; this
  # narrows to fields the struct actually has, so a stale override is ignored.
  defp safe_atom(field, allowed) do
    Enum.find(allowed, &(to_string(&1) == to_string(field)))
  end
end
```

- [ ] **Step 8: Migrate, test, gate, commit**

```bash
mix ecto.migrate && mix test test/deckex/settings_test.exs
```

Expected: PASS — 15 tests.

```bash
mix lint && git add -A && git commit -m "feat: add a typed settings store

A key/value table with no registry is a place where typos live forever. Every
key declares its type, default and options, and a write is checked against
them."
```

---

### Task 2: Wire the settings into the ports

**Files:**
- Modify: `lib/deckex/ai.ex`
- Modify: `lib/deckex/moxfield/http.ex`
- Test: `test/deckex/settings_wiring_test.exs`

**Interfaces:**
- Consumes: `Settings.get/1`, `Settings.model/0` (Task 1).
- Produces: no new functions; `Deckex.AI.model/0` and
  `Deckex.Moxfield.Http.user_agent/0` now read Settings first.

- [ ] **Step 1: Write the failing test**

Create `test/deckex/settings_wiring_test.exs`:

```elixir
defmodule Deckex.SettingsWiringTest do
  use Deckex.DataCase, async: true

  alias Deckex.AI
  alias Deckex.Moxfield.Http
  alias Deckex.Settings

  describe "the AI model" do
    test "falls back to the compile-time default" do
      assert AI.model() == "sonnet"
    end

    test "follows the stored setting" do
      {:ok, _value} = Settings.put(:claude_model, "opus")

      assert AI.model() == "opus"
    end
  end

  describe "the Moxfield User-Agent" do
    test "follows the stored setting, which is the whole point of it being a setting" do
      {:ok, _value} = Settings.put(:moxfield_user_agent, "deckex/1.0 (approved by moxfield)")

      assert Http.user_agent() == "deckex/1.0 (approved by moxfield)"
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/deckex/settings_wiring_test.exs`
Expected: FAIL — the stored setting is ignored.

Note: `config/test.exs` sets `user_agent: "deckex-test-agent"` for
`Deckex.Moxfield.Http`. Settings must win over config so the wiring is real;
the existing `http_test.exs` assertion still passes because no setting is
stored in that test.

- [ ] **Step 3: Read Settings in the AI facade**

In `lib/deckex/ai.ex`, replace `model/0` with:

```elixir
  @doc ~S"""
  The model to ask: the stored setting, falling back to config (default
  `"sonnet"`).
  """
  @spec model() :: String.t()
  def model, do: Deckex.Settings.get(:claude_model) || config(:model, "sonnet")
```

- [ ] **Step 4: Read Settings in the Moxfield adapter**

In `lib/deckex/moxfield/http.ex`, replace `user_agent/0` with:

```elixir
  @doc """
  The User-Agent sent to Moxfield.

  Settings wins over config: the whole reason this is a setting is that the
  owner can paste an approved User-Agent in without a deploy.
  """
  @spec user_agent() :: String.t()
  def user_agent do
    Deckex.Settings.get(:moxfield_user_agent) || config(:user_agent, @default_user_agent)
  end
```

- [ ] **Step 5: Run the tests, gate, commit**

```bash
mix test test/deckex/settings_wiring_test.exs test/deckex/moxfield/ && mix lint
```

Expected: PASS.

```bash
git add -A && git commit -m "feat: read the model and User-Agent from settings

Settings wins over config: the reason the User-Agent is a setting at all is
that an approved one can be pasted in without a deploy."
```

---

### Task 3: A consult records the model it was asked for

**Files:**
- Modify: `lib/deckex/consults.ex`
- Test: `test/deckex/consult_models_test.exs`

**Interfaces:**
- Consumes: `Settings.model/0`, `Settings.budget_usd/0` (Tasks 1–2).
- Produces:
  - `Deckex.Consults.request/3` now accepts `:model` in `opts` and stores it
  - `Deckex.Consults.compare(%Deck{}, lens :: atom(), models :: [String.t()], opts :: keyword()) :: {:ok, [%Consult{}]}`
  - `Deckex.Consults.models() :: [String.t()]`

- [ ] **Step 1: Write the failing test**

Create `test/deckex/consult_models_test.exs`:

```elixir
defmodule Deckex.ConsultModelsTest do
  use Deckex.DataCase, async: true

  import Mox

  alias Deckex.CatalogueFixture
  alias Deckex.Consults
  alias Deckex.Decks
  alias Deckex.Settings

  setup :verify_on_exit!

  defp deck do
    CatalogueFixture.seed!(~w(sol_ring forest counterspell))

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n1 Counterspell\n4 Forest", %{
        name: "Deck do Modelo",
        source: :paste
      })

    deck
  end

  describe "request/3 with a model" do
    test "records the model it was asked for, before it runs" do
      assert {:ok, consult} = Consults.request(deck(), :full, model: "opus")

      assert consult.model == "opus"
      assert consult.status == :pending
    end

    test "falls back to the configured model" do
      {:ok, _value} = Settings.put(:claude_model, "fable")

      assert {:ok, consult} = Consults.request(deck(), :full)
      assert consult.model == "fable"
    end

    test "sends the recorded model to the port, not the current setting" do
      {:ok, consult} = Consults.request(deck(), :full, model: "opus")
      # Changing the setting afterwards must not change what this consult runs.
      {:ok, _value} = Settings.put(:claude_model, "fable")

      expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, opts ->
        assert opts[:model] == "opus"

        {:ok, %{"diagnosis" => "ok", "cuts" => [], "adds" => []}}
      end)

      assert {:ok, done} = Consults.run(consult)
      assert done.model == "opus"
    end
  end

  describe "compare/4" do
    test "runs one identical briefing across several models" do
      assert {:ok, consults} = Consults.compare(deck(), :full, ["sonnet", "opus"])

      assert length(consults) == 2
      assert Enum.map(consults, & &1.model) |> Enum.sort() == ["opus", "sonnet"]

      # The experiment is only clean if the input is byte-identical.
      assert consults |> Enum.map(& &1.briefing) |> Enum.uniq() |> length() == 1
    end

    test "queues one job per model" do
      {:ok, _consults} = Consults.compare(deck(), :full, ["sonnet", "opus", "fable"])

      assert 3 = Oban.Job |> Deckex.Repo.aggregate(:count)
    end
  end

  describe "models/0" do
    test "offers the aliases the CLI accepts" do
      assert "sonnet" in Consults.models()
      assert "opus" in Consults.models()
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/deckex/consult_models_test.exs`
Expected: FAIL — `consult.model` is nil at request time.

- [ ] **Step 3: Record and honour the model**

In `lib/deckex/consults.ex`, add `alias Deckex.Settings`, then replace
`request/3`, `run/1`, `insert!/5` and `succeed/3` with:

```elixir
  @doc """
  Measures `deck`, freezes the report, the prompt **and the model**, then queues
  the call.

  The model is recorded now rather than read at run time: changing the setting
  between asking and answering must not silently change what a queued consult
  runs.
  """
  @spec request(Deck.t(), atom(), keyword()) :: {:ok, Consult.t()}
  def request(%Deck{} = deck, lens, opts \\ []) do
    snapshot = Decks.snapshot(deck)
    report = Analysis.report(snapshot, Settings.baselines())

    {:ok, hd(insert_all!(deck, lens, report, snapshot, [model(opts)], opts))}
  end

  @doc """
  Runs one identical briefing across several models, so they can be compared on
  the same question.

  One briefing is built and shared by every consult: an experiment whose input
  differs per arm measures nothing.
  """
  @spec compare(Deck.t(), atom(), [String.t()], keyword()) :: {:ok, [Consult.t()]}
  def compare(%Deck{} = deck, lens, models, opts \\ []) do
    snapshot = Decks.snapshot(deck)
    report = Analysis.report(snapshot, Settings.baselines())

    {:ok, insert_all!(deck, lens, report, snapshot, models, opts)}
  end

  @doc "The model aliases the `claude` CLI accepts."
  @spec models() :: [String.t()]
  def models, do: ["fable", "sonnet", "opus", "haiku"]

  @doc "Sends a consult's stored briefing to the model and records the answer."
  @spec run(Consult.t()) :: {:ok, Consult.t()} | {:error, Error.t()}
  def run(%Consult{} = consult) do
    running = update!(consult, %{status: :running})
    started = System.monotonic_time(:millisecond)
    schema = Schemas.for_lens(running.lens)

    # WebSearch is the point of the whole feature: the app supplies measured
    # facts about this deck, the model supplies knowledge about every card.
    opts = [
      allowed_tools: ["WebSearch"],
      timeout_ms: timeout_ms(),
      model: running.model
    ]

    case AI.complete(running.briefing, schema, opts) do
      {:ok, response} -> {:ok, succeed(running, response, started)}
      {:error, %Error{} = error} -> fail(running, error)
    end
  end

  defp model(opts), do: opts[:model] || Settings.model()

  defp insert_all!(deck, lens, report, snapshot, models, opts) do
    briefing = Briefing.build(report, snapshot, lens, budget_opts(opts))
    frozen = freeze(report)

    Enum.map(models, fn model ->
      consult = insert!(deck, lens, briefing, frozen, model, opts)

      {:ok, _job} = ConsultWorker.enqueue(consult.id)
      Events.broadcast_consult(consult)

      consult
    end)
  end

  defp budget_opts(opts), do: Keyword.put_new(opts, :budget_usd, Settings.budget_usd())

  defp insert!(deck, lens, briefing, frozen, model, opts) do
    %Consult{}
    |> Consult.changeset(%{
      deck_id: deck.id,
      lens: lens,
      finding_code: opts[:finding_code],
      status: :pending,
      briefing: briefing,
      report_snapshot: frozen,
      model: model
    })
    |> Repo.insert!()
  end

  defp succeed(consult, response, started) do
    update!(consult, %{
      status: :done,
      response: response,
      duration_ms: System.monotonic_time(:millisecond) - started,
      error: nil
    })
  end
```

- [ ] **Step 4: Let `Analysis.report/2` take the baselines it is given**

`Analysis.report/2` already accepts baselines as its second argument with a
default, so no change is needed there. Confirm it:

```bash
grep -n "def report" lib/deckex/analysis.ex
```

Expected: `def report(%DeckSnapshot{} = snapshot, baselines \\ Baselines.default())`.

- [ ] **Step 5: Run the test, gate, commit**

Run: `mix test test/deckex/consult_models_test.exs test/deckex/consults_test.exs`
Expected: PASS.

```bash
mix lint && git add -A && git commit -m "feat: pin a consult to the model it was asked for

Recorded at request time, not read at run time: changing the setting between
asking and answering must not silently change what a queued consult runs.
compare/4 shares one briefing across models -- an experiment whose input
differs per arm measures nothing."
```

---

### Task 4: The Ajustes screen

**Files:**
- Create: `lib/deckex_web/live/settings_live.ex`
- Modify: `lib/deckex_web/router.ex`
- Modify: `lib/deckex_web/live/mesa_live.ex` (a link)
- Test: `test/deckex_web/live/settings_live_test.exs`

**Interfaces:**
- Consumes: `Settings.all/0`, `Settings.put/2`, `Registry.entries/0`,
  `Registry.group/1` (Task 1).
- Produces: the route `/ajustes`.

- [ ] **Step 1: Write the failing test**

Create `test/deckex_web/live/settings_live_test.exs`:

```elixir
defmodule DeckexWeb.SettingsLiveTest do
  use DeckexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Deckex.Settings

  test "shows every declared setting, grouped", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/ajustes")

    assert html =~ "Modelo do Claude"
    assert html =~ "User-Agent do Moxfield"
    assert html =~ "Baselines"
  end

  test "saves the model", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/ajustes")

    live
    |> form("form[phx-submit='save']", setting: %{key: "claude_model", value: "opus"})
    |> render_submit()

    assert Settings.get(:claude_model) == "opus"
  end

  test "refuses a model outside the options and says why", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/ajustes")

    html =
      live
      |> form("form[phx-submit='save']", setting: %{key: "claude_model", value: "gpt-quatro"})
      |> render_submit()

    assert html =~ "não é uma opção válida"
    assert Settings.get(:claude_model) == "sonnet"
  end

  test "saves a baseline override", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/ajustes")

    live
    |> form("form[phx-submit='save-baseline']", baseline: %{field: "land_base", value: "38"})
    |> render_submit()

    assert Settings.baselines().land_base == 38
  end

  test "explains that the Moxfield User-Agent is the path to sanctioned access",
       %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/ajustes")

    assert html =~ "support@moxfield.com"
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/deckex_web/live/settings_live_test.exs`
Expected: FAIL — no route.

- [ ] **Step 3: Add the route and the Mesa link**

In `lib/deckex_web/router.ex`, inside the browser scope:

```elixir
    live "/ajustes", SettingsLive, :edit
```

In `lib/deckex_web/live/mesa_live.ex`, replace the header's button block with:

```elixir
        <div class="flex items-center gap-4">
          <.link
            navigate={~p"/ajustes"}
            class="text-caption text-ink-faint transition-colors hover:text-ink"
          >
            Ajustes
          </.link>

          <.button navigate={~p"/importar"} variant="primary">Trazer um deck</.button>
        </div>
```

- [ ] **Step 4: Write the LiveView**

Create `lib/deckex_web/live/settings_live.ex`:

```elixir
defmodule DeckexWeb.SettingsLive do
  @moduledoc """
  Ajustes: the knobs, with their reasons.

  Each setting shows its hint, because most of these are only meaningful with
  context — "User-Agent do Moxfield" means nothing until you know that pasting
  an approved one is what turns URL sync from a 403 into a feature.
  """
  use DeckexWeb, :live_view

  alias Deckex.Analysis.Baselines
  alias Deckex.Settings
  alias Deckex.Settings.Registry

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Ajustes", error: nil) |> load()}
  end

  defp load(socket) do
    assign(socket, values: Settings.all(), baselines: Settings.baselines())
  end

  @impl Phoenix.LiveView
  def handle_event("save", %{"setting" => %{"key" => key, "value" => value}}, socket) do
    {:noreply, save(socket, String.to_existing_atom(key), cast(key, value))}
  end

  def handle_event("save-baseline", %{"baseline" => %{"field" => field, "value" => value}}, socket) do
    override =
      socket.assigns.values
      |> Map.fetch!(:baselines)
      |> Map.put(field, parse_number(value))

    {:noreply, save(socket, :baselines, override)}
  end

  defp save(socket, key, value) do
    case Settings.put(key, value) do
      {:ok, _value} -> socket |> assign(error: nil) |> load() |> put_flash(:info, "Salvo.")
      {:error, error} -> assign(socket, error: error.message)
    end
  end

  # The form gives us strings; the registry says what the value must actually be.
  defp cast("consult_budget_usd", value), do: parse_number(value)
  defp cast(_key, value), do: value

  defp parse_number(value) do
    case Float.parse(value) do
      {number, ""} -> if number == trunc(number), do: trunc(number), else: number
      _not_a_number -> value
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-[1100px] px-6 py-10 lg:px-10 lg:py-14">
      <.link navigate={~p"/"} class="text-caption text-ink-faint transition-colors hover:text-ink">
        ← A Mesa
      </.link>

      <header class="mt-3 mb-10">
        <h1 class="text-hero font-semibold text-ink">Ajustes</h1>
        <p class="mt-1 text-body text-ink-muted">
          Os números da análise são heurísticas, não leis. Mexa à vontade.
        </p>
      </header>

      <p
        :if={@error}
        class="mb-8 rounded-lg border bg-surface p-4 text-body text-ink"
        style={"border-color:color-mix(in srgb, #{Format.severity_var(:critical)} 30%, transparent)"}
      >
        {@error}
      </p>

      <div class="space-y-8">
        <section :for={{group, title} <- groups()} class="rounded-xl border border-hairline-soft bg-surface p-6">
          <h2 class="mb-5 text-heading font-semibold text-ink">{title}</h2>

          <div class="space-y-6">
            <div :for={entry <- Registry.group(group)} :if={entry.type != :baselines}>
              <.form for={%{}} as={:setting} phx-submit="save" class="flex flex-wrap items-end gap-3">
                <input type="hidden" name="setting[key]" value={entry.key} />

                <div class="min-w-0 flex-1">
                  <label
                    for={"setting-#{entry.key}"}
                    class="mb-1.5 block text-label font-semibold uppercase tracking-[0.1em] text-ink-faint"
                  >
                    {entry.label}
                  </label>

                  <select
                    :if={entry.options}
                    id={"setting-#{entry.key}"}
                    name="setting[value]"
                    class="w-full rounded-md border border-hairline-soft bg-inlay px-3 py-2 text-body text-ink"
                  >
                    <option
                      :for={option <- entry.options}
                      value={option}
                      selected={to_string(@values[entry.key]) == to_string(option)}
                    >
                      {option}
                    </option>
                  </select>

                  <input
                    :if={is_nil(entry.options)}
                    id={"setting-#{entry.key}"}
                    type="text"
                    name="setting[value]"
                    value={@values[entry.key]}
                    class="w-full rounded-md border border-hairline-soft bg-inlay px-3 py-2 font-mono text-body-sm text-ink"
                  />

                  <p :if={entry.hint} class="mt-1.5 text-caption text-ink-muted">{entry.hint}</p>
                </div>

                <.button type="submit">Salvar</.button>
              </.form>
            </div>

            <div :if={group == :analysis}>
              <p class="mb-4 text-caption text-ink-muted">
                Heurísticas de Commander de 99 cartas. Um número em branco usa o padrão.
              </p>

              <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
                <.form
                  :for={{field, value} <- baseline_fields(@baselines)}
                  for={%{}}
                  as={:baseline}
                  phx-submit="save-baseline"
                  class="flex items-end gap-2"
                >
                  <input type="hidden" name="baseline[field]" value={field} />

                  <div class="min-w-0 flex-1">
                    <label
                      for={"baseline-#{field}"}
                      class="mb-1 block font-mono text-micro text-ink-faint"
                    >
                      {field}
                    </label>
                    <input
                      id={"baseline-#{field}"}
                      type="text"
                      name="baseline[value]"
                      value={value}
                      class="w-full rounded-md border border-hairline-soft bg-inlay px-2 py-1 font-mono text-caption text-ink"
                    />
                  </div>

                  <.button type="submit">ok</.button>
                </.form>
              </div>
            </div>
          </div>
        </section>
      </div>
    </div>
    """
  end

  defp groups do
    [{:ai, "Inteligência artificial"}, {:moxfield, "Moxfield"}, {:analysis, "Baselines"}]
  end

  defp baseline_fields(%Baselines{} = baselines) do
    baselines |> Map.from_struct() |> Enum.sort_by(fn {field, _value} -> to_string(field) end)
  end
end
```

- [ ] **Step 5: Run the test, gate, commit**

Run: `mix test test/deckex_web/live/settings_live_test.exs`
Expected: PASS — 5 tests.

```bash
mix lint && git add -A && git commit -m "feat: add the Ajustes screen

Each setting shows its hint: most are meaningless without context. The
User-Agent field means nothing until you know that pasting an approved one is
what turns URL sync from a 403 into a feature."
```

---

### Task 5: Choosing a model, and comparing them

**Files:**
- Modify: `lib/deckex_web/live/deck_live.ex`
- Test: `test/deckex_web/live/deck_compare_test.exs`

**Interfaces:**
- Consumes: `Consults.compare/4`, `Consults.models/0` (Task 3).
- Produces: no new modules.

- [ ] **Step 1: Write the failing test**

Create `test/deckex_web/live/deck_compare_test.exs`:

```elixir
defmodule DeckexWeb.DeckCompareTest do
  use DeckexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Deckex.CatalogueFixture
  alias Deckex.Consults
  alias Deckex.Decks

  setup do
    CatalogueFixture.seed!(~w(sol_ring forest counterspell))

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n1 Counterspell\n4 Forest", %{
        name: "Deck da Comparação",
        source: :paste
      })

    %{deck: deck}
  end

  test "the model can be chosen before asking", %{conn: conn, deck: deck} do
    {:ok, live, html} = live(conn, ~p"/decks/#{deck.id}")

    assert html =~ "opus"

    live
    |> form("form[phx-submit='consult-full']", consult: %{model: "opus"})
    |> render_submit()

    assert [%{model: "opus"}] = Consults.list_for_deck(deck)
  end

  test "comparing runs one briefing across every model", %{conn: conn, deck: deck} do
    {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

    live |> element("button[phx-click='compare-models']") |> render_click()

    consults = Consults.list_for_deck(deck)

    assert length(consults) == length(Consults.models())
    assert consults |> Enum.map(& &1.briefing) |> Enum.uniq() |> length() == 1
  end

  test "each consult shows which model answered it", %{conn: conn, deck: deck} do
    {:ok, _consult} = Consults.request(deck, :full, model: "opus")

    {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

    assert html =~ "opus"
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/deckex_web/live/deck_compare_test.exs`
Expected: FAIL — no model form.

- [ ] **Step 3: Add the model choice and the compare action**

In `lib/deckex_web/live/deck_live.ex`, add `model: Deckex.Settings.model()` to
the `assign_deck/2` call, then replace the two consult handlers with:

```elixir
  @impl Phoenix.LiveView
  def handle_event("consult-finding", %{"code" => code} = params, socket) do
    {:noreply, start_consult(socket, :finding, finding_code: code, model: params["model"])}
  end

  def handle_event("consult-full", params, socket) do
    model = get_in(params, ["consult", "model"]) || socket.assigns.model

    {:noreply, start_consult(socket, :full, model: model)}
  end

  def handle_event("compare-models", _params, socket) do
    {:ok, _consults} = Consults.compare(socket.assigns.deck, :full, Consults.models())

    {:noreply,
     socket
     |> put_flash(:info, "Rodando a mesma pergunta em #{length(Consults.models())} modelos.")
     |> assign(consults: Consults.list_for_deck(socket.assigns.deck))}
  end
```

and replace `start_consult/3` with a version that drops a nil model:

```elixir
  # Consults.request/3 raises rather than returning a tagged error — every
  # field it writes is built here, so a failure is a bug, not a user problem.
  defp start_consult(socket, lens, opts) do
    {:ok, _consult} =
      Consults.request(socket.assigns.deck, lens, Enum.reject(opts, &(elem(&1, 1) == nil)))

    socket
    |> put_flash(:info, "Consulta enviada. A resposta aparece aqui quando chegar.")
    |> assign(consults: Consults.list_for_deck(socket.assigns.deck))
  end
```

- [ ] **Step 4: Replace the findings header with a model picker**

In `lib/deckex_web/live/deck_live.ex`, replace the `<div class="mb-3 flex items-center justify-between gap-3">` header block with:

```elixir
          <div class="mb-3 space-y-2">
            <div class="flex items-center justify-between gap-3">
              <h2 class="text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
                Achados
              </h2>

              <button
                type="button"
                phx-click="compare-models"
                class="text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
              >
                Comparar modelos
              </button>
            </div>

            <.form for={%{}} as={:consult} phx-submit="consult-full" class="flex items-center gap-2">
              <select
                name="consult[model]"
                class="rounded-md border border-hairline-soft bg-inlay px-2 py-1 font-mono text-caption text-ink"
              >
                <option :for={model <- Consults.models()} value={model} selected={model == @model}>
                  {model}
                </option>
              </select>

              <button
                type="submit"
                class="text-caption text-ink-faint underline decoration-hairline-strong underline-offset-2 transition-colors hover:text-ink"
              >
                Consultar o deck inteiro
              </button>
            </.form>
          </div>
```

- [ ] **Step 5: Show the model on each consult**

In the consult `<header>`, replace the lens span with:

```elixir
                  <span class="font-mono text-caption text-ink-faint">
                    {consult.finding_code || consult.lens}
                    <span :if={consult.model} class="text-ink-disabled">· {consult.model}</span>
                  </span>
```

- [ ] **Step 6: Run the test, gate, commit**

Run: `mix test test/deckex_web/live/deck_compare_test.exs`
Expected: PASS — 3 tests.

```bash
mix lint && git add -A && git commit -m "feat: choose the model, and compare them on one question

Comparing shares a single briefing across every model, so the only variable is
the model itself."
```

---

### Task 6: Run the comparison for real

Not a test — the experiment the settings exist for.

- [ ] **Step 1: Run one briefing across every model**

```bash
cd /Users/tavano/projects/deckex
MIX_ENV=dev mix run -e '
  Logger.configure(level: :error)
  deck = List.first(Deckex.Decks.list_decks())
  {:ok, consults} = Deckex.Consults.compare(deck, :full, ["fable", "sonnet", "opus"])

  results =
    Enum.map(consults, fn consult ->
      {micros, outcome} = :timer.tc(fn -> Deckex.Consults.run(consult) end)
      {consult.model, div(micros, 1000), outcome}
    end)

  Enum.each(results, fn
    {model, ms, {:ok, done}} ->
      r = done.response
      IO.puts("\n════ #{String.upcase(model)} · #{ms}ms ════")
      IO.puts(r["diagnosis"])
      IO.puts("\ncortar: #{Enum.map_join(r["cuts"] || [], ", ", & &1["card"])}")
      IO.puts("colocar: #{Enum.map_join(r["adds"] || [], ", ", & &1["card"])}")

    {model, ms, {:error, e}} ->
      IO.puts("\n════ #{String.upcase(model)} · #{ms}ms ════\nFALHOU: #{e.message}")
  end)
'
```

Expected: three answers to the identical question. **Read them side by side.**
What to look for, in order of how much it matters:

1. **Legality.** Did any model suggest a card outside the colour identity? That
   is a hard failure and a reason to reject that model for this job.
2. **Grounding.** Did it cut cards that are actually in the list?
3. **Specificity.** "Add more removal" is worthless; "add Cyclonic Rift because
   the deck has one sweeper" is the product.
4. **Cost.** A model that takes four minutes and says the same thing as one that
   takes forty seconds is the wrong default.

- [ ] **Step 2: Record what you found**

Append a short section to `DESIGN.md`? No — this belongs with the spec's
decision log. Add a row to §14 of
`docs/superpowers/specs/2026-08-13-deckex-design.md` naming the model chosen as
the default and the evidence for it, then set it:

```bash
MIX_ENV=dev mix run -e 'Deckex.Settings.put(:claude_model, "sonnet")'
```

replacing `"sonnet"` with whichever model actually won.

- [ ] **Step 3: Run the full suite and the gate**

```bash
mix test && mix lint
```

---

## What this plan delivers

Every knob the app has, editable from a screen, with its reason next to it —
and the ability to answer "which model should this use?" from evidence rather
than from the first one that worked.

## Remaining debt

- A Content-Security-Policy, and deleting the `Config.CSP` ignore from
  `.sobelow-conf`.
- Self-hosting the two fonts into `priv/static/fonts`: they load from
  `fonts.googleapis.com` today, so an offline deckex renders in `system-ui`.
