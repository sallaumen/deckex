defmodule Deckex.AI.LedgerTest do
  use Deckex.DataCase, async: true

  import Deckex.Factory

  alias Deckex.AI.Ledger
  alias Deckex.AI.Usage
  alias Deckex.CatalogueFixture
  alias Deckex.Decks

  defp deck(name \\ "Deck Medido") do
    CatalogueFixture.seed!(~w(sol_ring forest))

    {:ok, deck} = Decks.import_from_text("1 Sol Ring\n4 Forest", %{name: name, source: :paste})

    deck
  end

  # The numbers the real CLI returned on 2026-08-24, kept verbatim: a fixture
  # invented by hand would drift from the envelope it claims to model.
  defp real_usage do
    %Usage{
      input_tokens: 2,
      output_tokens: 4,
      cache_creation_tokens: 10_665,
      cache_read_tokens: 19_242,
      cost_usd: Decimal.new("0.116381"),
      duration_ms: 2885
    }
  end

  describe "what the ledger records" do
    test "a consult's call counts against the consult and its deck" do
      deck = deck()
      consult = insert(:consult, deck: deck, status: :done)

      :ok = Ledger.record(real_usage(), kind: :consult, deck_id: deck.id, consult_id: consult.id)

      assert %{calls: 1, total_tokens: 29_913} = Ledger.totals_for_deck(deck)
      assert %{calls: 1, total_tokens: 29_913} = Ledger.totals_for_consult(consult.id)
    end

    # Classifying cards belongs to no deck and costs real money; a global meter
    # that skipped it would quietly understate the bill.
    test "a call that belongs to no deck still counts globally" do
      :ok = Ledger.record(real_usage(), kind: :classification)

      assert %{calls: 1} = Ledger.totals()
      assert Ledger.by_deck() == %{}
    end

    test "cache is counted apart from fresh input" do
      deck = deck()
      :ok = Ledger.record(real_usage(), kind: :consult, deck_id: deck.id)

      totals = Ledger.totals_for_deck(deck)

      assert totals.input_tokens == 2
      assert totals.cache_read_tokens == 19_242
      assert totals.cache_creation_tokens == 10_665
    end

    test "cost adds up across calls" do
      deck = deck()
      :ok = Ledger.record(real_usage(), kind: :consult, deck_id: deck.id)
      :ok = Ledger.record(real_usage(), kind: :consult, deck_id: deck.id)

      assert Decimal.equal?(Ledger.totals_for_deck(deck).cost_usd, Decimal.new("0.232762"))
    end

    # Measured or absent, never guessed: a call the adapter could not measure
    # writes no row rather than a row of zeros pretending to be a measurement.
    test "an unmeasured call records nothing" do
      :ok = Ledger.record(%Usage{}, kind: :consult)

      assert Ledger.totals().calls == 0
    end
  end

  describe "the totals the meters read" do
    test "a deck that never asked anything reads zero, not nil" do
      totals = Ledger.totals_for_deck(deck())

      assert totals.calls == 0
      assert totals.total_tokens == 0
      assert Decimal.equal?(totals.cost_usd, Decimal.new(0))
    end

    test "by_deck answers for every deck in one query" do
      first = deck("Primeiro")
      second = deck("Segundo")

      :ok = Ledger.record(real_usage(), kind: :consult, deck_id: first.id)
      :ok = Ledger.record(real_usage(), kind: :consult, deck_id: second.id)
      :ok = Ledger.record(real_usage(), kind: :consult, deck_id: second.id)

      by_deck = Ledger.by_deck()

      assert by_deck[first.id].calls == 1
      assert by_deck[second.id].calls == 2
      assert by_deck[second.id].total_tokens == 59_826
    end

    test "by_consult answers for a page full of them in one query" do
      deck = deck()
      one = insert(:consult, deck: deck, status: :done)
      two = insert(:consult, deck: deck, status: :done)

      :ok = Ledger.record(real_usage(), kind: :consult, deck_id: deck.id, consult_id: one.id)

      by_consult = Ledger.by_consult([one.id, two.id])

      assert by_consult[one.id].total_tokens == 29_913
      refute Map.has_key?(by_consult, two.id)
    end

    test "the global total is every call, deck or no deck" do
      deck = deck()
      :ok = Ledger.record(real_usage(), kind: :consult, deck_id: deck.id)
      :ok = Ledger.record(real_usage(), kind: :classification)

      assert Ledger.totals().calls == 2
      assert Ledger.totals().total_tokens == 59_826
    end
  end
end
