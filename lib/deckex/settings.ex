defmodule Deckex.Settings do
  @moduledoc """
  The knobs: which model to ask, what to tell Moxfield we are, and where the
  analysis baselines sit.

  **`baselines/0` returns a struct, it does not inject one.** `Deckex.Analysis`
  is pure by contract and must never reach for a database; the caller loads the
  baselines here and passes them in. That is why this module builds a
  `%Baselines{}` rather than the lens asking for one.
  """

  alias Deckex.Analysis.Baselines
  alias Deckex.Error
  alias Deckex.Repo
  alias Deckex.Settings.Registry
  alias Deckex.Settings.Setting
  alias Deckex.Settings.SettingQuery

  @doc """
  The current value of `key` — stored if set, the registry default otherwise.

  Raises on an undeclared key: that is a typo in code, not a user mistake.
  """
  @spec get(atom()) :: term()
  def get(key) do
    case Registry.fetch(key) do
      {:ok, entry} -> stored_or_default(key, entry)
      :error -> raise ArgumentError, "unknown setting #{inspect(key)}"
    end
  end

  @doc "Every declared setting's current value."
  @spec all() :: %{atom() => term()}
  def all do
    stored = SettingQuery.all()

    Map.new(Registry.entries(), fn entry ->
      {entry.key, Map.get(stored, to_string(entry.key), entry.default)}
    end)
  end

  @doc "Stores `value` for `key` after checking it against the registry."
  @spec put(atom(), term()) :: {:ok, term()} | {:error, Error.t()}
  def put(key, value) do
    with {:ok, entry} <- fetch_entry(key),
         :ok <- validate(entry, value) do
      %Setting{}
      |> Setting.changeset(%{key: to_string(key), value: %{"v" => value}})
      |> Repo.insert!(on_conflict: {:replace, [:value, :updated_at]}, conflict_target: :key)

      {:ok, value}
    end
  end

  @doc "The model to ask."
  @spec model() :: String.t()
  def model, do: get(:claude_model)

  @doc """
  The weakest model allowed to propose a card change, default `"fable"`.

  Analysis may run on anything. A suggestion to cut a card from a real deck is
  a different kind of answer, and the owner should not have to check which
  model produced it.
  """
  @spec model_floor() :: String.t()
  def model_floor, do: get(:model_floor)

  @doc """
  The price ceilings a lens must respect, in reais, or `nil` where there is
  none.

  `:upgrade` is capped too, which sounds like a contradiction — the lens is
  called "sem olhar preço". It is not: past a certain number a suggestion
  stops being an upgrade to this deck and becomes a different deck with a
  bigger budget. Lands get their own, lower ceiling because an expensive land
  is the easiest way to spend a lot and win nothing.
  """
  @spec ceilings(atom()) :: %{card: pos_integer() | nil, land: pos_integer() | nil}
  def ceilings(:budget), do: %{card: positive(:budget_max_brl), land: positive(:budget_max_brl)}

  # The card ceiling here is the WALL, not the exception line: `upgrade_max_brl`
  # (600) is enforced by `Deckex.Budget` as a quota — a pricier card spends one
  # of the two exception slots — and `upgrade_card_max_brl` (800) is where the
  # engine refuses outright, slots or no slots. Distinct on purpose: a wall at
  # the exception line would make the slots unreachable, and no wall at all
  # left the launcher showing an empty field the owner had to fill every time.
  # Lands keep their own, lower wall: a land is the easiest way to spend a lot
  # and win nothing, and no exception has ever been worth spending on one.
  def ceilings(:upgrade),
    do: %{card: positive(:upgrade_card_max_brl), land: positive(:upgrade_land_max_brl)}

  def ceilings(_lens), do: %{card: nil, land: nil}

  defp positive(key) do
    case get(key) do
      value when is_integer(value) and value > 0 -> value
      _no_ceiling -> nil
    end
  end

  @doc """
  The analysis baselines with any stored overrides applied.

  Unknown keys in the override map are ignored rather than raising: a baseline
  removed from the struct should not brick the settings screen.
  """
  @spec baselines() :: Baselines.t()
  def baselines do
    fields = Baselines.default() |> Map.from_struct() |> Map.keys() |> MapSet.new()

    :baselines
    |> get()
    |> Enum.reduce(Baselines.default(), fn {field, value}, baselines ->
      apply_override(baselines, safe_atom(field, fields), value)
    end)
  end

  defp stored_or_default(key, entry) do
    case SettingQuery.get(key) do
      nil -> entry.default
      value -> value
    end
  end

  defp apply_override(baselines, nil, _value), do: baselines
  defp apply_override(baselines, field, value), do: Map.put(baselines, field, value)

  defp fetch_entry(key) do
    case Registry.fetch(key) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, invalid("Não conheço a configuração #{inspect(key)}.", %{key: key})}
    end
  end

  defp validate(%{type: :string, options: nil}, value) when is_binary(value), do: :ok

  defp validate(%{type: :string, options: options} = entry, value) when is_binary(value) do
    if value in options do
      :ok
    else
      {:error,
       invalid("#{entry.label}: “#{value}” não é uma opção válida.", %{
         key: entry.key,
         options: options
       })}
    end
  end

  defp validate(%{type: :integer}, value) when is_integer(value) and value >= 0, do: :ok
  defp validate(%{type: :number}, value) when is_number(value) and value > 0, do: :ok
  # `is_map/1` used to be the whole check here, and the baselines are the
  # numbers every measurement in this app is compared against — the land
  # target, the interaction target, how many blockers count as defence. A typo
  # in one box wrote `"abc"` into the middle of the struct, passed because the
  # container was still a map, and every lens that read that field afterwards
  # was comparing a number to a string.
  defp validate(%{type: :baselines}, value) when is_map(value) do
    fields = Baselines.default() |> Map.from_struct() |> Map.keys() |> MapSet.new()

    # Only the fields that still exist are judged. A field renamed in code
    # leaves a stale key in the stored map, and the form submits the whole map
    # on every edit — refusing the stale key would lock all nineteen boxes
    # over a rename nobody made today. Reading already ignores them.
    value
    |> Enum.filter(fn {field, _number} -> safe_atom(field, fields) end)
    |> Enum.reduce_while(:ok, fn {field, number}, :ok ->
      case baseline_problem(field, number) do
        nil -> {:cont, :ok}
        problem -> {:halt, {:error, invalid(problem, %{field: field, value: inspect(number)})}}
      end
    end)
  end

  defp validate(entry, value) do
    {:error, invalid("#{entry.label}: valor inválido.", %{key: entry.key, value: inspect(value)})}
  end

  # The field name goes in the message. "Baselines: valor inválido" on a form
  # with nineteen boxes tells the owner to go and find it himself.
  defp baseline_problem(field, number) do
    cond do
      not is_number(number) -> "#{field}: “#{number}” não é um número."
      number <= 0 -> "#{field}: precisa ser maior que zero."
      true -> nil
    end
  end

  defp invalid(message, details), do: Error.new(:invalid_setting, message, details)

  # String.to_existing_atom would raise on a field removed from Baselines; this
  # narrows to fields the struct actually has, so a stale override is ignored.
  defp safe_atom(field, allowed) do
    Enum.find(allowed, &(to_string(&1) == to_string(field)))
  end
end
