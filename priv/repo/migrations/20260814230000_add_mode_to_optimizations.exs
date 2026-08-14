defmodule Deckex.Repo.Migrations.AddModeToOptimizations do
  use Ecto.Migration

  def change do
    alter table(:optimizations) do
      add :mode, :string, null: false, default: "refine"
    end
  end
end
