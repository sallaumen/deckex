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
