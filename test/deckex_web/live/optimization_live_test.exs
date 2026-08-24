defmodule DeckexWeb.OptimizationLiveTest do
  use DeckexWeb.ConnCase, async: true
  use Oban.Testing, repo: Deckex.Repo

  import Mox
  import Phoenix.LiveViewTest

  alias Deckex.CatalogueFixture
  alias Deckex.Consults
  alias Deckex.Decks
  alias Deckex.Decks.Deck
  alias Deckex.Decks.Versions
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

  # The floor filters this picker, and a floor set to the strongest model left
  # it with one option — for everyone, out of the box.
  describe "the model picker" do
    test "offers every model at or above the floor, and says what the floor is",
         %{conn: conn} do
      deck = deck()

      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}/otimizacoes")
      html = live |> element("button[phx-click='abrir-lancador']") |> render_click()

      assert html =~ ~s(<option value="opus")
      assert html =~ ~s(<option value="sonnet")
      assert html =~ "Piso:"
    end

    test "a run really can be launched on opus", %{conn: conn} do
      deck = deck()

      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}/otimizacoes")
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
          "model" => "opus"
        }
      )
      |> render_submit()

      assert [run] = Optimizations.list_for_deck(deck.id)
      assert run.contract["model"] == "opus"
    end
  end

  # A run is an argument about a list, so which list it argued about is part of
  # the record — and the answer is almost always "a mais nova".
  describe "starting from a version" do
    test "the launcher offers the versions, newest first and already chosen", %{conn: conn} do
      deck = deck()
      {:ok, _} = Decks.add_card(deck, "Cultivate")
      {:ok, _v2} = Versions.mark(deck, label: "Antes de otimizar")

      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}/otimizacoes")
      html = live |> element("button[phx-click='abrir-lancador']") |> render_click()

      assert html =~ "A partir de qual versão"
      assert html =~ "mais recente"
      assert html =~ "Antes de otimizar"
    end

    test "the run starts from the chosen version's list", %{conn: conn} do
      deck = deck()
      {:ok, v1} = Versions.fetch(deck, 1)
      # v1 has no Cultivate; the deck does now.
      {:ok, _} = Decks.add_card(deck, "Cultivate")
      {:ok, _v2} = Versions.mark(deck)

      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}/otimizacoes")
      live |> element("button[phx-click='abrir-lancador']") |> render_click()

      live
      |> form("#launch-form",
        contract: %{
          "from_version" => to_string(v1.number),
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

      [run] = Optimizations.list_for_deck(deck.id)

      assert run.contract["from_version"] == 1
      refute Enum.any?(run.list_original, &(&1["name"] == "Cultivate"))
    end

    test "the run page says which version it started from", %{conn: conn} do
      deck = deck()
      {:ok, run} = Optimizations.start(deck, %{"from_version" => 1}, @two_lenses)

      {:ok, _live, html} = live(conn, ~p"/otimizacoes/#{run.id}")

      assert html =~ "a partir da v1"
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

    # What the owner asked for: an applied optimization is a version of the same
    # deck, not a second deck beside it.
    test "aplicar até aqui writes the stage's list onto the deck itself", %{conn: conn} do
      deck = deck()
      {:ok, optimization} = Optimizations.start(deck, %{}, @two_lenses)
      {:ok, done} = run_first_stage(optimization, [], ["Cultivate"])
      step = hd(done.steps)

      {:ok, live, _html} = live(conn, ~p"/otimizacoes/#{optimization.id}")

      live
      |> element("button[phx-click='aplicar-no-deck'][phx-value-step='#{step.id}']")
      |> render_click()

      assert length(Decks.list_decks()) == 1

      names = deck |> Decks.snapshot() |> Map.get(:main) |> Enum.map(& &1.card.name)
      assert "Cultivate" in names

      [latest | _older] = Versions.list(deck)
      assert latest.origin == :optimization
    end

    # Applying the same run twice is one click away, and the history is opened
    # with exactly this question: which of these did I already put in the deck?
    test "a run already applied says so on both screens", %{conn: conn} do
      deck = deck()
      {:ok, optimization} = Optimizations.start(deck, %{}, @two_lenses)
      {:ok, done} = run_first_stage(optimization, [], ["Cultivate"])
      step = hd(done.steps)

      {:ok, live, _html} = live(conn, ~p"/otimizacoes/#{optimization.id}")

      live
      |> element("button[phx-click='aplicar-no-deck'][phx-value-step='#{step.id}']")
      |> render_click()

      {:ok, _run_live, run_html} = live(conn, ~p"/otimizacoes/#{optimization.id}")
      assert run_html =~ "já aplicada · v2"

      {:ok, _history, history_html} = live(conn, ~p"/decks/#{deck.id}/otimizacoes")
      assert history_html =~ "aplicada · v2"
    end

    # The whole point: a card cut on a misreading — Jaheira turns Food into
    # creatures that tap for mana — had nowhere to be argued with.
    test "marking a card while reading, and saying why at the end", %{conn: conn} do
      deck = deck()
      {:ok, optimization} = Optimizations.start(deck, %{}, @two_lenses)
      {:ok, _done} = run_first_stage(optimization, [], ["Cultivate"])

      {:ok, live, _html} = live(conn, ~p"/otimizacoes/#{optimization.id}")

      marked =
        live
        |> element("button[phx-click='marcar'][phx-value-card='Cultivate']")
        |> render_click()

      assert marked =~ "Desmarcar Cultivate"
      assert [%{card_name: "Cultivate", action: :add}] = Optimizations.marks(optimization)

      # The note comes at the end, when the run has stopped moving — so the
      # form for it does not exist yet, on purpose.
      refute marked =~ "Sua revisão"

      {:ok, _second} = run_first_stage(optimization, [], [])

      {:ok, ended, html} = live(conn, ~p"/otimizacoes/#{optimization.id}")
      assert html =~ "Sua revisão"

      [mark] = Optimizations.marks(optimization)

      ended
      |> form("#nota-carta-#{mark.id}", %{card: "Cultivate", nota: "essa eu não quero"})
      |> render_change()

      assert [%{note: "essa eu não quero"}] = Optimizations.marks(optimization)
    end

    test "the review runs as one last stage", %{conn: conn} do
      deck = deck()
      {:ok, optimization} = Optimizations.start(deck, %{}, @two_lenses)
      {:ok, _first} = run_first_stage(optimization, [], ["Cultivate"])
      {:ok, second} = run_first_stage(optimization, [], [])

      assert second.status == :done

      {:ok, live, _html} = live(conn, ~p"/otimizacoes/#{optimization.id}")

      live
      |> form("#revisao", revisao: %{geral: "cortou coisa do tema"})
      |> render_submit()

      {:ok, reviewing} = Optimizations.fetch(optimization.id)

      assert %{kind: :revisao, label: "Revisão do dono"} = List.last(reviewing.steps)
      assert reviewing.contract["revisao_geral"] == "cortou coisa do tema"
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
