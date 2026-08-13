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
