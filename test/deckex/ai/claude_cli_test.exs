defmodule Deckex.AI.ClaudeCliTest do
  use ExUnit.Case, async: true

  alias Deckex.AI.ClaudeCli
  alias Deckex.AI.Usage
  alias Deckex.Error

  describe "build_args/3" do
    test "asks for JSON output constrained by the schema" do
      args = ClaudeCli.build_args("classifique", %{type: "object"}, [])

      assert "-p" in args
      assert "classifique" in args
      assert "--output-format" in args
      assert "json" in args
      assert "--json-schema" in args
    end

    test "passes the model when given" do
      args = ClaudeCli.build_args("oi", %{}, model: "sonnet")

      assert "--model" in args
      assert "sonnet" in args
    end

    test "grants no tools by default" do
      refute "--allowedTools" in ClaudeCli.build_args("oi", %{}, [])
    end

    test "grants only the tools explicitly allowed" do
      args = ClaudeCli.build_args("oi", %{}, allowed_tools: ["WebSearch"])

      assert "--allowedTools" in args
      assert "WebSearch" in args
    end
  end

  describe "parse_output/1" do
    test "returns the structured output object" do
      envelope = Jason.encode!(%{"structured_output" => %{"cards" => []}})

      assert {:ok, %{"cards" => []}, %Usage{}} = ClaudeCli.parse_output(envelope)
    end

    # The envelope carried these all along and this function used to drop them,
    # which is why the app could spend all afternoon and not say how much.
    test "reads what the call cost out of the same envelope" do
      envelope =
        Jason.encode!(%{
          "structured_output" => %{"cards" => []},
          "total_cost_usd" => 0.116381,
          "duration_ms" => 2885,
          "usage" => %{
            "input_tokens" => 2,
            "output_tokens" => 4,
            "cache_creation_input_tokens" => 10_665,
            "cache_read_input_tokens" => 19_242
          }
        })

      assert {:ok, _output, usage} = ClaudeCli.parse_output(envelope)

      assert usage.input_tokens == 2
      assert usage.output_tokens == 4
      assert usage.cache_creation_tokens == 10_665
      assert usage.cache_read_tokens == 19_242
      assert usage.duration_ms == 2885
      assert Decimal.equal?(usage.cost_usd, Decimal.new("0.116381"))
      assert Usage.total_tokens(usage) == 29_913
    end

    # An older CLI, a stub, a shape nobody expected: no numbers is a fact, and
    # an invented number reads exactly like a measured one.
    test "an envelope without usage measures nothing rather than guessing" do
      envelope = Jason.encode!(%{"structured_output" => %{"cards" => []}})

      assert {:ok, _output, usage} = ClaudeCli.parse_output(envelope)

      refute Usage.measured?(usage)
      assert Usage.total_tokens(usage) == 0
    end

    test "surfaces an error envelope as a domain error" do
      envelope = Jason.encode!(%{"is_error" => true, "result" => "estourou o limite"})

      assert {:error, %Error{code: :ai_unavailable}} = ClaudeCli.parse_output(envelope)
    end

    test "surfaces a missing structured_output as a domain error" do
      envelope = Jason.encode!(%{"subtype" => "success", "result" => "texto solto"})

      assert {:error, %Error{code: :ai_unavailable}} = ClaudeCli.parse_output(envelope)
    end

    test "surfaces unparseable output as a domain error" do
      assert {:error, %Error{code: :ai_unavailable}} = ClaudeCli.parse_output("not json")
    end
  end
end
