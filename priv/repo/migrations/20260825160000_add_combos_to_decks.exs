defmodule Deckex.Repo.Migrations.AddCombosToDecks do
  @moduledoc """
  The known combos a deck assembles, and the ones it is one card from.

  Stored on the deck rather than in a table of their own, for the same reason
  the dossier is: they are derived from this list, read as a whole set, never
  queried one by one, and thrown away wholesale when the list changes. A table
  would buy joins nobody needs.

  `combos_stale` follows the dossier's flag exactly — a list that changed has
  combos that no longer describe it, and the refresh is one HTTP call made in
  the background rather than during a render.
  """
  use Ecto.Migration

  def change do
    alter table(:decks) do
      add :combos, :map
      add :combos_stale, :boolean, null: false, default: false
      add :combos_updated_at, :utc_datetime
    end
  end
end
