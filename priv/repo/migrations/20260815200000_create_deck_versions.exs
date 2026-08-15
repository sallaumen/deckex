defmodule Deckex.Repo.Migrations.CreateDeckVersions do
  use Ecto.Migration

  def change do
    create table(:deck_versions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :deck_id, references(:decks, type: :uuid, on_delete: :delete_all), null: false

      # Sequential per deck, and unique per deck: two versions numbered v3 is
      # a history nobody can read.
      add :number, :integer, null: false
      add :origin, :string, null: false
      add :label, :string

      # The run that produced this version, when one did. Nilified rather than
      # cascaded: deleting a run is tidying up, and it must not take a
      # photograph of the deck with it.
      add :optimization_id, references(:optimizations, type: :uuid, on_delete: :nilify_all)

      # The list as jsonb, exactly the shape the optimizer's sandbox uses. A
      # version is history: no lens ever measures it and no query ever joins it.
      add :list, :map, null: false
      add :commanders, {:array, :string}, null: false, default: []
      add :changes, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:deck_versions, [:deck_id, :number])
    create index(:deck_versions, [:deck_id])
  end
end
