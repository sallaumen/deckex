defmodule DeckexWeb.BancadaLiveTest do
  use DeckexWeb.ConnCase, async: true
  use Oban.Testing, repo: Deckex.Repo

  import Mox
  import Phoenix.LiveViewTest

  alias Deckex.CatalogueFixture
  alias Deckex.Decks
  alias Deckex.Decks.Deck
  alias Deckex.Optimizations
  alias Deckex.Workers.ConsultWorker
  alias Deckex.Workers.OptimizationAdvanceWorker

  setup :verify_on_exit!

  @contract %{"mode" => :curadoria, "vagas_corte" => 2, "vagas_entrada" => 3}

  defp vacancy(grupo, vaga, cards) do
    %{
      "grupo" => grupo,
      "vaga" => vaga,
      "candidatos" => Enum.map(cards, &%{"carta" => &1, "porque" => "porque #{&1}"})
    }
  end

  defp cardapio do
    %{
      "leitura" => "Leitura sintética.",
      "cortes" => [
        vacancy("Terreno demais", "Noventa e oito florestas é terreno demais.", ["Forest"]),
        vacancy("Ramp fraco", "Llanowar morre a qualquer varrida.", ["Llanowar Elves"]),
        vacancy("Reserva", "Vaga extra de corte.", ["Forest"])
      ],
      "adicoes" => [
        vacancy("Ramp", "Sua curva quer aceleração de 3.", ["Cultivate", "Sol Ring"]),
        vacancy("Compra", "O deck não compra carta nenhuma.", ["Rhystic Study"])
      ]
    }
  end

  defp plan do
    %{
      "leitura" => "Leitura.",
      "problemas" => [],
      "nao_mexer" => "Nada.",
      "plano" => "Plano.",
      "sinergias" => "Sinergias.",
      "linhas_de_vitoria" => "Vitória.",
      "fraquezas" => "Fraquezas."
    }
  end

  defp answer(optimization_id, response) do
    expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts -> {:ok, response} end)

    {:ok, optimization} = Optimizations.fetch(optimization_id)
    step = Enum.find(optimization.steps, &(&1.status == :running))

    :ok = perform_job(ConsultWorker, %{consult_id: step.consult_id})
    :ok = perform_job(OptimizationAdvanceWorker, %{consult_id: step.consult_id})

    Optimizations.fetch(optimization_id)
  end

  defp parked_run(contract \\ @contract) do
    CatalogueFixture.seed!(~w(sol_ring forest cultivate llanowar_elves rhystic_study))

    stub(Deckex.Scryfall.Mock, :fetch_by_names, fn names ->
      {:ok, %{found: [], not_found: names}}
    end)

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n98 Forest\n1 Llanowar Elves", %{
        name: "Deck da Bancada",
        source: :paste
      })

    deck = deck |> Deck.changeset(%{color_identity: ["G", "U"]}) |> Deckex.Repo.update!()

    {:ok, optimization} = Optimizations.start(deck, contract)
    {:ok, _planned} = answer(optimization.id, plan())
    {:ok, waiting} = answer(optimization.id, cardapio())

    {deck, waiting}
  end

  defp quadro(view), do: view |> element(~s(button[phx-value-fase="quadro"])) |> render_click()

  # Scoped by vacancy: the same card can be offered by two vacancies, and the
  # reserve deliberately re-offers Forest.
  defp pick(view, vaga, card) do
    view
    |> element(~s(button[phx-value-vaga="#{vaga}"][phx-value-carta="#{card}"]))
    |> render_click()
  end

  describe "getting there" do
    test "the run page calls him over while a board is open", %{conn: conn} do
      {_deck, optimization} = parked_run()

      {:ok, _view, html} = live(conn, ~p"/otimizacoes/#{optimization.id}")

      assert html =~ "Sua vez"
      assert html =~ "vagas esperando você"
      assert html =~ ~s(href="/otimizacoes/#{optimization.id}/bancada")
    end

    test "a run with no board open sends him back to the timeline", %{conn: conn} do
      CatalogueFixture.seed!(~w(sol_ring forest))

      stub(Deckex.Scryfall.Mock, :fetch_by_names, fn names ->
        {:ok, %{found: [], not_found: names}}
      end)

      {:ok, deck} =
        Decks.import_from_text("1 Sol Ring\n4 Forest", %{name: "Sem bancada", source: :paste})

      {:ok, optimization} = Optimizations.start(deck, %{"mode" => :refine})

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/otimizacoes/#{optimization.id}/bancada")

      assert to == "/otimizacoes/#{optimization.id}"
    end
  end

  describe "triage" do
    test "opens on the first vacancy with the need as the headline", %{conn: conn} do
      {_deck, optimization} = parked_run()

      {:ok, _view, html} = live(conn, ~p"/otimizacoes/#{optimization.id}/bancada")

      assert html =~ "Noventa e oito florestas é terreno demais."
      assert html =~ "Terreno demais"
      assert html =~ "1 de 4"
    end

    test "hides the reserve until the count asks for it", %{conn: conn} do
      {_deck, optimization} = parked_run()

      {:ok, view, html} = live(conn, ~p"/otimizacoes/#{optimization.id}/bancada")

      refute html =~ "Vaga extra de corte."

      # One entry with nothing paying for it, and the reserve cut is there.
      quadro(view)
      html = pick(view, "add:0", "Cultivate")

      assert html =~ "101"
      assert quadro(view) =~ "Vaga extra de corte."
    end

    test "a pick moves him on, and the rail moves with him", %{conn: conn} do
      {_deck, optimization} = parked_run()

      {:ok, view, html} = live(conn, ~p"/otimizacoes/#{optimization.id}/bancada")

      assert html =~ "100"

      view |> element(~s(button[phx-value-carta="Forest"])) |> render_click()
      html = render(view)

      # The count fell to 99 and the cursor advanced to the next vacancy.
      assert html =~ "99"
      assert html =~ "Llanowar morre a qualquer varrida."
    end

    test "skipping counts as decided without changing the deck", %{conn: conn} do
      {_deck, optimization} = parked_run()

      {:ok, view, html} = live(conn, ~p"/otimizacoes/#{optimization.id}/bancada")

      assert html =~ "0 de 4"

      html = view |> element(~s(button[phx-click="pular"])) |> render_click()

      assert html =~ "1 de 4"
      assert html =~ "decididas"
      # A skip is a decision about a vacancy, never a change to the list.
      assert html =~ "100"
    end

    test "the keyboard picks the nth candidate of the vacancy on screen", %{conn: conn} do
      {_deck, optimization} = parked_run()

      {:ok, view, _html} = live(conn, ~p"/otimizacoes/#{optimization.id}/bancada")

      render_hook(view, "tecla", %{"n" => 1})

      assert render(view) =~ "99"
    end
  end

  describe "the board" do
    test "groups the vacancies by the reason they exist", %{conn: conn} do
      {_deck, optimization} = parked_run()

      {:ok, view, _html} = live(conn, ~p"/otimizacoes/#{optimization.id}/bancada")

      html = view |> element(~s(button[phx-value-fase="quadro"])) |> render_click()

      assert html =~ "Sai do deck"
      assert html =~ "Entra no deck"
      assert html =~ "Terreno demais"
      assert html =~ "Ramp"
      assert html =~ "Compra"
    end

    test "says the reserve exists without opening it", %{conn: conn} do
      {_deck, optimization} = parked_run()

      {:ok, view, _html} = live(conn, ~p"/otimizacoes/#{optimization.id}/bancada")
      html = view |> element(~s(button[phx-value-fase="quadro"])) |> render_click()

      assert html =~ "vagas de corte na reserva"
      refute html =~ "Vaga extra de corte."
    end
  end

  describe "the rail" do
    test "refuses to close off 100, and says by how much", %{conn: conn} do
      {_deck, optimization} = parked_run()

      {:ok, view, _html} = live(conn, ~p"/otimizacoes/#{optimization.id}/bancada")

      quadro(view)
      html = pick(view, "add:0", "Cultivate")

      assert html =~ "101 cartas"
      assert html =~ "Corte mais 1"
      assert html =~ ~r/<button[^>]*disabled/
    end

    test "opens the gate once the count lands on 100", %{conn: conn} do
      {_deck, optimization} = parked_run()

      {:ok, view, _html} = live(conn, ~p"/otimizacoes/#{optimization.id}/bancada")

      quadro(view)
      pick(view, "add:0", "Cultivate")
      html = pick(view, "cut:0", "Forest")

      refute html =~ "Corte mais"
      assert html =~ "Fechar a rodada"
    end

    test "warns before the engine's refusal instead of after it", %{conn: conn} do
      # Rhystic Study is US$ 69.24 — far over a R$ 100 ceiling.
      {_deck, optimization} =
        parked_run(Map.put(@contract, "ceilings", %{"card" => 100, "land" => 100}))

      {:ok, view, _html} = live(conn, ~p"/otimizacoes/#{optimization.id}/bancada")

      # Said on the board, before the click, not after it.
      assert quadro(view) =~ "passa do teto de R$ 100"
    end
  end

  describe "closing" do
    test "audits the choices and hands the run to the critic", %{conn: conn} do
      {_deck, optimization} = parked_run()

      {:ok, view, _html} = live(conn, ~p"/otimizacoes/#{optimization.id}/bancada")

      quadro(view)
      pick(view, "add:0", "Cultivate")
      pick(view, "cut:0", "Forest")

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> element(~s(button[phx-click="fechar"])) |> render_click()

      assert to == "/otimizacoes/#{optimization.id}"

      {:ok, moved} = Optimizations.fetch(optimization.id)
      cardapio_step = Enum.find(moved.steps, &(&1.kind == :cardapio))

      assert [
               %{"action" => "cut", "card" => "Forest"},
               %{"action" => "add", "card" => "Cultivate"}
             ] = cardapio_step.applied
    end
  end

  describe "coming back" do
    test "the choices survive a remount, and he lands on the first open one", %{conn: conn} do
      {_deck, optimization} = parked_run()

      {:ok, view, _html} = live(conn, ~p"/otimizacoes/#{optimization.id}/bancada")
      view |> element(~s(button[phx-value-carta="Forest"])) |> render_click()

      {:ok, _fresh, html} = live(conn, ~p"/otimizacoes/#{optimization.id}/bancada")

      # The count remembers the cut, and he opens on the vacancy after it.
      assert html =~ "99"
      assert html =~ "Llanowar morre a qualquer varrida."
      assert html =~ "2 de 4"
    end
  end
end
