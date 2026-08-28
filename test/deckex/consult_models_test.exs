defmodule Deckex.ConsultModelsTest do
  use Deckex.DataCase, async: true

  import Mox

  alias Deckex.CatalogueFixture
  alias Deckex.Consults
  alias Deckex.Consults.Consult
  alias Deckex.Decks
  alias Deckex.Settings

  setup :verify_on_exit!

  defp deck do
    CatalogueFixture.seed!(~w(sol_ring forest counterspell))

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n1 Counterspell\n4 Forest", %{
        name: "Deck do Modelo",
        source: :paste
      })

    deck
  end

  describe "request/3 with a model" do
    test "records the model it was asked for, before it runs" do
      assert {:ok, consult} = Consults.request(deck(), :full, model: "opus")

      assert consult.model == "opus"
      assert consult.status == :pending
    end

    test "falls back to the configured model" do
      {:ok, _value} = Settings.put(:claude_model, "fable")

      assert {:ok, consult} = Consults.request(deck(), :full)
      assert consult.model == "fable"
    end

    test "sends the recorded model to the port, not the current setting" do
      {:ok, consult} = Consults.request(deck(), :full, model: "opus")
      # Changing the setting afterwards must not change what this consult runs.
      {:ok, _value} = Settings.put(:claude_model, "fable")

      expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, opts ->
        assert opts[:model] == "opus"

        {:ok, %{"diagnosis" => "ok", "cuts" => [], "adds" => []}}
      end)

      assert {:ok, done} = Consults.run(consult)
      assert done.model == "opus"
    end
  end

  describe "compare/4" do
    test "runs one identical briefing across several models" do
      assert {:ok, consults} = Consults.compare(deck(), :full, ["sonnet", "opus"])

      assert length(consults) == 2
      assert consults |> Enum.map(& &1.model) |> Enum.sort() == ["opus", "sonnet"]

      # The experiment is only clean if the input is byte-identical.
      assert consults |> Enum.map(& &1.briefing) |> Enum.uniq() |> length() == 1
    end

    test "queues one job per model" do
      {:ok, _consults} = Consults.compare(deck(), :full, ["sonnet", "opus", "fable"])

      assert Deckex.Repo.aggregate(Oban.Job, :count) == 3
    end
  end

  describe "the new lenses" do
    test "matchup carries the opponent into the prompt" do
      assert {:ok, consult} =
               Consults.request(deck(), :matchup, against: "deck agressivo vermelho")

      assert consult.lens == :matchup
      assert consult.briefing =~ "deck agressivo vermelho"
    end

    test "budget states a ceiling" do
      {:ok, _value} = Settings.put(:budget_max_brl, 15)

      assert {:ok, consult} = Consults.request(deck(), :budget)
      assert consult.briefing =~ "15"
    end

    # "Sem olhar preço" still has a shape: how many expensive cards the deck
    # may hold, and how many may break the ceiling outright.
    test "upgrade chases power but states what the list can hold" do
      assert {:ok, consult} = Consults.request(deck(), :upgrade)

      assert consult.briefing =~ "as strong as it can be"
      assert consult.briefing =~ "over **R$ 400** counts as expensive"
      assert consult.briefing =~ "may hold 10 of them"
      assert consult.briefing =~ "Over **R$ 600** is an *exception*"
      # The empty deck has spent none of either allowance.
      assert consult.briefing =~ "It already holds **0**"
      assert consult.briefing =~ "0 are spent"
      # A land still gets a hard wall, and no exception can buy past it.
      assert consult.briefing =~ "R$ 300"
    end

    # :finding rides the "Pedir diagnóstico" buttons, :scout the dossier card,
    # and :alinhamento, :visao, :cardapio, :balanco, :revisao and :livre the
    # optimization pipeline — none belongs in the lens dropdown, so none has a
    # label. A single-stage round is still a round: it is launched from the
    # launcher, with a contract and a sandbox, not from the consult picker.
    test "every pickable lens has a label" do
      labels = Map.new(Consults.lens_labels())

      for lens <- Consult.lenses(),
          lens not in [
            :finding,
            :scout,
            :visao,
            :cardapio,
            :balanco,
            :revisao,
            :livre,
            :pilares,
            :plano,
            :execucao,
            :reconstrucao,
            :critico
          ] do
        assert Map.has_key?(labels, lens), "sem rótulo para #{lens}"
      end
    end
  end

  describe "the floor and the picker it feeds" do
    # The bug this exists to not have again: the floor shipped defaulting to
    # `fable`, the STRONGEST model on the ladder, so "the weakest model allowed
    # to change the deck" excluded everything but the strongest and the
    # launcher's picker had exactly one option — for everyone, out of the box.
    test "the default floor leaves a real choice of model" do
      offered = Consults.models_at_or_above(Settings.model_floor())

      assert length(offered) > 1, "o piso padrão deixa só #{inspect(offered)} para escolher"
    end

    test "the models the owner named are among them" do
      offered = Consults.models_at_or_above(Settings.model_floor())

      assert "opus" in offered
      assert "sonnet" in offered
    end

    # The floor still has to mean something: the cheapest model does not get to
    # propose cutting a card from a real deck.
    test "and the cheap one is still below the line" do
      refute "haiku" in Consults.models_at_or_above(Settings.model_floor())
    end

    test "a run asking for a model at the floor is allowed to start" do
      assert Consults.model_rank("sonnet") >= Consults.model_rank(Settings.model_floor())
      assert Consults.model_rank("opus") >= Consults.model_rank(Settings.model_floor())
    end
  end

  describe "models/0" do
    test "offers the aliases the CLI accepts" do
      assert "sonnet" in Consults.models()
      assert "opus" in Consults.models()
    end
  end
end
