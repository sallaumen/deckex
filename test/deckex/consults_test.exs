defmodule Deckex.ConsultsTest do
  use Deckex.DataCase, async: true

  import Mox

  alias Deckex.CatalogueFixture
  alias Deckex.Consults
  alias Deckex.Decks
  alias Deckex.Error
  alias Deckex.ScryfallFixture
  alias Deckex.Workers.CatalogueWorker
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
        assert schema["required"] == ["leitura", "diagnosis", "cuts", "adds"]
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

    test "keeps the evidence behind the failure, not just the sentence" do
      deck = deck()
      {:ok, consult} = Consults.request(deck, :full)

      expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts ->
        {:error,
         Error.new(:ai_unavailable, "A IA retornou erro.", %{
           result: "Credit balance is too low"
         })}
      end)

      assert {:error, %Error{}} = Consults.run(consult)

      assert [failed] = Consults.list_for_deck(deck)
      assert failed.error_code == "ai_unavailable"
      assert failed.error_details == %{"result" => "Credit balance is too low"}
      # A failure that took six seconds and one that took ten minutes are
      # different stories; the row used to be unable to tell them apart.
      assert failed.duration_ms >= 0
    end

    test "a detail JSONB cannot hold is inspected, never raised while reporting a failure" do
      deck = deck()
      {:ok, consult} = Consults.request(deck, :full)

      expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts ->
        {:error, Error.new(:ai_unavailable, "morreu", %{reason: {:exit, :killed}, tries: 3})}
      end)

      assert {:error, %Error{}} = Consults.run(consult)

      assert [%{error_details: details}] = Consults.list_for_deck(deck)
      assert details["reason"] == "{:exit, :killed}"
      assert details["tries"] == 3
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

  describe "refresh_catalogue/1" do
    @tag capture_log: true
    test "reports a Scryfall failure instead of swallowing it" do
      {:ok, consult} = Consults.request(deck(), :full)

      # Scryfall is down for the whole test, so "Cultivate" never reaches the
      # catalogue and the refresh has real work to fail at.
      stub(Deckex.Scryfall.Mock, :fetch_by_names, fn _names ->
        {:error, Error.new(:scryfall_unavailable, "caiu")}
      end)

      expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts -> answer() end)
      {:ok, done} = Consults.run(consult)

      assert {:error, %Error{code: :scryfall_unavailable}} = Consults.refresh_catalogue(done)
    end

    test "answers :ok without a request when the catalogue already holds them" do
      {:ok, consult} = Consults.request(deck(), :full)

      stub_catalogue()
      expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts -> answer() end)
      {:ok, done} = Consults.run(consult)

      # No `expect` on the Scryfall mock: a second pass over a complete
      # catalogue must not spend a request. This is what makes the owner's
      # re-run button cheap enough to press twice.
      assert :ok = Consults.refresh_catalogue(done)
    end
  end

  describe "run/1 when the catalogue refresh fails" do
    # The bug this guards: the failure was logged and forgotten, so the card
    # never reached the catalogue and the suggestion said "não achei essa
    # carta na Scryfall" forever. A miss must be retried, not accepted.
    @tag capture_log: true
    test "queues a retry rather than leaving the catalogue short" do
      {:ok, consult} = Consults.request(deck(), :full)

      stub(Deckex.Scryfall.Mock, :fetch_by_names, fn _names ->
        {:error, Error.new(:scryfall_unavailable, "caiu")}
      end)

      expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts -> answer() end)

      assert {:ok, done} = Consults.run(consult)
      assert done.status == :done

      assert_enqueued(worker: CatalogueWorker, args: %{consult_id: done.id})
    end

    test "queues nothing when the refresh works" do
      {:ok, consult} = Consults.request(deck(), :full)

      stub_catalogue()
      expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts -> answer() end)

      assert {:ok, _done} = Consults.run(consult)

      refute_enqueued(worker: CatalogueWorker)
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

  describe "the scout" do
    @scout_answer {:ok,
                   %{
                     "plano" => "Spellslinger Temur.",
                     "sinergias" => "Sol Ring acelera tudo.",
                     "linhas_de_vitoria" => "Valor incremental.",
                     "fraquezas" => "Sem win condition clara."
                   }}

    test "a finished scout writes the dossier onto the deck" do
      deck = deck()
      {:ok, consult} = Consults.request(deck, :scout)

      expect(Deckex.AI.Mock, :complete, fn prompt, schema, _opts ->
        assert prompt =~ "scout, not the consultant"
        assert schema["required"] == ["plano", "sinergias", "linhas_de_vitoria", "fraquezas"]

        @scout_answer
      end)

      assert {:ok, done} = Consults.run(consult)
      assert done.status == :done

      {:ok, fresh} = Decks.fetch_deck(deck.id)
      assert fresh.dossier["plano"] == "Spellslinger Temur."
      assert fresh.dossier_source == :scout
      assert fresh.dossier_stale == false
    end

    test "a failed scout leaves the deck untouched" do
      deck = deck()
      {:ok, consult} = Consults.request(deck, :scout)

      expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts ->
        {:error, Error.new(:ai_timeout, "estourou")}
      end)

      assert {:error, %Error{}} = Consults.run(consult)

      {:ok, fresh} = Decks.fetch_deck(deck.id)
      assert fresh.dossier == nil
    end

    test "a consult on a deck with a dossier carries it in the briefing" do
      deck = deck()
      {:ok, deck} = Decks.put_dossier(deck, elem(@scout_answer, 1))

      {:ok, consult} = Consults.request(deck, :full)

      assert consult.briefing =~ "Leitura estratégica"
      assert consult.briefing =~ "Sol Ring acelera tudo."
    end

    test "a consult on a deck without a dossier still works" do
      {:ok, consult} = Consults.request(deck(), :full)

      refute consult.briefing =~ "Leitura estratégica"
    end
  end

  describe "consults inside an optimization" do
    # Seeded in ONE call — two seed!/1 calls in one test is the documented
    # 40P01 recipe (see CatalogueFixture's moduledoc).
    test "request with a snapshot override freezes THAT list, tagged with the run" do
      CatalogueFixture.seed!(~w(sol_ring forest counterspell cultivate))

      {:ok, deck} =
        Decks.import_from_text("1 Sol Ring\n1 Counterspell\n4 Forest", %{
          name: "Deck de Consulta",
          source: :paste
        })

      optimization = insert(:optimization, deck: deck)

      # The sandbox differs from the deck: Cultivate is only in the sandbox.
      sandbox = [
        %{"name" => "Cultivate", "quantity" => 1},
        %{"name" => "Forest", "quantity" => 4}
      ]

      snapshot = Deckex.Optimizations.snapshot_for(sandbox, [], deck)

      {:ok, consult} =
        Consults.request(deck, :full, snapshot: snapshot, optimization_id: optimization.id)

      assert consult.optimization_id == optimization.id
      assert consult.briefing =~ "Cultivate"
      refute consult.briefing =~ "Counterspell"
    end

    test "the deck page never lists pipeline consults" do
      deck = deck()
      optimization = insert(:optimization, deck: deck)

      {:ok, _mine} = Consults.request(deck, :full)
      {:ok, _pipeline} = Consults.request(deck, :full, optimization_id: optimization.id)

      assert [%{optimization_id: nil}] = Consults.list_for_deck(deck)
    end
  end
end
