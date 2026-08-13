defmodule Deckex.Workers.ClassifyCardsWorkerTest do
  use Deckex.DataCase, async: true

  import Mox

  alias Deckex.Cards
  alias Deckex.CatalogueFixture
  alias Deckex.Error
  alias Deckex.Workers.ClassifyCardsWorker

  setup :verify_on_exit!

  # One ordered, conflict-safe batch per test — see `Deckex.CatalogueFixture`
  # for why the order is load-bearing and why it must be a single call.
  defp seed(names) do
    CatalogueFixture.seed_map!(names)
  end

  test "classifies the cards it is given" do
    %{"sol_ring" => card} = seed(~w(sol_ring))

    assert :ok = perform_job(ClassifyCardsWorker, %{card_ids: [card.id]})
    assert [%{kind: :ramp}] = Cards.roles_for(card)
  end

  test "cancels rather than retrying when no card exists" do
    assert {:cancel, _reason} =
             perform_job(ClassifyCardsWorker, %{card_ids: [Ecto.UUID.generate()]})
  end

  test "retries an AI timeout rather than cancelling" do
    %{"young_pyromancer" => card} = seed(~w(young_pyromancer))

    expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts ->
      {:error, Error.new(:ai_timeout, "estourou")}
    end)

    assert {:error, %Error{code: :ai_timeout}} =
             perform_job(ClassifyCardsWorker, %{card_ids: [card.id]})
  end
end
