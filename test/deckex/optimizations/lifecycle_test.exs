defmodule Deckex.Optimizations.LifecycleTest do
  use Deckex.DataCase, async: true

  alias Deckex.CatalogueFixture
  alias Deckex.Decks
  alias Deckex.Error
  alias Deckex.Optimizations

  defp deck(attrs \\ %{}) do
    CatalogueFixture.seed!(~w(sol_ring forest rhystic_study))

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n1 Rhystic Study\n4 Forest", %{
        name: "Deck do Ciclo",
        source: :paste
      })

    case map_size(attrs) do
      0 -> deck
      _some -> deck |> Deckex.Decks.Deck.changeset(attrs) |> Repo.update!()
    end
  end

  describe "default_contract/1" do
    test "derives from the deck and Settings, nothing hardcoded to a deck" do
      contract = Optimizations.default_contract(deck())

      # Rhystic Study is a Game Changer, so the measured floor — and thus the
      # default ceiling — is 3: optimize without changing tables.
      assert contract["bracket_max"] == 3
      assert contract["ceilings"] == %{"card" => 800, "land" => 200}
      assert contract["model"] == Deckex.Settings.model()
      assert contract["keep"] == []
    end
  end

  describe "recipe/1" do
    test "includes the scout only when the dossier is missing or stale" do
      bare = deck()
      assert %{"lens" => "scout"} = hd(Optimizations.recipe(bare))

      {:ok, fresh} =
        Decks.put_dossier(bare, %{
          "plano" => "p",
          "sinergias" => "s",
          "linhas_de_vitoria" => "l",
          "fraquezas" => "f"
        })

      refute Enum.any?(Optimizations.recipe(fresh), &(&1["lens"] == "scout"))

      {:ok, _card} = Decks.add_card(fresh, "Forest")
      {:ok, stale} = Decks.fetch_deck(fresh.id)
      assert %{"lens" => "scout"} = hd(Optimizations.recipe(stale))
    end

    test "ends with the second stabilization checkpoint" do
      assert %{"kind" => "checkpoint", "label" => "Estabilização 2"} =
               List.last(Optimizations.recipe(deck()))
    end
  end

  describe "start/3" do
    test "freezes contract, recipe and the sandbox list, and creates every stage" do
      {:ok, optimization} = Optimizations.start(deck(), %{"notes" => "mantenha o tema"})

      assert optimization.status == :running
      assert optimization.contract["notes"] == "mantenha o tema"
      assert optimization.contract["bracket_max"] == 3
      assert length(optimization.steps) == length(optimization.recipe)

      [first | rest] = optimization.steps
      assert first.position == 1
      assert first.list_before != nil
      assert Enum.all?(rest, &is_nil(&1.list_before))

      assert %{"name" => "Rhystic Study", "quantity" => 1} in optimization.list_original
    end

    test "refuses a second run while one is alive" do
      deck = deck()
      {:ok, _first} = Optimizations.start(deck)

      assert {:error, %Error{code: :optimization_running}} = Optimizations.start(deck)
    end

    test "a recipe override replaces the default, for tests and variants" do
      recipe = [%{"kind" => "checkpoint", "lens" => "full", "label" => "Só uma"}]

      {:ok, optimization} = Optimizations.start(deck(), %{}, recipe)

      assert [%{label: "Só uma", kind: :checkpoint}] = optimization.steps
    end
  end

  describe "pause / resume / cancel" do
    test "transitions round-trip and broadcast" do
      {:ok, optimization} = Optimizations.start(deck())
      Deckex.Events.subscribe_optimization(optimization.id)

      {:ok, paused} = Optimizations.pause(optimization)
      assert paused.status == :paused
      assert_receive {:optimization_updated, _id}

      {:ok, resumed} = Optimizations.resume(paused)
      assert resumed.status == :running

      {:ok, cancelled} = Optimizations.cancel(resumed)
      assert cancelled.status == :cancelled
    end
  end

  describe "set_feedback/2" do
    test "merges the owner's margin notes" do
      {:ok, optimization} = Optimizations.start(deck())
      [step | _rest] = optimization.steps

      {:ok, rated} = Optimizations.set_feedback(step, %{"rating" => "up"})
      {:ok, noted} = Optimizations.set_feedback(rated, %{"note" => "boa etapa"})

      assert noted.feedback == %{"rating" => "up", "note" => "boa etapa"}
    end
  end

  describe "save_as_deck/2" do
    test "forks the current sandbox state into a brand-new deck" do
      deck = deck()
      {:ok, optimization} = Optimizations.start(deck)

      {:ok, forked} = Optimizations.save_as_deck(optimization)

      assert forked.id != deck.id
      assert forked.name =~ "otimizado"

      counts =
        forked
        |> Decks.snapshot()
        |> Map.get(:main)
        |> Enum.map(&{&1.card.name, &1.quantity})
        |> Enum.sort()

      assert counts == [{"Forest", 4}, {"Rhystic Study", 1}, {"Sol Ring", 1}]
    end
  end
end
