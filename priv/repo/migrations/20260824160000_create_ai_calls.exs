defmodule Deckex.Repo.Migrations.CreateAiCalls do
  @moduledoc """
  One row per call to the model — the ledger every token meter reads.

  The CLI envelope already carried `usage` and `total_cost_usd` on every
  answer and the adapter threw them away, so the app spent money all day and
  could not say how much. Kept as a ledger rather than a counter on the
  consult because not every call belongs to a consult: classifying cards is an
  AI call with no consult and no deck, and it costs the same real money.

  Numbers only, measured, never estimated. A call whose envelope carried no
  usage stores zeros and says so by having nothing to show.
  """
  use Ecto.Migration

  def change do
    create table(:ai_calls, primary_key: false) do
      add :id, :uuid, primary_key: true

      # What the call was for, and what it belonged to. Both ids nilify: a
      # deleted deck must not erase the record that its optimization cost R$ 40.
      add :kind, :string, null: false
      add :model, :string
      add :deck_id, references(:decks, type: :uuid, on_delete: :nilify_all)
      add :consult_id, references(:consults, type: :uuid, on_delete: :nilify_all)

      add :input_tokens, :integer, null: false, default: 0
      add :output_tokens, :integer, null: false, default: 0
      add :cache_creation_tokens, :integer, null: false, default: 0
      add :cache_read_tokens, :integer, null: false, default: 0

      # The CLI reports cost in USD; this app shows reais everywhere, converted
      # at the edge like every other price.
      add :cost_usd, :decimal, precision: 12, scale: 6, null: false, default: 0
      add :duration_ms, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:ai_calls, [:deck_id])
    create index(:ai_calls, [:consult_id])
    create index(:ai_calls, [:inserted_at])
  end
end
