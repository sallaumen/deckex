defmodule Deckex.Schema do
  @moduledoc """
  Base schema for every table in the application: UUID v7 primary keys and UTC
  timestamps. `use Deckex.Schema` instead of `Ecto.Schema` directly so the key
  strategy is declared once rather than copied into every schema — and so
  foreign keys automatically agree with the primary keys they point at.
  """

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema

      @primary_key {:id, Uniq.UUID, version: 7, autogenerate: true}
      @foreign_key_type Uniq.UUID
      @timestamps_opts [type: :utc_datetime]
    end
  end
end
