defmodule DeckexWeb.UI.FormatTest do
  use ExUnit.Case, async: true

  alias DeckexWeb.UI.Format

  doctest Format

  describe "mana_symbols/1 — the shapes a real cost takes" do
    test "splits a generic-plus-colours cost in printed order" do
      assert [generic, g, u, r] = Format.mana_symbols("{3}{G}{U}{R}")

      assert %{kind: :generic, label: "3", colors: [], raw: "{3}"} = generic
      assert %{kind: :color, label: "G", colors: ["G"]} = g
      assert %{kind: :color, colors: ["U"]} = u
      assert %{kind: :color, colors: ["R"]} = r
    end

    test "reads X as a variable, not as a generic number" do
      assert [x, b1, b2, b3] = Format.mana_symbols("{X}{B}{B}{B}")

      assert %{kind: :variable, label: "X"} = x
      assert Enum.all?([b1, b2, b3], &(&1.kind == :color and &1.colors == ["B"]))
    end

    test "a hybrid carries both colours, in printed order" do
      assert [%{kind: :hybrid, label: "W/U", colors: ["W", "U"]}] = Format.mana_symbols("{W/U}")
    end

    test "a monocoloured hybrid reports its generic half as colourless" do
      assert [%{kind: :hybrid, label: "2/W", colors: ["C", "W"]}] = Format.mana_symbols("{2/W}")
    end

    test "phyrexian keeps its colour and drops the P" do
      assert [%{kind: :phyrexian, label: "U/P", colors: ["U"]}] = Format.mana_symbols("{U/P}")
    end

    test "handles the loose symbols an oracle text carries" do
      assert Enum.map(Format.mana_symbols("{T}{Q}{S}{C}{E}"), & &1.kind) ==
               [:tap, :untap, :snow, :color, :energy]
    end

    test "an unrecognised symbol degrades instead of disappearing" do
      assert [%{kind: :unknown, label: "HW", raw: "{HW}"}] = Format.mana_symbols("{HW}")
    end

    test "upcases lowercase input" do
      assert [%{kind: :color, colors: ["G"], label: "G"}] = Format.mana_symbols("{g}")
    end

    test "a land has no cost, and that is not an error" do
      assert Format.mana_symbols(nil) == []
      assert Format.mana_symbols("") == []
      assert Format.mana_symbols("Sorcery") == []
    end

    test "double-digit generic costs stay one symbol" do
      assert [%{kind: :generic, label: "10"}, %{kind: :color}] = Format.mana_symbols("{10}{R}")
    end
  end

  describe "pip rendering decisions" do
    test "a hybrid pip is a hard-stop diagonal across both tokens" do
      [hybrid] = Format.mana_symbols("{W/U}")

      assert Format.pip_background(hybrid) ==
               "linear-gradient(135deg, var(--mana-w) 0 50%, var(--mana-u) 50% 100%)"
    end

    test "every colour maps onto its own token" do
      for {code, token} <- [
            {"W", "--mana-w"},
            {"U", "--mana-u"},
            {"B", "--mana-b"},
            {"R", "--mana-r"},
            {"G", "--mana-g"},
            {"C", "--mana-c"}
          ] do
        assert Format.color_token(code) == token
      end
    end

    test "an unknown colour falls back to colourless rather than raising" do
      assert Format.color_token("Z") == "--mana-c"
      assert Format.color_token(nil) == "--mana-c"
    end

    test "coloured pips draw a glyph and print no text" do
      [g] = Format.mana_symbols("{G}")

      assert Format.pip_glyph(g) == :tree
      assert Format.pip_text(g) == nil
    end

    test "generic and variable pips print text and draw no glyph" do
      for cost <- ["{3}", "{X}"] do
        [symbol] = Format.mana_symbols(cost)

        assert Format.pip_glyph(symbol) == nil
        assert Format.pip_text(symbol) == symbol.label
      end
    end

    test "a monocoloured hybrid prints its generic half; a two-colour one prints nothing" do
      [mono] = Format.mana_symbols("{2/W}")
      [pair] = Format.mana_symbols("{B/G}")

      assert Format.pip_text(mono) == "2"
      assert Format.pip_text(pair) == nil
    end

    test "phyrexian draws its own mark over the colour's disc" do
      [symbol] = Format.mana_symbols("{U/P}")

      assert Format.pip_glyph(symbol) == :phyrexian
      assert Format.pip_background(symbol) == "var(--mana-u)"
    end
  end

  describe "accessible labels (pt-BR)" do
    test "describes a whole cost in reading order" do
      assert Format.mana_cost_label("{3}{G}{U}{R}") ==
               "Custo de mana: 3 genérico, verde, azul, vermelho"
    end

    test "names a hybrid as a choice between its halves" do
      assert Format.mana_cost_label("{2/W}") == "Custo de mana: híbrido 2 ou branco"
      assert Format.mana_cost_label("{B/G}") == "Custo de mana: híbrido preto ou verde"
    end

    test "names phyrexian mana" do
      assert Format.mana_cost_label("{U/P}") == "Custo de mana: azul phyrexiano"
    end

    test "a missing cost says so instead of rendering empty" do
      assert Format.mana_cost_label(nil) == "Sem custo de mana"
      assert Format.mana_cost_label("") == "Sem custo de mana"
    end
  end

  describe "sort_colors/1" do
    test "orders any identity into WUBRG" do
      assert Format.sort_colors(["G", "W", "R", "U", "B"]) == ["W", "U", "B", "R", "G"]
    end

    test "drops duplicates and anything that is not a colour" do
      assert Format.sort_colors(["g", "G", "banana"]) == ["G"]
    end

    test "handles an empty or missing identity" do
      assert Format.sort_colors([]) == []
      assert Format.sort_colors(nil) == []
    end
  end

  describe "severity tokens" do
    test "each severity has its own token" do
      assert Format.severity_token(:critical) == "--sev-critical"
      assert Format.severity_token(:warning) == "--sev-warning"
      assert Format.severity_token(:healthy) == "--sev-healthy"
    end

    test "info is not an alarm, so it resolves to the neutral token" do
      assert Format.severity_token(:info) == "--sev-info"
    end

    test "no severity ever borrows a mana token" do
      mana_tokens = Enum.map(Format.colors(), &Format.color_token/1)

      for severity <- [:critical, :warning, :healthy, :info] do
        refute Format.severity_token(severity) in mana_tokens
      end
    end

    test "neutral is the resting tone and is ink, not a hue" do
      assert Format.tone_token(:neutral) == "--ink"
      assert Format.tone_var(:critical) == "var(--sev-critical)"
    end

    test "labels are pt-BR" do
      assert Format.severity_label(:critical) == "Crítico"
      assert Format.severity_label(:warning) == "Atenção"
      assert Format.severity_label(:healthy) == "Saudável"
      assert Format.severity_label(:info) == "Nota"
    end
  end

  describe "number formatting" do
    test "uses the pt-BR decimal comma" do
      assert Format.decimal(3.24) == "3,2"
      assert Format.decimal(3.26, 2) == "3,26"
    end

    test "a whole average prints whole" do
      assert Format.decimal(3.0) == "3"
      assert Format.decimal(3) == "3"
      assert Format.decimal(2.04) == "2"
    end

    test "an unmeasured value is visibly absent, not zero" do
      assert Format.decimal(nil) == "—"
      assert Format.percent(nil) == "—"
    end

    test "shares round to whole percentages" do
      assert Format.percent(0.184) == "18%"
      assert Format.percent(0.2) == "20%"
      assert Format.percent(0) == "0%"
    end
  end
end
