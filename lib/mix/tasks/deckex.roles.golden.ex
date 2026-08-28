defmodule Mix.Tasks.Deckex.Roles.Golden do
  @shortdoc "Prints the fixture-classification snapshot for RolesGoldenTest"

  @moduledoc """
  Classifies every Scryfall fixture and prints the `@golden` map body.

      mix deckex.roles.golden

  Paste the output over `@golden` in `test/deckex/cards/roles_golden_test.exs`
  and review the diff line by line — a row you cannot defend as a player is a
  rule that needs a guard, not a snapshot that needs updating.

  Pure: reads fixture files only. No Repo, no Oban, no network.
  """
  use Mix.Task

  alias Deckex.Cards.Card
  alias Deckex.Cards.Roles
  alias Deckex.Cards.ScryfallMapper

  @fixtures "test/support/fixtures/scryfall"

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("compile")

    @fixtures
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.sort()
    |> Enum.map_join(",\n", fn file ->
      kinds =
        struct!(
          Card,
          @fixtures
          |> Path.join(file)
          |> File.read!()
          |> Jason.decode!()
          |> ScryfallMapper.to_attrs()
        )
        |> Roles.classify()
        |> Enum.map(& &1.kind)
        |> Enum.sort()

      "    #{Path.rootname(file)}: ~w(#{Enum.join(kinds, " ")})a"
    end)
    |> IO.puts()
  end
end
