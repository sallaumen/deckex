defmodule Deckex.Settings.Setting do
  @moduledoc """
  One stored setting.

  The primary key is the setting's own name — there is exactly one row per key
  by construction, so "which value wins" is never a question.

  The value is wrapped in a map (`%{"v" => value}`) because a jsonb column holds
  an object, not a bare scalar, and a wrapper is simpler than a column per type.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:key, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime]

  @type t :: %__MODULE__{}

  schema "settings" do
    field :value, :map

    timestamps()
  end

  @doc "Builds a changeset for a stored setting."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value])
    |> validate_required([:key, :value])
  end
end
