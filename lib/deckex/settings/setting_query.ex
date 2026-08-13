defmodule Deckex.Settings.SettingQuery do
  @moduledoc "All reads of stored settings."

  alias Deckex.Repo
  alias Deckex.Settings.Setting

  @doc "Every stored setting, as a map of key string to raw value."
  @spec all() :: %{String.t() => term()}
  def all do
    Setting
    |> Repo.all()
    |> Map.new(fn %{key: key, value: %{"v" => value}} -> {key, value} end)
  end

  @doc "One stored setting's value, or nil."
  @spec get(atom()) :: term() | nil
  def get(key) do
    case Repo.get(Setting, to_string(key)) do
      nil -> nil
      %{value: %{"v" => value}} -> value
    end
  end
end
