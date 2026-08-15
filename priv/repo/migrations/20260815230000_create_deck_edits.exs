defmodule Deckex.Repo.Migrations.CreateDeckEdits do
  @moduledoc """
  The changes made to a deck since its last version, with why each was made.

  Without this, a version marked after a morning of applying suggestions says
  "editado à mão" beside every card — true, and useless. The reason a card came
  in was written by the consult that suggested it, and it is the one thing the
  owner will want to read six versions later.

  Rows live only until the next version consumes them. This is a pending
  changelog, not an audit trail.
  """
  use Ecto.Migration

  def change do
    create table(:deck_edits, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :deck_id, references(:decks, type: :uuid, on_delete: :delete_all), null: false

      add :action, :string, null: false
      add :card_name, :string, null: false
      add :reason, :text

      # The consult that suggested it, when one did. Nilified rather than
      # cascaded: deleting a consult is tidying up and must not erase the
      # reason a card is in the deck.
      add :consult_id, references(:consults, type: :uuid, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:deck_edits, [:deck_id])

    # A version can also come from a single consult, and then it points at it
    # the same way an optimization's version points at its run.
    alter table(:deck_versions) do
      add :consult_id, references(:consults, type: :uuid, on_delete: :nilify_all)
    end
  end
end
