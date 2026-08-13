defmodule Deckex.Repo.Migrations.CreateDecks do
  use Ecto.Migration

  def change do
    create table(:decks, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :string, null: false
      add :moxfield_url, :string
      add :moxfield_public_id, :string
      add :source, :string, null: false
      add :color_identity, {:array, :string}, null: false, default: []
      add :status, :string, null: false

      # The text the deck was built from. Kept so a parser improvement can
      # re-import without asking the user to paste again.
      add :raw_decklist, :text

      add :last_synced_at, :utc_datetime
      add :last_error, :text
      add :notes, :text
      add :archived_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:decks, [:moxfield_public_id],
             where: "moxfield_public_id IS NOT NULL",
             name: :decks_moxfield_public_id_index
           )

    create table(:deck_cards, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :deck_id, references(:decks, type: :uuid, on_delete: :delete_all), null: false
      add :card_id, references(:cards, type: :uuid, on_delete: :restrict), null: false
      add :quantity, :integer, null: false, default: 1
      add :board, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:deck_cards, [:deck_id, :card_id, :board])
    create index(:deck_cards, [:deck_id])
  end
end
