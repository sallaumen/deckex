defmodule Deckex.Workers.CatalogueWorkerTest do
  use Deckex.DataCase, async: true

  import Mox

  alias Deckex.Cards
  alias Deckex.CatalogueFixture
  alias Deckex.Consults
  alias Deckex.Decks
  alias Deckex.Error
  alias Deckex.ScryfallFixture
  alias Deckex.Workers.CatalogueWorker

  # Every test here drives a consult whose Scryfall call fails on purpose, so
  # the warning that failure logs is expected output.
  @moduletag capture_log: true

  setup :verify_on_exit!

  defp deck do
    CatalogueFixture.seed!(~w(sol_ring forest counterspell))

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n1 Counterspell\n4 Forest", %{
        name: "Deck de Consulta",
        source: :paste
      })

    deck
  end

  # A consult whose answer names Cultivate, which the catalogue does not hold —
  # the state a Scryfall outage at answer time leaves behind.
  defp answered_consult(deck) do
    {:ok, consult} = Consults.request(deck, :full)

    stub(Deckex.Scryfall.Mock, :fetch_by_names, fn _names ->
      {:error, Error.new(:scryfall_unavailable, "caiu")}
    end)

    expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts ->
      {:ok,
       %{
         "diagnosis" => "Falta ramp.",
         "cuts" => [%{"card" => "Sol Ring", "reason" => "exemplo"}],
         "adds" => [%{"card" => "Cultivate", "reason" => "ramp"}]
       }}
    end)

    {:ok, done} = Consults.run(consult)

    done
  end

  test "fetches the cards the consult's answer named" do
    consult = answered_consult(deck())
    assert Cards.get_by_name("Cultivate") == nil

    expect(Deckex.Scryfall.Mock, :fetch_by_names, fn names ->
      assert "Cultivate" in names

      {:ok, %{found: [ScryfallFixture.load!("cultivate")], not_found: []}}
    end)

    assert :ok = perform_job(CatalogueWorker, %{consult_id: consult.id})
    assert %{name: "Cultivate"} = Cards.get_by_name("Cultivate")
  end

  test "retries rather than writing the card off while Scryfall is still down" do
    consult = answered_consult(deck())

    expect(Deckex.Scryfall.Mock, :fetch_by_names, fn _names ->
      {:error, Error.new(:scryfall_unavailable, "ainda caiu")}
    end)

    assert {:error, %Error{code: :scryfall_unavailable}} =
             perform_job(CatalogueWorker, %{consult_id: consult.id})
  end

  test "cancels when the consult has vanished" do
    assert {:cancel, _reason} =
             perform_job(CatalogueWorker, %{consult_id: Ecto.UUID.generate()})
  end

  describe "enqueue_all/0" do
    test "queues the consults whose catalogue is short" do
      consult = answered_consult(deck())

      assert {:ok, 1} = CatalogueWorker.enqueue_all()
      assert_enqueued(worker: CatalogueWorker, args: %{consult_id: consult.id})
    end

    test "queues nothing when every suggested card is already known" do
      deck = deck()
      consult = answered_consult(deck)

      expect(Deckex.Scryfall.Mock, :fetch_by_names, fn _names ->
        {:ok, %{found: [ScryfallFixture.load!("cultivate")], not_found: []}}
      end)

      assert :ok = perform_job(CatalogueWorker, %{consult_id: consult.id})

      assert {:ok, 0} = CatalogueWorker.enqueue_all()
    end
  end
end
