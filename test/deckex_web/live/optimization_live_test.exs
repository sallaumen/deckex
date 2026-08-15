defmodule DeckexWeb.OptimizationLiveTest do
  use DeckexWeb.ConnCase, async: true
  use Oban.Testing, repo: Deckex.Repo

  import Mox
  import Phoenix.LiveViewTest

  alias Deckex.CatalogueFixture
  alias Deckex.Consults
  alias Deckex.Decks
  alias Deckex.Decks.Deck
  alias Deckex.Optimizations
  alias Deckex.Workers.ConsultWorker
  alias Deckex.Workers.OptimizationAdvanceWorker

  setup :verify_on_exit!

  @two_lenses [
    %{"kind" => "lens", "lens" => "mana_ramp", "label" => "Mana"},
    %{"kind" => "lens", "lens" => "speed_curve", "label" => "Early game"}
  ]

  defp deck do
    CatalogueFixture.seed!(~w(sol_ring forest cultivate))

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n4 Forest", %{name: "Deck da Página", source: :paste})

    # A pasted list with no commander has an empty identity; give it G so the
    # green add in these scripts is legal — the engine WILL refuse otherwise,
    # which is its job and its own test.
    deck
    |> Deck.changeset(%{color_identity: ["G"]})
    |> Deckex.Repo.update!()
  end

  defp run_first_stage(optimization, cuts, adds) do
    stub(Deckex.Scryfall.Mock, :fetch_by_names, fn names ->
      {:ok, %{found: [], not_found: names}}
    end)

    expect(Deckex.AI.Mock, :complete, fn _p, _s, _o ->
      {:ok,
       %{
         "leitura" => "Leitura da etapa.",
         "diagnosis" => "Diagnóstico.",
         "cuts" => Enum.map(cuts, &%{"card" => &1, "reason" => "corte"}),
         "adds" => Enum.map(adds, &%{"card" => &1, "reason" => "entrada"})
       }}
    end)

    {:ok, fetched} = Optimizations.fetch(optimization.id)
    step = Enum.find(fetched.steps, &(&1.status == :running))

    :ok = perform_job(ConsultWorker, %{consult_id: step.consult_id})
    :ok = perform_job(OptimizationAdvanceWorker, %{consult_id: step.consult_id})

    Optimizations.fetch(optimization.id)
  end

  describe "the history page and the launcher" do
    test "launches a run with the contract and lands on its page", %{conn: conn} do
      deck = deck()
      {:ok, live, html} = live(conn, ~p"/decks/#{deck.id}/otimizacoes")

      assert html =~ "Nenhuma otimização ainda"

      live |> element("button[phx-click='abrir-lancador']") |> render_click()

      assert {:error, {:live_redirect, %{to: "/otimizacoes/" <> _id}}} =
               live
               |> form("#launch-form",
                 contract: %{
                   "bracket_max" => "3",
                   "ceiling_card" => "800",
                   "ceiling_land" => "200",
                   "keep" => "Sol Ring",
                   "matchups" => "um aggro rápido",
                   "notes" => "",
                   "model" => "fable"
                 }
               )
               |> render_submit()

      assert [run] = Optimizations.list_for_deck(deck.id)
      assert run.contract["keep"] == ["Sol Ring"]
      assert run.contract["bracket_max"] == 3
    end

    test "a second launch is refused with the reason", %{conn: conn} do
      deck = deck()
      {:ok, _running} = Optimizations.start(deck, %{}, @two_lenses)

      {:ok, live, html} = live(conn, ~p"/decks/#{deck.id}/otimizacoes")
      assert html =~ "agora: Mana"

      live |> element("button[phx-click='abrir-lancador']") |> render_click()

      live
      |> form("#launch-form",
        contract: %{
          "bracket_max" => "3",
          "ceiling_card" => "",
          "ceiling_land" => "",
          "keep" => "",
          "matchups" => "",
          "notes" => "",
          "model" => "fable"
        }
      )
      |> render_submit()

      assert [_only_one] = Optimizations.list_for_deck(deck.id)
    end
  end

  describe "the timeline" do
    test "shows stages live: leitura, applied, rejected with reasons", %{conn: conn} do
      deck = deck()
      {:ok, optimization} = Optimizations.start(deck, %{"keep" => ["Sol Ring"]}, @two_lenses)

      {:ok, live_early, html_early} = live(conn, ~p"/otimizacoes/#{optimization.id}")
      assert html_early =~ "Mana"
      assert html_early =~ "consultando…"
      assert html_early =~ "etapa 1/2"
      assert page_title(live_early) =~ "1/2 · Otimização"

      {:ok, _after} = run_first_stage(optimization, ["Sol Ring"], ["Cultivate"])

      {:ok, _live, html} = live(conn, ~p"/otimizacoes/#{optimization.id}")

      assert html =~ "Leitura da etapa."
      assert html =~ "Cultivate"
      assert html =~ "Recusadas pelo motor"
      assert html =~ "lista de proteção"
      # The evolution chip: 5 cards + the applied Cultivate.
      assert html =~ "6 cartas"
    end

    test "feedback round-trips", %{conn: conn} do
      deck = deck()
      {:ok, optimization} = Optimizations.start(deck, %{}, @two_lenses)
      {:ok, done} = run_first_stage(optimization, [], ["Cultivate"])
      step = hd(done.steps)

      {:ok, live, _html} = live(conn, ~p"/otimizacoes/#{optimization.id}")

      live
      |> element("button[phx-value-step='#{step.id}'][phx-value-rating='up']")
      |> render_click()

      live
      |> form("#nota-#{step.id}", feedback: %{"note" => "gostei do corte"})
      |> render_submit()

      {:ok, refreshed} = Optimizations.fetch(optimization.id)
      feedback = hd(refreshed.steps).feedback
      assert feedback["rating"] == "up"
      assert feedback["note"] == "gostei do corte"
    end

    test "criar deck deste ponto forks the stage's list", %{conn: conn} do
      deck = deck()
      {:ok, optimization} = Optimizations.start(deck, %{}, @two_lenses)
      {:ok, done} = run_first_stage(optimization, [], ["Cultivate"])
      step = hd(done.steps)

      {:ok, live, _html} = live(conn, ~p"/otimizacoes/#{optimization.id}")

      live
      |> element("button[phx-click='criar-deck'][phx-value-step='#{step.id}']")
      |> render_click()

      forked = Enum.find(Decks.list_decks(), &(&1.name =~ "etapa 1"))
      assert forked

      names = forked |> Decks.snapshot() |> Map.get(:main) |> Enum.map(& &1.card.name)
      assert "Cultivate" in names
      # The original deck was never written.
      original_names = deck |> Decks.snapshot() |> Map.get(:main) |> Enum.map(& &1.card.name)
      refute "Cultivate" in original_names
    end

    test "pause and resume drive the run from the page", %{conn: conn} do
      deck = deck()
      {:ok, optimization} = Optimizations.start(deck, %{}, @two_lenses)

      {:ok, live, _html} = live(conn, ~p"/otimizacoes/#{optimization.id}")

      html = live |> element("button[phx-click='pausar']") |> render_click()
      assert html =~ "pausada"

      html = live |> element("button[phx-click='retomar']") |> render_click()
      assert html =~ "rodando"
    end
  end

  describe "reimaginar" do
    test "the launcher starts a reimagine run carrying the salt contract", %{conn: conn} do
      deck = deck()
      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}/otimizacoes")

      live |> element("button[phx-click='abrir-lancador']") |> render_click()

      html = live |> element("button[phx-value-modo='reimagine']") |> render_click()
      assert html =~ "O que você não quer na mesa"

      live
      |> element("button[phx-value-tatica='stax'][phx-value-valor='evitar']")
      |> render_click()

      assert {:error, {:live_redirect, _}} =
               live
               |> form("#launch-form",
                 contract: %{
                   "bracket_max" => "3",
                   "ceiling_card" => "800",
                   "ceiling_land" => "200",
                   "keep" => "",
                   "matchups" => "",
                   "notes" => "",
                   "model" => "fable"
                 }
               )
               |> render_submit()

      assert [run] = Optimizations.list_for_deck(deck.id)
      assert run.mode == :reimagine
      assert run.contract["salt"]["stax"] == "evitar"
      assert hd(run.steps).lens == "visao"
    end

    test "a contract that contradicts itself is refused before it spends", %{conn: conn} do
      deck = deck()
      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}/otimizacoes")

      live |> element("button[phx-click='abrir-lancador']") |> render_click()
      live |> element("button[phx-value-modo='reimagine']") |> render_click()

      live
      |> element("button[phx-value-tatica='mass_land_denial'][phx-value-valor='quero']")
      |> render_click()

      html =
        live
        |> form("#launch-form",
          contract: %{
            "bracket_max" => "3",
            "ceiling_card" => "",
            "ceiling_land" => "",
            "keep" => "",
            "matchups" => "",
            "notes" => "",
            "model" => "fable"
          }
        )
        |> render_submit()

      # Nothing launched, the modal stayed open so the owner can fix it, and
      # the reason actually reached the screen.
      assert Optimizations.list_for_deck(deck.id) == []
      assert html =~ "O que você não quer na mesa"
      assert html =~ "Bracket 4"
    end

    test "refining still starts a refine run with no salt", %{conn: conn} do
      deck = deck()
      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}/otimizacoes")

      live |> element("button[phx-click='abrir-lancador']") |> render_click()

      assert {:error, {:live_redirect, _}} =
               live
               |> form("#launch-form",
                 contract: %{
                   "bracket_max" => "3",
                   "ceiling_card" => "",
                   "ceiling_land" => "",
                   "keep" => "",
                   "matchups" => "",
                   "notes" => "",
                   "model" => "fable"
                 }
               )
               |> render_submit()

      assert [run] = Optimizations.list_for_deck(deck.id)
      assert run.mode == :refine
      assert run.contract["salt"] == %{}
    end
  end

  describe "the deck page" do
    test "gains the Otimizar button and hides pipeline consults", %{conn: conn} do
      deck = deck()
      {:ok, optimization} = Optimizations.start(deck, %{}, @two_lenses)
      {:ok, _done} = run_first_stage(optimization, [], ["Cultivate"])

      {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

      # With a run alive, the deck page's button becomes the way back to it.
      assert html =~ "Otimização rodando"
      assert html =~ ~s(href="/otimizacoes/#{optimization.id}")
      refute html =~ ">Otimizar<"
      # The pipeline consult exists but never surfaces here.
      refute html =~ "Leitura da etapa."
      assert Consults.list_for_deck(deck) == []
    end
  end
end
