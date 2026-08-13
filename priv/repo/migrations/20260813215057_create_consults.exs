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
