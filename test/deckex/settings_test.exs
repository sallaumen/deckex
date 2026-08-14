defmodule Deckex.SettingsTest do
  use Deckex.DataCase, async: true

  alias Deckex.Analysis.Baselines
  alias Deckex.Error
  alias Deckex.Settings
  alias Deckex.Settings.Registry

  describe "Registry" do
    test "declares the model with its options" do
      assert {:ok, entry} = Registry.fetch(:claude_model)

      assert entry.type == :string
      assert "sonnet" in entry.options
      assert "opus" in entry.options
    end

    test "declares the Moxfield User-Agent" do
      assert {:ok, %{type: :string}} = Registry.fetch(:moxfield_user_agent)
    end

    test "declares the baselines as one map" do
      assert {:ok, %{type: :baselines}} = Registry.fetch(:baselines)
    end

    test "does not know an invented key" do
      assert :error = Registry.fetch(:banana)
    end

    test "every entry carries a pt-BR label and a group" do
      for entry <- Registry.entries() do
        assert is_binary(entry.label)
        assert entry.label != ""
        assert entry.group in [:ai, :budget, :moxfield, :analysis]
      end
    end
  end

  describe "get/1" do
    test "falls back to the registry default when nothing is stored" do
      assert Settings.get(:claude_model) == "sonnet"
    end

    test "returns what was stored" do
      {:ok, _value} = Settings.put(:claude_model, "opus")

      assert Settings.get(:claude_model) == "opus"
    end

    test "raises on a key the registry does not declare" do
      assert_raise ArgumentError, fn -> Settings.get(:banana) end
    end
  end

  describe "put/2" do
    test "rejects a value outside the declared options" do
      assert {:error, %Error{code: :invalid_setting}} = Settings.put(:claude_model, "gpt-quatro")
    end

    test "rejects a value of the wrong type" do
      assert {:error, %Error{code: :invalid_setting}} = Settings.put(:claude_model, 42)
    end

    test "rejects an unknown key" do
      assert {:error, %Error{code: :invalid_setting}} = Settings.put(:banana, "x")
    end

    test "overwrites rather than duplicating" do
      {:ok, _first} = Settings.put(:claude_model, "opus")
      {:ok, _second} = Settings.put(:claude_model, "fable")

      assert Settings.get(:claude_model) == "fable"
    end
  end

  describe "all/0" do
    test "returns every key, stored or default" do
      {:ok, _value} = Settings.put(:claude_model, "opus")

      all = Settings.all()

      assert all[:claude_model] == "opus"
      assert all[:moxfield_user_agent] != nil
    end
  end

  describe "baselines/0" do
    test "returns the documented defaults when nothing is overridden" do
      assert %Baselines{land_base: 36, ramp_target: 10} = Settings.baselines()
    end

    test "applies an override without touching the rest" do
      {:ok, _value} = Settings.put(:baselines, %{"land_base" => 38})

      baselines = Settings.baselines()

      assert baselines.land_base == 38
      assert baselines.ramp_target == 10
    end

    test "ignores an override for a field Baselines does not have" do
      {:ok, _value} = Settings.put(:baselines, %{"banana" => 1})

      assert %Baselines{} = Settings.baselines()
    end
  end

  describe "model/0 and ceilings/1" do
    test "model is the configured model" do
      {:ok, _value} = Settings.put(:claude_model, "opus")

      assert Settings.model() == "opus"
    end

    test "a zero budget means no ceiling, not a ceiling of zero" do
      assert Settings.ceilings(:budget).card == nil

      {:ok, _value} = Settings.put(:budget_max_brl, 30)
      assert Settings.ceilings(:budget).card == 30
    end
  end
end
