defmodule DeckexWeb.SettingsFormTest do
  @moduledoc """
  How the settings panel behaves when what you typed is wrong.

  It held **one** error message for a form with nineteen baseline boxes plus
  nine settings, printed it at the top, and cleared it on the next re-render
  from the parent — so a typo in the eighth box produced a message above the
  fold, next to none of them, that could vanish before it was read. Meanwhile
  the box kept showing the rejected value as if it had been accepted.
  """
  use DeckexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Deckex.Settings

  defp open(conn) do
    {:ok, live, _html} = live(conn, ~p"/ajustes")
    live |> element("button[phx-click='open']") |> render_click()

    live
  end

  describe "a value the app refuses" do
    test "says why, under the field it belongs to", %{conn: conn} do
      live = open(conn)

      html =
        live
        |> form("#panel-usd_to_brl", %{setting: %{key: "usd_to_brl", value: "abc"}})
        |> render_change()

      assert html =~ "valor inválido"
      # The message is the field's own, addressed by the field's own id.
      assert html =~ ~s(id="panel-field-usd_to_brl-error")
      assert has_element?(live, "#panel-field-usd_to_brl[aria-invalid='true']")
    end

    test "keeps every other field clean", %{conn: conn} do
      live = open(conn)

      live
      |> form("#panel-usd_to_brl", %{setting: %{key: "usd_to_brl", value: "abc"}})
      |> render_change()

      refute has_element?(live, "#panel-field-claude_model[aria-invalid='true']")
    end

    # The old panel wiped its single error on any re-render from the parent.
    test "the message survives an unrelated update", %{conn: conn} do
      live = open(conn)

      live
      |> form("#panel-usd_to_brl", %{setting: %{key: "usd_to_brl", value: "abc"}})
      |> render_change()

      html =
        live
        |> form("#panel-claude_model", %{setting: %{key: "claude_model", value: "opus"}})
        |> render_change()

      assert html =~ ~s(id="panel-field-usd_to_brl-error")
    end

    test "and goes away when the field is fixed", %{conn: conn} do
      live = open(conn)

      live
      |> form("#panel-usd_to_brl", %{setting: %{key: "usd_to_brl", value: "abc"}})
      |> render_change()

      html =
        live
        |> form("#panel-usd_to_brl", %{setting: %{key: "usd_to_brl", value: "6"}})
        |> render_change()

      refute html =~ ~s(id="panel-field-usd_to_brl-error")
      assert Settings.get(:usd_to_brl) == 6
    end
  end

  describe "the baselines" do
    # One bad box printing its message under all nineteen of them is the same
    # bug in a different coat.
    test "a bad baseline is reported under that baseline only", %{conn: conn} do
      live = open(conn)

      html =
        live
        |> form("#panel-baseline-land_base", %{baseline: %{field: "land_base", value: "abc"}})
        |> render_change()

      assert html =~ ~s(id="panel-baseline-field-land_base-error")
      refute has_element?(live, "#panel-baseline-field-ramp_target[aria-invalid='true']")
    end

    # The one that mattered: these numbers feed every measurement in the app.
    test "a bad baseline never reaches the stored baselines", %{conn: conn} do
      live = open(conn)

      live
      |> form("#panel-baseline-land_base", %{baseline: %{field: "land_base", value: "abc"}})
      |> render_change()

      assert Settings.baselines().land_base == 36
    end

    test "a good one is stored and confirmed", %{conn: conn} do
      live = open(conn)

      html =
        live
        |> form("#panel-baseline-land_base", %{baseline: %{field: "land_base", value: "38"}})
        |> render_change()

      assert html =~ "salvo"
      assert Settings.baselines().land_base == 38
    end
  end
end
