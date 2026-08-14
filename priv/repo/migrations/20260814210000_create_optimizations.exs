defmodule Deckex.Repo.Migrations.CreateOptimizations do
  use Ecto.Migration

  def change do
    create table(:optimizations, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :deck_id, references(:decks, type: :uuid, on_delete: :delete_all), null: false
      add :status, :string, null: false
      add :outcome, :string

      # The goal contract and the recipe, both frozen at launch: an
      # optimization whose rules drift mid-run is one nobody can reason about.
      add :contract, :map, null: false
      add :recipe, {:array, :map}, null: false

      # The sandbox's starting point. The real deck is never written.
      add :list_original, {:array, :map}, null: false
      add :commanders, {:array, :string}, null: false, default: []

      add :finished_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:optimizations, [:deck_id])
    create index(:optimizations, [:status])

    create table(:optimization_steps, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :optimization_id,
          references(:optimizations, type: :uuid, on_delete: :delete_all),
          null: false

      add :position, :integer, null: false
      add :kind, :string, null: false
      add :lens, :string, null: false
      add :label, :string, null: false
      add :status, :string, null: false
      add :consult_id, references(:consults, type: :uuid, on_delete: :nilify_all)

      add :list_before, {:array, :map}
      add :applied, {:array, :map}, null: false, default: []
      add :rejected, {:array, :map}, null: false, default: []
      add :feedback, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:optimization_steps, [:optimization_id])
    create unique_index(:optimization_steps, [:optimization_id, :position])
    create index(:optimization_steps, [:consult_id])

    alter table(:consults) do
      add :optimization_id, :uuid
    end

    create index(:consults, [:optimization_id])
  end
end
