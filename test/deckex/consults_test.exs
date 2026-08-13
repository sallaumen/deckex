defmodule Deckex.ConsultsTest do
  use Deckex.DataCase, async: true

  import Mox

  alias Deckex.CatalogueFixture
  alias Deckex.Consults
  alias Deckex.Decks
  alias Deckex.Error
  alias Deckex.ScryfallFixture
  alias Deckex.Workers.ConsultWorker

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

  defp answer do
    {:ok,
     %{
       "diagnosis" => "Falta interação.",
       "cuts" => [%{"card" => "Sol Ring", "reason" => "exemplo"}],
       "adds" => [%{"card" => "Cultivate", "reason" => "ramp"}]
     }}
  end

  # A finished consult pulls the cards it suggested into the catalogue, so the
  # suggestion table can show a real price without the page hitting Scryfall.
  defp stub_catalogue do
    stub(Deckex.Scryfall.Mock, :fetch_by_names, fn _names ->
      {:ok, %{found: [ScryfallFixture.load!("cultivate")], not_found: []}}
    end)
  end

  describe "request/3" do
    test "freezes the briefing and the report, then queues the call" do
      assert {:ok, consult} = Consults.request(deck(), :mana_ramp)

      assert consult.status == :pending
      assert consult.lens == :mana_ramp
      assert consult.briefing =~ "Deck de Consulta"
      assert is_map(consult.report_snapshot)

      assert_enqueued(worker: ConsultWorker)
    end

    test "scopes to one finding when given a code" do
      assert {:ok, consult} =
               Consults.request(deck(), :finding, finding_code: "interaction.no_board_wipes")

      assert consult.finding_code == "interaction.no_board_wipes"
      assert consult.briefing =~ "interaction.no_board_wipes"
    end

    test "lists a deck's consults" do
      deck = deck()
      {:ok, _consult} = Consults.request(deck, :full)

      assert [%{lens: :full}] = Consults.list_for_deck(deck)
    end
  end

  describe "run/1" do
    test "stores the model's answer and marks the consult done" do
      deck = deck()
      {:ok, consult} = Consults.request(deck, :full)

      stub_catalogue()

      expect(Deckex.AI.Mock, :complete, fn prompt, schema, opts ->
        assert prompt =~ "Commander"
        assert schema["required"] == ["diagnosis", "cuts", "adds"]
        # The whole point: the model may look things up.
        assert opts[:allowed_tools] == ["WebSearch"]

        answer()
      end)

      assert {:ok, done} = Consults.run(consult)

      assert done.status == :done
      assert done.response["diagnosis"] == "Falta interação."
      assert done.duration_ms >= 0
      assert done.model != nil
    end

    test "records a failure instead of losing it" do
      deck = deck()
      {:ok, consult} = Consults.request(deck, :full)

      expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts ->
        {:error, Error.new(:ai_timeout, "estourou")}
      end)

      assert {:error, %Error{code: :ai_timeout}} = Consults.run(consult)

      assert [%{status: :failed, error: stored}] = Consults.list_for_deck(deck)
      assert stored =~ "estourou"
    end

    test "sends the stored briefing verbatim — never a rebuilt one" do
      {:ok, consult} = Consults.request(deck(), :full)

      stub_catalogue()

      expect(Deckex.AI.Mock, :complete, fn prompt, _schema, _opts ->
        assert prompt == consult.briefing

        answer()
      end)

      assert {:ok, _done} = Consults.run(consult)
    end
  end

  describe "ConsultWorker" do
    test "runs the consult it is given" do
      deck = deck()
      {:ok, consult} = Consults.request(deck, :full)

      stub_catalogue()
      expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts -> answer() end)

      assert :ok = perform_job(ConsultWorker, %{consult_id: consult.id})
      assert [%{status: :done}] = Consults.list_for_deck(deck)
    end

    test "cancels when the consult has vanished" do
      assert {:cancel, _reason} = perform_job(ConsultWorker, %{consult_id: Ecto.UUID.generate()})
    end

    test "retries a timeout rather than cancelling" do
      {:ok, consult} = Consults.request(deck(), :full)

      expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts ->
        {:error, Error.new(:ai_timeout, "estourou")}
      end)

      assert {:error, %Error{code: :ai_timeout}} =
               perform_job(ConsultWorker, %{consult_id: consult.id})
    end
  end
end
