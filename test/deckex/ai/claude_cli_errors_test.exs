defmodule Deckex.AI.ClaudeCliErrorsTest do
  @moduledoc """
  What the app says when the CLI fails.

  A real review stage failed three times with "O `claude` saiu com código 1"
  and nothing else. The CLI had written the reason to stdout — *"Failed to
  authenticate: OAuth session expired and could not be refreshed"* — inside its
  ordinary JSON envelope, and then exited 1. The adapter read the exit code,
  ignored the envelope, and reported the number.
  """
  use ExUnit.Case, async: true

  alias Deckex.AI.ClaudeCli
  alias Deckex.Error

  defp envelope(result, extra \\ %{}) do
    Jason.encode!(Map.merge(%{"is_error" => true, "result" => result}, extra))
  end

  describe "an envelope that says what went wrong" do
    test "an expired login is named, with the command that fixes it" do
      output =
        envelope("Failed to authenticate: OAuth session expired and could not be refreshed")

      assert {:error, %Error{code: :ai_unauthenticated} = error} = ClaudeCli.parse_output(output)
      assert error.message =~ "claude login"
      assert error.message =~ "etapas já pagas ficam"
    end

    test "any other API error keeps the CLI's own words" do
      output = envelope("Overloaded: please retry")

      assert {:error, %Error{code: :ai_unavailable} = error} = ClaudeCli.parse_output(output)
      assert error.message =~ "A IA retornou erro"
      assert error.details.result == "Overloaded: please retry"
    end

    # The failure mode this whole test file is about: the reason was in the
    # output and the app reported the exit code.
    test "an envelope with no result at all still does not crash" do
      assert {:error, %Error{code: :ai_unavailable}} =
               ClaudeCli.parse_output(Jason.encode!(%{"is_error" => true}))
    end
  end

  describe "output that is not an envelope" do
    test "unreadable output says so rather than guessing" do
      assert {:error, %Error{code: :ai_unavailable} = error} =
               ClaudeCli.parse_output("Segmentation fault")

      assert error.message =~ "Não consegui ler"
    end

    test "a successful envelope with no structured output is reported as such" do
      output = Jason.encode!(%{"subtype" => "success", "result" => "texto solto"})

      assert {:error, %Error{} = error} = ClaudeCli.parse_output(output)
      assert error.message =~ "sem saída estruturada"
    end
  end
end
