defmodule Deckex.Repo.Migrations.AddObanJobsTable do
  use Ecto.Migration

  # Oban 2.23 refuses to start below schema version 14.
  def up, do: Oban.Migration.up(version: 14)

  # Keep the down migration at version 1 so a rollback removes everything Oban
  # created, not just the most recent version's changes.
  def down, do: Oban.Migration.down(version: 1)
end
