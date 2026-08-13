defmodule Deckex.CliTest do
  use ExUnit.Case, async: true

  alias Deckex.Cli

  describe "run/2" do
    test "returns the command result when it finishes in time" do
      assert {:ok, {"pronto", 0}} = Cli.run(fn -> {"pronto", 0} end, 1_000)
    end

    test "returns the exit status the command produced" do
      assert {:ok, {"falhou", 1}} = Cli.run(fn -> {"falhou", 1} end, 1_000)
    end

    test "kills a command that outruns its budget instead of hanging the caller" do
      slow = fn ->
        Process.sleep(500)
        {"tarde demais", 0}
      end

      assert {:error, :timeout} = Cli.run(slow, 50)
    end

    test "reports a crashing command rather than crashing with it" do
      # Task.async links, so an abnormal exit reaches the caller as a signal.
      # Only a process trapping exits survives to receive the tagged tuple —
      # which is exactly who calls this: supervised workers and GenServers.
      Process.flag(:trap_exit, true)

      assert {:error, {:exit, :boom}} = Cli.run(fn -> exit(:boom) end, 1_000)
    end
  end
end
