defmodule Deckex.AI.ClaudeCliTest do
  use ExUnit.Case, async: true

  alias Deckex.AI.ClaudeCli
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

      assert {:ok, %{"cards" => []}} = ClaudeCli.parse_output(envelope)
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
