defmodule DeckexWeb.TouchTargetTest do
  @moduledoc """
  A guard for a bug that shipped looking fixed.

  The root font-size here is 13px, so a rem-based utility renders at 0.8125×
  its nominal value: `min-h-11` reads as 44 and paints 35.75. Thirty-eight hit
  areas were written as 44 and shipped as 36, and nothing in the suite could
  tell — the class was present, spelled correctly, and wrong.

  A touch target is a physical size. It measures from `--size-touch`, in px,
  and this test fails the moment a rem-based one comes back.
  """
  use ExUnit.Case, async: true

  @templates Path.wildcard("lib/deckex_web/**/*.ex") ++
               Path.wildcard("lib/deckex_web/**/*.heex")

  # Tailwind's numeric scale is rem-based, so these never mean 44px here.
  @rem_scaled ~w(min-h-11 min-h-12 size-11 size-12 h-11 w-11)

  test "no hit area is sized from the rem scale" do
    offenders =
      for path <- @templates,
          source = markup(path),
          class <- @rem_scaled,
          String.contains?(source, class),
          do: "#{Path.relative_to_cwd(path)}: #{class}"

    assert offenders == [],
           """
           Estes alvos de toque usam a escala rem, que com root de 13px rende
           36px em vez de 44px. Use `min-h-touch` / `size-touch`:

           #{Enum.join(offenders, "\n")}
           """
  end

  # <summary> is a control that looks like text, which is how ten of them
  # shipped at 18px while every <button> on the page was fixed.
  test "every summary that acts as a control is sized like one" do
    offenders =
      for path <- @templates,
          source = markup(path),
          line <- String.split(source, "\n"),
          String.contains?(line, "<summary"),
          not String.contains?(line, "min-h-touch"),
          do: "#{Path.relative_to_cwd(path)}: #{String.trim(line)}"

    assert offenders == [], Enum.join(offenders, "\n")
  end

  test "the touch token is declared, in px" do
    tokens = File.read!("assets/css/tokens.css")

    assert tokens =~ ~r/--size-touch:\s*44px/
  end

  test "the token is exposed as a Tailwind utility" do
    assert File.read!("assets/css/app.css") =~ "--spacing-touch: var(--size-touch)"
  end

  # A comment that *names* the tag is not a control that ships. The `<summary>`
  # guard flagged the comment explaining why the summary next to it had a hit
  # area — the guard reading its own documentation as a violation.
  defp markup(path), do: path |> File.read!() |> String.replace(~r/<%!--.*?--%>/s, "")
end
