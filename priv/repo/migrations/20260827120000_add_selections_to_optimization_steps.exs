defmodule Deckex.Repo.Migrations.AddSelectionsToOptimizationSteps do
  use Ecto.Migration

  def change do
    alter table(:optimization_steps) do
      # What the owner chose on the Bancada, keyed `"<action>:<index>"` against
      # the vacancies in this step's consult answer. A `null` value is an
      # explicit skip; an absent key is undecided, and the board shows the two
      # differently.
      #
      # Separate from `applied` on purpose: `selections` is what he chose and
      # `applied` is what the audit let through. Same reason `rejected` exists.
      add :selections, :map, null: false, default: %{}
    end
  end
end
