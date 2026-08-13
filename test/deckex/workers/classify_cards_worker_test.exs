defmodule Deckex.Workers.ClassifyCardsWorkerTest do
  use Deckex.DataCase, async: true

  import Mox

  alias Deckex.Cards
  alias Deckex.Cards.Card
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.Error
  alias Deckex.ScryfallFixture
  alias Deckex.Workers.ClassifyCardsWorker

  setup :verify_on_exit!

  defp insert_fixture(name) do
    attrs = name |> ScryfallFixture.load!() |> ScryfallMapper.to_attrs()

    %Card{} |> Card.changeset(attrs) |> Repo.insert!()
  end

  test "classifies the cards it is given" do
    card = insert_fixture("sol_ring")

    assert :ok = perform_job(ClassifyCardsWorker, %{card_ids: [card.id]})
    assert [%{kind: :ramp}] = Cards.roles_for(card)
  end

  test "cancels rather than retrying when no card exists" do
    assert {:cancel, _reason} =
             perform_job(ClassifyCardsWorker, %{card_ids: [Ecto.UUID.generate()]})
  end

  test "retries an AI timeout rather than cancelling" do
    card = insert_fixture("young_pyromancer")

    expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts ->
      {:error, Error.new(:ai_timeout, "estourou")}
    end)

    assert {:error, %Error{code: :ai_timeout}} =
             perform_job(ClassifyCardsWorker, %{card_ids: [card.id]})
  end
end
