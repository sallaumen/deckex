defmodule DeckexWeb.UI.Format do
  @moduledoc """
  Pure display formatters for the "A Mesa" design system.

  This module answers three questions exactly once, in code, so that no
  component ever writes a hex value:

    * how a mana cost string decomposes into renderable symbols
      (`mana_symbols/1`),
    * which design token a mana colour uses (`color_token/1`),
    * which design token a finding severity uses (`severity_token/1`).

  Everything here takes primitives — strings, atoms, numbers — and returns
  primitives. There is no markup and no domain struct, so the whole module is
  unit-testable without the database. Function components live in
  `DeckexWeb.UI`.

  User-facing strings are pt-BR by the project language rule. Card names are
  never translated and never pass through here.
  """

  @typedoc """
  One renderable piece of a mana cost.

    * `:kind` — how it should be drawn.
    * `:raw` — the original text, braces included (`"{2/W}"`).
    * `:label` — the text between the braces, upcased (`"2/W"`).
    * `:colors` — the pip-renderable colour codes behind it, in the order they
      appear. A generic half of a monocoloured hybrid is reported as `"C"`, so
      `colors` is always safe to map straight onto tokens.
  """
  @type symbol :: %{
          kind: kind(),
          raw: String.t(),
          label: String.t(),
          colors: [String.t()]
        }

  @type kind ::
          :color
          | :generic
          | :variable
          | :hybrid
          | :phyrexian
          | :snow
          | :tap
          | :untap
          | :energy
          | :unknown

  @type severity :: :critical | :warning | :healthy | :info
  @type tone :: severity() | :neutral

  @symbol_pattern ~r/\{([^{}]+)\}/

  # WUBRG, the order every Magic player already reads colours in.
  @color_order ~w(W U B R G C)

  @color_tokens %{
    "W" => "--mana-w",
    "U" => "--mana-u",
    "B" => "--mana-b",
    "R" => "--mana-r",
    "G" => "--mana-g",
    "C" => "--mana-c"
  }

  @color_labels %{
    "W" => "Branco",
    "U" => "Azul",
    "B" => "Preto",
    "R" => "Vermelho",
    "G" => "Verde",
    "C" => "Incolor"
  }

  @color_glyphs %{
    "W" => :sun,
    "U" => :drop,
    "B" => :skull,
    "R" => :flame,
    "G" => :tree,
    "C" => :gem
  }

  @doc """
  The five colours plus colourless, in WUBRG order.

      iex> DeckexWeb.UI.Format.colors()
      ["W", "U", "B", "R", "G", "C"]
  """
  @spec colors() :: [String.t()]
  def colors, do: @color_order

  @doc """
  The CSS custom property name for a mana colour.

  Returns the name, not a `var()` call, so it can be dropped into a custom
  property declaration. Unknown codes fall back to colourless rather than
  raising — a card with a mana symbol we have never seen still renders.

      iex> DeckexWeb.UI.Format.color_token("B")
      "--mana-b"
  """
  @spec color_token(String.t() | nil) :: String.t()
  def color_token(code) when is_binary(code) do
    Map.get(@color_tokens, String.upcase(code), "--mana-c")
  end

  def color_token(_code), do: "--mana-c"

  @doc """
  The `var()` reference for a mana colour, ready for a `style` attribute.

      iex> DeckexWeb.UI.Format.color_var("g")
      "var(--mana-g)"
  """
  @spec color_var(String.t() | nil) :: String.t()
  def color_var(code), do: "var(#{color_token(code)})"

  @doc """
  The pt-BR name of a mana colour, for tooltips and screen readers.

      iex> DeckexWeb.UI.Format.color_label("U")
      "Azul"
  """
  @spec color_label(String.t() | nil) :: String.t()
  def color_label(code) when is_binary(code) do
    Map.get(@color_labels, String.upcase(code), "Incolor")
  end

  def color_label(_code), do: "Incolor"

  @doc """
  Sorts a colour identity into WUBRG order, dropping anything unrecognised.

      iex> DeckexWeb.UI.Format.sort_colors(["G", "U", "W"])
      ["W", "U", "G"]
  """
  @spec sort_colors([String.t()] | nil) :: [String.t()]
  def sort_colors(codes) when is_list(codes) do
    codes
    |> Enum.map(&String.upcase/1)
    |> Enum.filter(&Map.has_key?(@color_tokens, &1))
    |> Enum.uniq()
    |> Enum.sort_by(fn code -> Enum.find_index(@color_order, &(&1 == code)) end)
  end

  def sort_colors(_codes), do: []

  @doc """
  Splits a Scryfall mana cost into renderable symbols.

  Handles generic and variable costs, the five colours plus colourless, snow,
  hybrid (`{W/U}`) and monocoloured hybrid (`{2/W}`), Phyrexian (`{U/P}`), and
  the tap/untap symbols. Anything unrecognised comes back as `:unknown`
  carrying its own text, so an unfamiliar symbol degrades to a readable pip
  instead of disappearing.

  `nil` and `""` return `[]` — a land has no mana cost, and that is not an
  error.

      iex> DeckexWeb.UI.Format.mana_symbols("{1}{G}") |> Enum.map(& &1.kind)
      [:generic, :color]
  """
  @spec mana_symbols(String.t() | nil) :: [symbol()]
  def mana_symbols(cost) when is_binary(cost) do
    @symbol_pattern
    |> Regex.scan(cost, capture: :all_but_first)
    |> Enum.map(fn [body] -> symbol(body) end)
  end

  def mana_symbols(_cost), do: []

  defp symbol(body) do
    label = String.upcase(body)

    label
    |> String.split("/")
    |> classify(%{raw: "{" <> body <> "}", label: label})
  end

  defp classify([part], meta), do: single(part, meta)

  defp classify(parts, meta) do
    case Enum.split_with(parts, &(&1 == "P")) do
      {[], halves} -> build(:hybrid, meta, Enum.map(halves, &half_color/1))
      {_phyrexian, halves} -> build(:phyrexian, meta, Enum.map(halves, &half_color/1))
    end
  end

  # A half that is not a colour code is the generic half of `{2/W}`; it renders
  # as a colourless disc with its number printed over it.
  defp half_color(part) do
    if Map.has_key?(@color_tokens, part), do: part, else: "C"
  end

  defp single("T", meta), do: build(:tap, meta, [])
  defp single("Q", meta), do: build(:untap, meta, [])
  defp single("S", meta), do: build(:snow, meta, [])
  defp single("E", meta), do: build(:energy, meta, [])
  defp single("P", meta), do: build(:phyrexian, meta, [])
  defp single(part, meta) when part in ~w(X Y Z), do: build(:variable, meta, [])

  defp single(part, meta) do
    cond do
      Map.has_key?(@color_tokens, part) -> build(:color, meta, [part])
      numeric?(part) -> build(:generic, meta, [])
      true -> build(:unknown, meta, [])
    end
  end

  defp numeric?(part), do: match?({_int, ""}, Integer.parse(part))

  defp build(kind, meta, colors) do
    %{kind: kind, raw: meta.raw, label: meta.label, colors: colors}
  end

  @doc """
  The CSS `background` value for a symbol's pip.

  A hybrid gets a hard-stop diagonal across its two colours — the printed
  symbol's own device — and everything else gets a flat token.

      iex> DeckexWeb.UI.Format.mana_symbols("{R}") |> hd() |> DeckexWeb.UI.Format.pip_background()
      "var(--mana-r)"
  """
  @spec pip_background(symbol()) :: String.t()
  def pip_background(%{kind: :hybrid, colors: [left, right]}) do
    "linear-gradient(135deg, #{color_var(left)} 0 50%, #{color_var(right)} 50% 100%)"
  end

  def pip_background(%{colors: [code | _rest]}), do: color_var(code)
  def pip_background(%{}), do: color_var("C")

  @doc """
  Which drawn glyph a pip carries, or `nil` when the pip prints text instead.

  The return is an atom naming a shape, never markup — `DeckexWeb.UI.mana_glyph/1`
  owns the paths.
  """
  @spec pip_glyph(symbol()) :: atom() | nil
  def pip_glyph(%{kind: :color, colors: [code | _rest]}), do: Map.get(@color_glyphs, code)
  def pip_glyph(%{kind: :phyrexian}), do: :phyrexian
  def pip_glyph(%{kind: :snow}), do: :snow
  def pip_glyph(%{kind: :tap}), do: :tap
  def pip_glyph(%{kind: :untap}), do: :untap
  def pip_glyph(%{}), do: nil

  @doc """
  The text a pip prints, or `nil` when it carries a glyph instead.

  A hybrid prints only its generic half (`{2/W}` prints `"2"`); a two-colour
  hybrid prints nothing, because the split disc already says which two colours
  it is and two half-size glyphs are illegible at pip scale.
  """
  @spec pip_text(symbol()) :: String.t() | nil
  def pip_text(%{kind: kind, label: label}) when kind in [:generic, :variable, :unknown],
    do: label

  def pip_text(%{kind: :energy}), do: "E"

  def pip_text(%{kind: :hybrid, label: label}) do
    [head | _rest] = String.split(label, "/")
    if numeric?(head), do: head
  end

  def pip_text(%{}), do: nil

  @doc """
  The pt-BR name of a single symbol, lowercase, for composing an accessible
  description.

      iex> DeckexWeb.UI.Format.mana_symbols("{3}") |> hd() |> DeckexWeb.UI.Format.symbol_label()
      "3 genérico"
  """
  @spec symbol_label(symbol()) :: String.t()
  def symbol_label(%{kind: :color, colors: [code | _rest]}),
    do: String.downcase(color_label(code))

  def symbol_label(%{kind: :generic, label: label}), do: "#{label} genérico"
  def symbol_label(%{kind: :variable, label: label}), do: label
  def symbol_label(%{kind: :snow}), do: "neve"
  def symbol_label(%{kind: :tap}), do: "virar"
  def symbol_label(%{kind: :untap}), do: "desvirar"
  def symbol_label(%{kind: :energy}), do: "energia"

  def symbol_label(%{kind: :hybrid, label: label}) do
    "híbrido " <> Enum.map_join(String.split(label, "/"), " ou ", &half_label/1)
  end

  def symbol_label(%{kind: :phyrexian, colors: []}), do: "phyrexiano"

  def symbol_label(%{kind: :phyrexian, colors: [code | _rest]}),
    do: "#{String.downcase(color_label(code))} phyrexiano"

  def symbol_label(%{label: label}), do: label

  defp half_label(part) do
    if Map.has_key?(@color_tokens, part), do: String.downcase(color_label(part)), else: part
  end

  @doc """
  The accessible description of a whole mana cost, in pt-BR.

      iex> DeckexWeb.UI.Format.mana_cost_label("{2}{U}")
      "Custo de mana: 2 genérico, azul"
  """
  @spec mana_cost_label(String.t() | nil) :: String.t()
  def mana_cost_label(cost) do
    case mana_symbols(cost) do
      [] -> "Sem custo de mana"
      symbols -> "Custo de mana: " <> Enum.map_join(symbols, ", ", &symbol_label/1)
    end
  end

  @doc """
  The CSS custom property name for a finding severity.

  `:info` deliberately resolves to a neutral token: a note is not an alarm, and
  only alarms get a hue (see The One-Legend Rule in `DESIGN.md`).

      iex> DeckexWeb.UI.Format.severity_token(:critical)
      "--sev-critical"
  """
  @spec severity_token(severity()) :: String.t()
  def severity_token(:critical), do: "--sev-critical"
  def severity_token(:warning), do: "--sev-warning"
  def severity_token(:healthy), do: "--sev-healthy"
  def severity_token(_severity), do: "--sev-info"

  @doc "The `var()` reference for a finding severity, ready for a `style` attribute."
  @spec severity_var(severity()) :: String.t()
  def severity_var(severity), do: "var(#{severity_token(severity)})"

  @doc """
  The CSS custom property name for a component tone.

  Same ramp as `severity_token/1` plus `:neutral`, which is the resting state of
  a stat tile or a curve bar: ink, no hue at all.
  """
  @spec tone_token(tone()) :: String.t()
  def tone_token(:neutral), do: "--ink"
  def tone_token(tone), do: severity_token(tone)

  @doc "The `var()` reference for a component tone, ready for a `style` attribute."
  @spec tone_var(tone()) :: String.t()
  def tone_var(tone), do: "var(#{tone_token(tone)})"

  @doc """
  The pt-BR label of a finding severity.

      iex> DeckexWeb.UI.Format.severity_label(:warning)
      "Atenção"
  """
  @spec severity_label(severity()) :: String.t()
  def severity_label(:critical), do: "Crítico"
  def severity_label(:warning), do: "Atenção"
  def severity_label(:healthy), do: "Saudável"
  def severity_label(_severity), do: "Nota"

  @doc """
  Formats a number for display with a pt-BR decimal comma.

  Integers print bare — an average of exactly 3 is `"3"`, not `"3,0"` — and
  `nil` prints an em dash so an unmeasured value is visibly absent rather than
  silently zero.

      iex> DeckexWeb.UI.Format.decimal(3.24)
      "3,2"
  """
  @spec decimal(number() | nil, non_neg_integer()) :: String.t()
  def decimal(value, places \\ 1)
  def decimal(nil, _places), do: "—"
  def decimal(value, _places) when is_integer(value), do: Integer.to_string(value)

  def decimal(value, places) when is_float(value) do
    rounded = Float.round(value, places)

    if rounded == Float.round(rounded, 0) do
      rounded |> trunc() |> Integer.to_string()
    else
      rounded |> :erlang.float_to_binary(decimals: places) |> String.replace(".", ",")
    end
  end

  @doc """
  Formats a 0.0–1.0 share as a whole percentage.

      iex> DeckexWeb.UI.Format.percent(0.184)
      "18%"
  """
  @spec percent(number() | nil) :: String.t()
  def percent(nil), do: "—"

  def percent(share) when is_number(share) do
    "#{round(share * 100)}%"
  end
end
