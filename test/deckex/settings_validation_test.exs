defmodule Deckex.SettingsValidationTest do
  @moduledoc """
  What the settings form is allowed to store.

  The baselines are the numbers every measurement in this app is compared
  against — the land target, the interaction target, how many blockers count as
  defence. Validation checked that the override was *a map* and stopped there,
  so a typo in one box wrote a string into the middle of it and every lens that
  read that field afterwards was comparing a number to `"abc"`.
  """
  use Deckex.DataCase, async: true

  alias Deckex.Error
  alias Deckex.Settings

  describe "a baseline override" do
    test "takes a number" do
      assert {:ok, _saved} = Settings.put(:baselines, %{"land_base" => 38})
      assert Settings.baselines().land_base == 38
    end

    # The bug: `is_map/1` was the whole check, so this was stored and every
    # measurement comparing against `land_base` then met a string.
    test "refuses a value that is not a number" do
      assert {:error, %Error{code: :invalid_setting} = error} =
               Settings.put(:baselines, %{"land_base" => "abc"})

      assert error.message =~ "land_base"
    end

    test "refuses a negative or zero target" do
      assert {:error, %Error{}} = Settings.put(:baselines, %{"land_base" => 0})
      assert {:error, %Error{}} = Settings.put(:baselines, %{"land_base" => -3})
    end

    test "names the offending field, not just the group" do
      {:error, error} = Settings.put(:baselines, %{"interaction_target" => "muitos"})

      assert error.message =~ "interaction_target"
      assert error.message =~ "muitos"
    end

    # A field renamed in code leaves a stale key in the stored map, and the
    # form submits the whole map on every edit — refusing the stale key would
    # lock all nineteen boxes over a rename nobody made today. Reading already
    # ignores them.
    test "a stale field from a rename does not lock the form" do
      assert {:ok, _saved} = Settings.put(:baselines, %{"campo_que_nao_existe" => 3})
      assert Settings.baselines().land_base == 36
    end

    test "a stale field alongside a bad one still reports the bad one" do
      assert {:error, %Error{} = error} =
               Settings.put(:baselines, %{"campo_antigo" => 1, "land_base" => "abc"})

      assert error.message =~ "land_base"
    end

    test "an empty override is valid — it means no override at all" do
      assert {:ok, _saved} = Settings.put(:baselines, %{})
    end
  end

  describe "the other settings" do
    test "an integer field refuses junk" do
      assert {:error, %Error{}} = Settings.put(:ceiling_card, "abc")
    end

    test "an option field refuses a value outside its options" do
      assert {:error, %Error{}} = Settings.put(:claude_model, "gpt")
    end
  end
end
