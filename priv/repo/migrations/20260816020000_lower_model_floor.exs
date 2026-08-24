defmodule Deckex.Repo.Migrations.LowerModelFloor do
  @moduledoc """
  Moves a stored `model_floor` that is still a copy of the old default.

  The floor shipped defaulting to `fable`, which is the **strongest** model on
  the ladder — so "the weakest model allowed to change the deck" excluded
  everything except the strongest, and the launcher's model picker had exactly
  one option for everyone. The default is now `sonnet`.

  Only a row that still holds the old default is moved: someone who deliberately
  set the floor to fable meant it, and this is not the place to argue.
  """
  use Ecto.Migration

  def up do
    execute """
    UPDATE settings
    SET value = '{"v": "sonnet"}'::jsonb, updated_at = NOW()
    WHERE key = 'model_floor' AND value->>'v' = 'fable'
    """
  end

  # Putting the lock back would be restoring a bug, not a preference.
  def down, do: :ok
end
