defmodule Deckex.Repo.Migrations.AddGameChangerToCards do
  use Ecto.Migration

  def change do
    alter table(:cards) do
      add :game_changer, :boolean, default: false, null: false
    end
  end
end
