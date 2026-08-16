defmodule Deckex.Optimizations.ReviewTest do
  use Deckex.DataCase, async: true

  alias Deckex.CatalogueFixture
  alias Deckex.Consults.Briefing
  alias Deckex.Decks
  alias Deckex.Error
  alias Deckex.Optimizations
  alias Deckex.Optimizations.Mark
  alias Deckex.Optimizations.Optimization
  alias Deckex.Optimizations.OptimizationStep

  defp deck do
    CatalogueFixture.seed!(~w(sol_ring forest natures_lore cultivate counterspell))

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n1 Cultivate\n4 Forest", %{
        name: "Deck da Revisão",
        source: :paste
      })

    deck
  end

  defp finished_run(deck) do
    {:ok, run} =
      Optimizations.start(deck, %{}, [%{"kind" => "lens", "lens" => "full", "label" => "Tudo"}])

    [step] = run.steps

    applied = [%{"action" => "cut", "card" => "Cultivate", "reason" => "só faz mana"}]

    {:ok, _step} =
      step
      |> OptimizationStep.changeset(%{
        status: :done,
        applied: applied,
        list_after: Optimizations.apply_changes_to_list(step.list_before, applied)
      })
      |> Repo.update()

    {:ok, run} = Optimizations.fetch(run.id)
    {:ok, done} = Optimizations.cancel(run)

    done
    |> Optimization.changeset(%{status: :done, outcome: "completo"})
    |> Repo.update!()

    {:ok, run} = Optimizations.fetch(run.id)

    run
  end

  describe "marking a card while reading" do
    test "the mark toggles and remembers what the run did to it" do
      run = finished_run(deck())

      {:ok, :marked} = Optimizations.toggle_mark(run, "Cultivate", :cut)

      assert [%{card_name: "Cultivate", action: :cut, note: nil}] = Optimizations.marks(run)

      {:ok, :unmarked} = Optimizations.toggle_mark(run, "Cultivate", :cut)
      assert Optimizations.marks(run) == []
    end

    test "the note is written against the mark" do
      run = finished_run(deck())
      {:ok, :marked} = Optimizations.toggle_mark(run, "Cultivate", :cut)

      {:ok, mark} = Optimizations.note_mark(run, "Cultivate", "entendeu errado, ela fixa cor")

      assert mark.note == "entendeu errado, ela fixa cor"
    end

    test "a note on a card nobody marked is not a note" do
      run = finished_run(deck())

      assert Optimizations.note_mark(run, "Sol Ring", "nada") == :error
    end
  end

  describe "review/2" do
    test "appends one last stage and starts it" do
      run = finished_run(deck())
      {:ok, :marked} = Optimizations.toggle_mark(run, "Cultivate", :cut)
      {:ok, _mark} = Optimizations.note_mark(run, "Cultivate", "ela fixa cor, o corte foi errado")

      {:ok, reviewing} = Optimizations.review(run, "")

      assert reviewing.status == :running
      assert %{kind: :revisao, label: "Revisão do dono"} = List.last(reviewing.steps)
    end

    # The correction cost a run to notice and a review to say. It belongs to the
    # deck now, and the next run will carry it without being asked.
    test "what he said about a card becomes the deck's memory" do
      deck = deck()
      run = finished_run(deck)
      {:ok, :marked} = Optimizations.toggle_mark(run, "Cultivate", :cut)
      {:ok, _mark} = Optimizations.note_mark(run, "Cultivate", "ela fixa cor, não é só rampa")

      {:ok, _reviewing} = Optimizations.review(run, "")

      assert [%{card_name: "Cultivate", note: "ela fixa cor, não é só rampa", source: :review}] =
               Decks.card_notes(deck)
    end

    test "the general note alone is enough" do
      run = finished_run(deck())

      {:ok, reviewing} = Optimizations.review(run, "ficou lento demais")

      assert reviewing.contract["revisao_geral"] == "ficou lento demais"
      assert %{kind: :revisao} = List.last(reviewing.steps)
    end

    # A stage that costs a consult and has nothing to answer is a stage that
    # spends money to say nothing.
    test "nothing written, nothing to review" do
      run = finished_run(deck())
      {:ok, :marked} = Optimizations.toggle_mark(run, "Cultivate", :cut)

      assert {:error, %Error{code: :nothing_to_review}} = Optimizations.review(run, "   ")
    end

    # Every review is a paid consult. Three rounds of "não é bem isso" is a
    # conversation; the fourth is a new optimization wearing the old one's
    # clothes.
    test "the loop is bounded" do
      run = finished_run(deck())

      run =
        Enum.reduce(1..3, run, fn _round, run ->
          {:ok, reviewing} = Optimizations.review(run, "de novo")

          # The stage it just queued would land and finish the run; here it is
          # settled by hand so the next round can ask for another review.
          reviewing |> Optimization.changeset(%{status: :done}) |> Repo.update!()

          {:ok, refreshed} = Optimizations.fetch(run.id)
          refreshed
        end)

      assert Optimizations.reviews_spent(run) == 3
      refute Optimizations.reviewable?(run)

      assert {:error, %Error{code: :review_limit_reached}} = Optimizations.review(run, "mais uma")
    end

    test "the review is the last stage, not a stage in the middle" do
      deck = deck()

      {:ok, running} =
        Optimizations.start(deck, %{}, [%{"kind" => "lens", "lens" => "full", "label" => "Tudo"}])

      assert {:error, %Error{code: :optimization_not_done}} =
               Optimizations.review(running, "qualquer coisa")
    end
  end

  describe "the briefing the review sends" do
    test "carries the card, what the run did to it, and what he said" do
      snapshot = Deckex.AnalysisFixture.snapshot([])
      report = Deckex.Analysis.report(snapshot)

      briefing =
        Briefing.build(report, snapshot, :revisao,
          optimization: %{
            contract: %{"bracket_max" => 3, "revisao_geral" => "ficou lento"},
            changelog: [],
            stage_kind: :revisao,
            marks: [
              %Mark{
                card_name: "Jaheira, Friend of the Forest",
                action: :cut,
                note: "ela transforma Food em criatura que tapa por mana"
              }
            ]
          }
        )

      assert briefing =~ "Jaheira, Friend of the Forest"
      assert briefing =~ "the run cut it"
      assert briefing =~ "ela transforma Food em criatura"
      assert briefing =~ "ficou lento"
      # The instruction that makes the stage worth running at all.
      assert briefing =~ "he is right and the run was wrong"
    end
  end
end
