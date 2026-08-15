defmodule Deckex.Repo.Migrations.AddPowerToughnessToCards do
  use Ecto.Migration

  def change do
    alter table(:cards) do
      # Strings, not integers: Magic prints "*", "1+*" and "∞".
      add :power, :string
      add :toughness, :string
    end
  end
end
