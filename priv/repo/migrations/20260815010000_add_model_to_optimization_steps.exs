defmodule Deckex.Repo.Migrations.AddModelToOptimizationSteps do
  use Ecto.Migration

  def change do
    alter table(:optimization_steps) do
      # Null means "whatever the contract says". A value here is the owner
      # having redone this one stage with a different model.
      add :model, :string
    end
  end
end
