defmodule Deckex.Repo.Migrations.CreateDeckCardNotes do
  @moduledoc """
  What the owner has told this app about a specific card in a specific deck.

  The review stage taught it once — Jaheira turns Food into creatures that tap
  for mana — and then the run ended and the knowledge died with it. The next
  run would misread her again, and he would explain her again. A fact about a
  card in a deck belongs to the deck, not to the half-hour that happened to
  surface it.
  """
  use Ecto.Migration

  def change do
    create table(:deck_card_notes, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :deck_id, references(:decks, type: :uuid, on_delete: :delete_all), null: false

      add :card_name, :string, null: false
      add :note, :text, null: false

      # Whether it came out of a review stage or was typed straight onto the
      # deck page. Both are the owner's words; only one of them cost a consult.
      add :source, :string, null: false, default: "manual"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:deck_card_notes, [:deck_id, :card_name])
  end
end
