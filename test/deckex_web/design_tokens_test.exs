defmodule DeckexWeb.DesignTokensTest do
  @moduledoc """
  Guards against a class of bug that is invisible in review and in the browser:
  a Tailwind utility naming a token that does not exist.

  `class="text-hero"` compiles, renders, and does nothing — the page title
  silently falls back to the body size and nobody notices. Tailwind cannot warn,
  because an unknown utility is indistinguishable from a class name meant for
  something else. This test found exactly that on four `<h1>`s.

  The rule: a class using one of our token prefixes must name a token declared
  in the `@theme` block, or appear in `@builtins` below. Adding to `@builtins`
  is deliberate — it means "this is a structural Tailwind utility with no design
  token behind it", which is true of `text-center` and false of `text-hero`.
  """
  use ExUnit.Case, async: true

  @theme "assets/css/app.css"
  @sources "lib"

  # Tailwind resolves each prefix against particular token namespaces: `text-`
  # against both the type scale and the palette (text-body, text-ink).
  @namespaces %{
    "text" => ["text", "color"],
    "bg" => ["color"],
    "border" => ["color", "radius"],
    "rounded" => ["radius"],
    "shadow" => ["shadow"],
    "font" => ["font"],
    "aspect" => ["aspect"],
    "fill" => ["color"],
    "stroke" => ["color"],
    "ring" => ["color"],
    "outline" => ["color"],
    "divide" => ["color"],
    "accent" => ["color"],
    "caret" => ["color"]
  }

  # Structural Tailwind utilities that share a prefix with our tokens but carry
  # no design decision — alignment, borders as geometry, weights.
  @builtins ~w(
    text-center text-left text-right text-justify text-nowrap
    font-semibold font-bold font-medium font-normal font-mono font-sans
    border-0 border-2 border-t border-b border-l border-r border-x border-y
    border-l-2
    border-collapse border-separate divide-y divide-x
    rounded-full rounded-none rounded-t-xs
    bg-current
  )

  test "every utility using a token prefix names a token that exists" do
    tokens = tokens()

    unresolved =
      @sources
      |> classes()
      |> Enum.reject(&(&1 in @builtins))
      |> Enum.filter(&prefixed?/1)
      |> Enum.reject(&resolves?(&1, tokens))
      |> Enum.uniq()
      |> Enum.sort()

    assert unresolved == [],
           """
           These classes use a design-token prefix but name nothing declared in
           #{@theme}, so they render as nothing:

           #{Enum.map_join(unresolved, "\n", &"  #{&1}")}

           Use a token that exists, declare the missing one in the @theme block,
           or — if it is a structural Tailwind utility — add it to @builtins.
           """
  end

  defp tokens do
    ~r/--(color|font|text|radius|shadow|aspect)-([a-z0-9-]+):/
    |> Regex.scan(File.read!(@theme))
    |> Enum.group_by(&Enum.at(&1, 1), &Enum.at(&1, 2))
  end

  # Only what is actually inside a `class` attribute — `fill-rule="evenodd"` on
  # an SVG path is not a class, and neither is prose in a comment.
  defp classes(dir) do
    dir
    |> Path.join("**/*.ex*")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      ~r/class=(?:"([^"]*)"|\{([^}]*)\})/s
      |> Regex.scan(File.read!(path))
      |> Enum.flat_map(&(&1 |> Enum.drop(1) |> Enum.join(" ") |> String.split(~r/[\s"]+/)))
    end)
    |> Enum.map(&bare/1)
    |> Enum.reject(&(&1 == ""))
  end

  # `2xl:text-heading/50` → `text-heading`: drop responsive/state variants and
  # any opacity modifier.
  defp bare(class) do
    class |> String.split(":") |> List.last() |> String.replace(~r{/\d+$}, "")
  end

  defp prefixed?(class) do
    case String.split(class, "-", parts: 2) do
      # Arbitrary values (`text-[13px]`) are explicit by nature, not tokens.
      [prefix, name] -> Map.has_key?(@namespaces, prefix) and not String.starts_with?(name, "[")
      _single_word -> false
    end
  end

  defp resolves?(class, tokens) do
    [prefix, name] = String.split(class, "-", parts: 2)

    Enum.any?(@namespaces[prefix], &(name in Map.get(tokens, &1, [])))
  end
end
