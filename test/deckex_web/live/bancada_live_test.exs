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

  describe "the keyboard" do
    setup %{conn: conn} do
      {_deck, optimization} = parked_run()
      {:ok, view, _html} = live(conn, ~p"/otimizacoes/#{optimization.id}/bancada")

      %{view: view, optimization: optimization}
    end

    # The regression that matters: a window key listener hears every key, and
    # the LiveView used to raise `FunctionClauseError` on the first letter —
    # killing the process and losing the cursor on remount.
    test "a key that means nothing here is ignored, not a crash", %{view: view} do
      for key <- ~w(a Z 9 Shift Tab F5 Dead) do
        render_hook(view, "tecla", %{"key" => key})
      end

      assert render(view) =~ "Bancada"
    end

    test "0 skips the vacancy on screen", %{view: view} do
      render_hook(view, "tecla", %{"acao" => "pular"})

      assert render(view) =~ "1 de 4"
      assert render(view) =~ "100"
    end

    test "U undoes the vacancy on screen", %{view: view} do
      render_hook(view, "tecla", %{"n" => 1})
      assert render(view) =~ "99"

      render_hook(view, "tecla", %{"acao" => "desfazer"})
      assert render(view) =~ "100"
    end

    test "the shortcuts sheet opens, and every path out closes it", %{view: view} do
      html = view |> element(~s(button[phx-click="atalhos"])) |> render_click()

      assert html =~ "Atalhos"
      assert html =~ "nenhuma destas"

      # Escape, via the hook. Closing twice must stay closed — the old wiring
      # had two window listeners whose toggles cancelled and reopened it.
      render_hook(view, "tecla", %{"acao" => "fechar-paineis"})
      render_hook(view, "fechar-atalhos", %{})
      refute render(view) =~ ~s(role="dialog")

      # And the X, which is idempotent rather than a toggle.
      view |> element(~s(header button[phx-click="atalhos"])) |> render_click()
      view |> element(~s(button[phx-click="fechar-atalhos"])) |> render_click()
      refute render(view) =~ ~s(role="dialog")
    end
  end

  describe "hostile payloads" do
    setup %{conn: conn} do
      {_deck, optimization} = parked_run()
      {:ok, view, _html} = live(conn, ~p"/otimizacoes/#{optimization.id}/bancada")

      %{view: view}
    end

    # `Enum.at/2` wraps a negative index to the END of the list, so an
    # unguarded n=0 silently picked the LAST candidate — a selection the owner
    # never made, which is the one failure this screen exists to prevent.
    test "n=0 picks nothing instead of wrapping to the last candidate", %{view: view} do
      render_hook(view, "tecla", %{"n" => 0})
      render_hook(view, "tecla", %{"n" => -1})
      render_hook(view, "tecla", %{"n" => "1"})

      assert render(view) =~ "0 de 4"
      assert render(view) =~ "100"
    end

    test "a junk filter is ignored, not a crash", %{view: view} do
      quadro(view)
      render_hook(view, "filtrar", %{"filtro" => "nao_existe"})
      render_hook(view, "filtrar", %{"filtro" => "ok"})

      assert render(view) =~ "Sai do deck"
    end

    test "a stale vacancy key is ignored, not a crash", %{view: view} do
      render_hook(view, "escolher", %{"vaga" => "add:99", "carta" => "Sol Ring"})
      render_hook(view, "limpar", %{"vaga" => "cut:99"})

      assert render(view) =~ "0 de 4"
    end
  end

  describe "the cursor when the reserve opens" do
    # Picking the add that opens the reserve inserts cut vacancies BEFORE the
    # adds, so a numeric +1 landed him back on the vacancy he had just
    # answered. Advancing from the answered KEY survives the insertion.
    test "a pick advances to the next vacancy, not back onto itself", %{conn: conn} do
      {_deck, optimization} = parked_run()

      {:ok, view, _html} = live(conn, ~p"/otimizacoes/#{optimization.id}/bancada")

      # Jump to add:0 and pick — net +1 opens the reserve cut.
      view |> element(~s(button[phx-value-fase="quadro"])) |> render_click()
      view |> element(~s(button[phx-value-chave="add:0"])) |> render_click()
      render_hook(view, "tecla", %{"n" => 1})

      html = render(view)
      assert html =~ "O deck não compra carta nenhuma."
      refute html =~ "Sua curva quer aceleração de 3."
    end

    test "undoing the add folds the reserve without stranding the cursor", %{conn: conn} do
      {_deck, optimization} = parked_run()

      {:ok, view, _html} = live(conn, ~p"/otimizacoes/#{optimization.id}/bancada")

      quadro(view)
      pick(view, "add:0", "Cultivate")

      # The board now shows the reserve; undo the add from the last vacancy.
      view |> element(~s(button[phx-value-chave="add:1"])) |> render_click()
      render_hook(view, "limpar", %{"vaga" => "add:0"})

      # `visible` shrank under the cursor and the page still stands.
      assert render(view) =~ "de 4"
    end
  end

  describe "judging a card" do
    test "every candidate carries its rules text", %{conn: conn} do
      {_deck, optimization} = parked_run()

      {:ok, view, html} = live(conn, ~p"/otimizacoes/#{optimization.id}/bancada")

      # Forest's oracle text, which is what the choice is actually made on.
      assert html =~ "Add"

      html = view |> element(~s(button[phx-click="texto"])) |> render_click()

      refute html =~ "esconder o texto das cartas"
      assert html =~ "mostrar o texto das cartas"
    end

    test "a candidate's accessible name is the card, not the whole tile", %{conn: conn} do
      {_deck, optimization} = parked_run()

      {:ok, _view, html} = live(conn, ~p"/otimizacoes/#{optimization.id}/bancada")

      assert html =~ ~s(aria-label="Opção 1: Forest")
    end
  end

  describe "the owner's own words" do
    test "a cut candidate carries the note he wrote about it", %{conn: conn} do
      {deck, optimization} = parked_run()

      {:ok, _note} =
        Decks.put_card_note(deck, "Forest", "essa floresta é a que o Nissa busca")

      {:ok, _view, html} = live(conn, ~p"/otimizacoes/#{optimization.id}/bancada")

      # His words, above the model's argument, labelled as his.
      assert html =~ "essa floresta é a que o Nissa busca"
      assert html =~ "Você"
    end
  end

  describe "the board's filters" do
    setup %{conn: conn} do
      {_deck, optimization} = parked_run()
      {:ok, view, _html} = live(conn, ~p"/otimizacoes/#{optimization.id}/bancada")
      quadro(view)

      %{view: view}
    end

    test "narrow the board to what he is looking for", %{view: view} do
      pick(view, "cut:0", "Forest")

      html = view |> element(~s(button[phx-value-filtro="escolhidas"])) |> render_click()

      assert html =~ "Noventa e oito florestas é terreno demais."
      refute html =~ "Llanowar morre a qualquer varrida."

      html = view |> element(~s(button[phx-value-filtro="indecisas"])) |> render_click()

      refute html =~ "Noventa e oito florestas é terreno demais."
      assert html =~ "Llanowar morre a qualquer varrida."
    end

    test "say plainly when nothing matches", %{view: view} do
      html = view |> element(~s(button[phx-value-filtro="escolhidas"])) |> render_click()

      assert html =~ "Nenhuma vaga com esse filtro"
    end

    test "a vacancy on the board opens in triage", %{view: view} do
      html = view |> element(~s(button[phx-value-chave="add:0"])) |> render_click()

      assert html =~ "Sua curva quer aceleração de 3."
      assert html =~ "Nenhuma destas"
    end
  end

  describe "the round as a list" do
    test "the rail can show back what he chose", %{conn: conn} do
      {_deck, optimization} = parked_run()

      {:ok, view, _html} = live(conn, ~p"/otimizacoes/#{optimization.id}/bancada")

      html = view |> element(~s(button[phx-click="resumo"])) |> render_click()
      assert html =~ "Nada escolhido ainda"

      quadro(view)
      pick(view, "add:0", "Cultivate")
      html = render(view)

      assert html =~ "Suas escolhas"
      assert html =~ "Cultivate"
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
