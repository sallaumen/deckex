defmodule Deckex.Consults.SuggestionsTest do
  use Deckex.DataCase, async: true

  alias Deckex.Cards
  alias Deckex.CatalogueFixture
  alias Deckex.Consults.Suggestion
  alias Deckex.Consults.Suggestions

  defp consult(response) do
    CatalogueFixture.seed!(~w(sol_ring counterspell))

    insert(:consult, response: response, status: :done)
  end

  describe "for_consult/1" do
    test "joins the model's rows to real cards" do
      rows =
        %{
          "cuts" => [%{"card" => "Sol Ring", "reason" => "exemplo"}],
          "adds" => [%{"card" => "Counterspell", "reason" => "interação"}]
        }
        |> consult()
        |> Suggestions.for_consult()

      assert [
               %Suggestion{action: :cut, name: "Sol Ring", resolved?: true},
               %Suggestion{action: :add, name: "Counterspell", resolved?: true}
             ] = rows
    end

    test "carries the model's reason through untouched" do
      [row | _rest] =
        %{"cuts" => [%{"card" => "Sol Ring", "reason" => "custa slot"}], "adds" => []}
        |> consult()
        |> Suggestions.for_consult()

      assert row.reason == "custa slot"
    end

    test "attaches the price from the catalogue, not from the model" do
      [row | _rest] =
        %{
          "cuts" => [],
          "adds" => [%{"card" => "Sol Ring", "reason" => "x", "price_usd" => "999.99"}]
        }
        |> consult()
        |> Suggestions.for_consult()

      refute Decimal.equal?(row.price_usd, Decimal.new("999.99"))
      assert row.price_usd == Cards.get_by_name("Sol Ring").price_usd
    end

    # No Mox expectation here on purpose: building the table must not reach for
    # the network. A card the catalogue has never seen renders unresolved.
    test "marks a card it cannot resolve rather than dropping it" do
      [row] =
        %{"cuts" => [], "adds" => [%{"card" => "Carta Que Não Existe", "reason" => "x"}]}
        |> consult()
        |> Suggestions.for_consult()

      assert %Suggestion{resolved?: false, card: nil, name: "Carta Que Não Existe"} = row
    end

    test "keeps the finding a suggestion addresses" do
      [row] =
        %{
          "cuts" => [],
          "adds" => [%{"card" => "Sol Ring", "reason" => "x", "addresses" => "mana.ramp_low"}]
        }
        |> consult()
        |> Suggestions.for_consult()

      assert row.addresses == "mana.ramp_low"
    end

    test "an unanswered consult has no rows" do
      assert Suggestions.for_consult(insert(:consult, response: nil)) == []
    end
  end

  describe "names/1" do
    test "lists every card the answer mentions, as the model spelled it" do
      names =
        %{
          "cuts" => [%{"card" => "Sol Ring", "reason" => "x"}],
          "adds" => [%{"card" => "Cultivate", "reason" => "ramp"}]
        }
        |> consult()
        |> Suggestions.names()

      assert names == ["Sol Ring", "Cultivate"]
    end

    test "says a name once even when the model repeats it" do
      names =
        %{
          "cuts" => [%{"card" => "Sol Ring", "reason" => "x"}],
          "adds" => [%{"card" => "Sol Ring", "reason" => "y"}]
        }
        |> consult()
        |> Suggestions.names()

      assert names == ["Sol Ring"]
    end

    test "an unanswered consult mentions nothing" do
      assert Suggestions.names(insert(:consult, response: nil)) == []
    end
  end

  describe "total_usd/1" do
    test "sums what the adds would cost, ignoring the cuts" do
      rows =
        %{
          "cuts" => [%{"card" => "Sol Ring", "reason" => "x"}],
          "adds" => [%{"card" => "Counterspell", "reason" => "y"}]
        }
        |> consult()
        |> Suggestions.for_consult()

      assert Decimal.equal?(
               Suggestions.total_usd(rows),
               Cards.get_by_name("Counterspell").price_usd
             )
    end

    test "an empty list costs nothing rather than crashing" do
      assert Decimal.equal?(Suggestions.total_usd([]), Decimal.new(0))
    end
  end

  describe "to_csv/1" do
    test "has a header and one line per suggestion" do
      csv =
        %{
          "cuts" => [%{"card" => "Sol Ring", "reason" => "exemplo"}],
          "adds" => [%{"card" => "Counterspell", "reason" => "interação"}]
        }
        |> consult()
        |> Suggestions.for_consult()
        |> Suggestions.to_csv()

      [header | rows] = csv |> String.trim() |> String.split("\n")

      assert header == "acao,carta,motivo,achado,preco_usd,preco_brl,resolvida"
      assert length(rows) == 2
      assert Enum.any?(rows, &String.starts_with?(&1, "cortar,Sol Ring,"))
    end

    test "quotes a reason containing a comma so the file stays parseable" do
      csv =
        %{
          "cuts" => [%{"card" => "Sol Ring", "reason" => "rápido, mas dispensável"}],
          "adds" => []
        }
        |> consult()
        |> Suggestions.for_consult()
        |> Suggestions.to_csv()

      assert csv =~ ~s("rápido, mas dispensável")
    end

    test "escapes a quote inside a reason" do
      csv =
        %{"cuts" => [%{"card" => "Sol Ring", "reason" => ~s(o "melhor" card)}], "adds" => []}
        |> consult()
        |> Suggestions.for_consult()
        |> Suggestions.to_csv()

      assert csv =~ ~s("o ""melhor"" card")
    end
  end
end
