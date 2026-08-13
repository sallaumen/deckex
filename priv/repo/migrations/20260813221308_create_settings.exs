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
