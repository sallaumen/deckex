defmodule Deckex.Repo.Migrations.ConsultsReferenceTheirOptimization do
  @moduledoc """
  `consults.optimization_id` was a bare uuid column with no foreign key.

  Found the way these things are found: deleting fifteen runs left a hundred
  and twenty-three consults behind, pointing at rows that no longer existed.
  They were invisible — every read of a deck's consults filters on
  `is_nil(optimization_id)` — so they would have sat there forever, and the
  only reason anybody noticed is that the count did not drop.

  A pipeline consult belongs to its run and has no meaning without it, so it
  goes when the run goes. `deck_id` already cascades from the deck; this is the
  same rule for the other parent.
  """
  use Ecto.Migration

  def up do
    # Anything already dangling would refuse the constraint, and a dangling
    # pipeline consult is exactly what this migration is about.
    execute """
    DELETE FROM consults c
    WHERE c.optimization_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM optimizations o WHERE o.id = c.optimization_id)
    """

    alter table(:consults) do
      modify :optimization_id,
             references(:optimizations, type: :uuid, on_delete: :delete_all),
             from: :uuid
    end
  end

  def down do
    alter table(:consults) do
      modify :optimization_id, :uuid,
        from: references(:optimizations, type: :uuid, on_delete: :delete_all)
    end
  end
end
