defmodule Deckex.Cards.CatalogueSeedConcurrencyTest do
  # async: false — this test manufactures its own concurrency, and would
  # otherwise be measuring the rest of the suite's.
  use Deckex.DataCase, async: false

  alias Deckex.CatalogueFixture
  alias Ecto.Adapters.SQL.Sandbox

  @seeders 24

  # The regression guard AGENTS.md says was missing — the 40P01 that "came back
  # three times". It is NOT a lock-ordering bug: the losing transaction had
  # inserted exactly one row, so there was no order to get wrong.
  #
  # The cycle needs one transaction to write the same card row TWICE:
  #
  #   B inserts R; its speculative insertion completes, leaving an uncommitted
  #   tuple. A inserts R; its speculative insertion is still in flight, holding
  #   a token. B writes R again, meets A's speculative tuple, and waits on A's
  #   token. A reaches `cards_name_normalized_index`, meets B's uncommitted
  #   tuple, and waits on B's transaction. Deadlock, on one row.
  #
  # This test seeds twice on purpose. That breaks the "seed once per test" law
  # deliberately, because reproducing the deadlock is the whole point — and a
  # second write of a card row is easy to reach by accident, notably when a
  # LiveView process writes on the same sandbox connection as its test.
  test "concurrent seeds all succeed rather than one losing to a deadlock" do
    results =
      1..@seeders
      |> Task.async_stream(
        fn _seeder ->
          owner = Sandbox.start_owner!(Deckex.Repo, shared: false)

          try do
            CatalogueFixture.seed_all!()
            CatalogueFixture.seed_all!()

            # Hold the rows uncommitted for a moment, the way a real test does
            # between seeding and asserting. This is what builds the convoy.
            Process.sleep(50)
            :ok
          rescue
            error -> {:error, error}
          after
            Sandbox.stop_owner(owner)
          end
        end,
        max_concurrency: @seeders,
        timeout: 120_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.filter(results, &(&1 != :ok)) == []
  end
end
