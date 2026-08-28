defmodule DeckexWeb.OneControlStyleTest do
  @moduledoc """
  Every form control in the app wears one style.

  It did not, and nobody decided that: each screen wrote its own class string,
  so the same kind of box appeared with `px-2`, `px-3` and `px-4` and with two
  different type sizes, side by side in the same form. Duplication of a literal
  is how a design system erodes — quietly, one screen at a time, with no commit
  that looks wrong on its own.

  This test is the guard. A new control uses `UI.field/1`, or borrows
  `UI.control_class/0` when it genuinely needs its own markup; writing the
  string out again fails here.
  """
  use ExUnit.Case, async: true

  @screens Path.wildcard("lib/deckex_web/live/*.ex") ++
             Path.wildcard("lib/deckex_web/components/*.ex")

  # The tell: a form control's background and border written together as a
  # literal. `bg-inlay/50` and friends are panels wearing the same token at a
  # different opacity, and a button group is not a control either — the solid
  # background plus horizontal padding is what marks a box you type into.
  @hand_rolled ~r|class="[^"]*border-hairline-soft bg-inlay px-\d[^"]*"|

  test "no screen writes its own control styling" do
    offenders =
      for path <- @screens,
          line <- String.split(File.read!(path), "\n"),
          Regex.match?(@hand_rolled, line),
          do: "#{Path.basename(path)}: #{String.trim(line)}"

    assert offenders == [],
           """
           Controle com estilo próprio. Use `<.field>` ou `control_class()`:

           #{Enum.join(offenders, "\n")}
           """
  end

  # The component is the way in; the class is the escape hatch for markup the
  # component does not model. Both have to keep existing for the rule to hold.
  test "the shared control style is still exported" do
    assert is_binary(DeckexWeb.UI.control_class())
    assert DeckexWeb.UI.control_class() =~ "px-3 py-2"
    assert function_exported?(DeckexWeb.UI, :field, 1)
  end
end
