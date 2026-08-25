defmodule Deckex.Repo.Migrations.AddDescriptionToDecks do
  @moduledoc """
  The owner's own words about what a deck is for.

  Everything the app knew about a deck's intent was either measured from the
  list or written by a model: the numbers say what the deck *is*, the dossier
  says what a scout *read into it*. Neither is the person who built it saying
  what he was going for — and when a stage cuts the card that made the whole
  thing work, that missing sentence is usually the one that would have stopped
  it.

  Deliberately not the dossier. The dossier is the app's reading and gets
  rewritten by a consult; this is his, and nothing overwrites it.
  """
  use Ecto.Migration

  def change do
    alter table(:decks) do
      add :description, :text
    end
  end
end
