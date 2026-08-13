defmodule Deckex.Repo.Migrations.CreateCardRoles do
  use Ecto.Migration

  def change do
    create table(:card_roles, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :card_id, references(:cards, type: :uuid, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :confidence, :string, null: false
      add :source, :string, null: false
      add :evidence, :text

      timestamps(type: :utc_datetime)
    end

    # One verdict per role per card. The upsert in Deckex.Cards keys on this.
    create unique_index(:card_roles, [:card_id, :kind])
    create index(:card_roles, [:kind])
  end
end
