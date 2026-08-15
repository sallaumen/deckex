defmodule Deckex.Consults.AuditTest do
  use Deckex.DataCase, async: true

  alias Deckex.Analysis.CardEntry
  alias Deckex.Cards
  alias Deckex.CatalogueFixture
  alias Deckex.Consults
  alias Deckex.Consults.Audit
  alias Deckex.Consults.Suggestion
  alias Deckex.Decks
  alias Deckex.Decks.Deck
  alias Deckex.Settings

  # A pasted list with no commander has an empty colour identity — identity
  # comes from the commander alone. These tests model a mono-G commander deck,
  # so the identity is set the way a commander would set it.
  defp snapshot do
    CatalogueFixture.seed!(~w(sol_ring forest counterspell cultivate))

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n4 Forest", %{name: "Deck Auditado", source: :paste})

    deck
    |> Deck.changeset(%{color_identity: ["G"]})
    |> Repo.update!()
    |> Decks.snapshot()
  end

  defp sugg(action, name) do
    card = Cards.get_by_name(name)

    %Suggestion{action: action, name: name, reason: "t", card: card, resolved?: card != nil}
  end

  describe "audit/2" do
    test "an add outside the colour identity is named illegal" do
      audit = Consults.audit(snapshot(), [sugg(:add, "Counterspell")])

      assert [problem] = audit.problems[{:add, "Counterspell"}]
      assert problem =~ "fora da identidade de cor"
    end

    test "an add of a singleton card already in the deck is refused by name" do
      audit = Consults.audit(snapshot(), [sugg(:add, "Sol Ring")])

      assert [problem] = audit.problems[{:add, "Sol Ring"}]
      assert problem =~ "singleton"
    end

    test "a basic land add repeats freely" do
      audit = Consults.audit(snapshot(), [sugg(:add, "Forest")])

      refute Map.has_key?(audit.problems, {:add, "Forest"})
    end

    test "a cut of a card that is not in the list is called out" do
      audit = Consults.audit(snapshot(), [sugg(:cut, "Cultivate")])

      assert [problem] = audit.problems[{:cut, "Cultivate"}]
      assert problem =~ "não está na lista"
    end

    test "a card that is not Commander-legal is named" do
      # snapshot/0 seeds the catalogue — sugg/2 can only resolve after it.
      snap = snapshot()
      %Suggestion{card: card} = base = sugg(:add, "Cultivate")

      audit =
        Consults.audit(snap, [%{base | card: %{card | commander_legal: false}}])

      assert Enum.any?(audit.problems[{:add, "Cultivate"}], &(&1 =~ "não é legal em Commander"))
    end

    test "clean suggestions simulate and diff the findings" do
      audit = Consults.audit(snapshot(), [sugg(:cut, "Sol Ring"), sugg(:add, "Cultivate")])

      assert audit.problems == %{}
      # A five-card deck fires findings before and after; the diff is total:
      # every before-finding is either resolved or remaining, never lost.
      assert audit.remaining != []
      assert is_list(audit.resolved) and is_list(audit.introduced)
    end

    test "an unresolved suggestion is excluded without complaint" do
      unresolved = %Suggestion{action: :add, name: "Carta Ignota", reason: "t", resolved?: false}

      audit = Consults.audit(snapshot(), [unresolved])

      assert audit.problems == %{}
      assert %Audit{} = audit
    end

    test "a suggestion with problems is left out of the simulation" do
      snap = snapshot()

      clean = Consults.audit(snap, [])
      with_illegal = Consults.audit(snap, [sugg(:add, "Counterspell")])

      # The illegal add must not move the measured findings at all.
      assert Enum.map(with_illegal.remaining, & &1.code) == Enum.map(clean.remaining, & &1.code)
      assert with_illegal.introduced == clean.introduced
    end
  end

  describe "price ceilings" do
    # Arid Mesa is US$ 29.97; at the default rate of 5.4 that is R$ 161.84.
    # Rhystic Study is US$ 69.24 — R$ 373.90.
    setup do
      CatalogueFixture.seed!(~w(sol_ring forest arid_mesa rhystic_study))

      {:ok, deck} =
        Decks.import_from_text("1 Sol Ring\n4 Forest", %{name: "Deck Caro", source: :paste})

      snapshot =
        deck
        |> Deck.changeset(%{color_identity: ["G", "R", "U"]})
        |> Repo.update!()
        |> Decks.snapshot()

      %{snapshot: snapshot}
    end

    defp priced(action, name) do
      card = Cards.get_by_name(name)

      %Suggestion{
        action: action,
        name: name,
        reason: "t",
        card: card,
        price_usd: card.price_usd,
        resolved?: true
      }
    end

    # Rhystic Study is also a Game Changer, so it collects a bracket note too;
    # these assertions look for the ceiling verdict among the problems rather
    # than assuming it is the only one.
    defp ceiling_verdict(audit, name) do
      audit.problems |> Map.get({:add, name}, []) |> Enum.find(&(&1 =~ "teto"))
    end

    defp note_for(audit, name), do: audit.notes |> Map.get({:add, name}, []) |> List.first()

    # The owner's rule, in his words: a card over the ceiling still gets in if
    # it is worth breaking the rule for — there are two slots for exactly that.
    test "a card over the ceiling spends an exception instead of being refused",
         %{snapshot: snapshot} do
      {:ok, _v} = Settings.put(:upgrade_max_brl, 100)

      audit = Consults.audit(snapshot, [priced(:add, "Rhystic Study")], :upgrade)

      refute ceiling_verdict(audit, "Rhystic Study")
      assert note_for(audit, "Rhystic Study") =~ "exceção 1 de 2"
    end

    test "with the slots full it is refused, named with both numbers", %{snapshot: snapshot} do
      {:ok, _v} = Settings.put(:upgrade_max_brl, 100)
      {:ok, _v} = Settings.put(:exception_card_max, 1)

      audit =
        Consults.audit(
          snapshot,
          [priced(:add, "Arid Mesa"), priced(:add, "Rhystic Study")],
          :upgrade
        )

      # Arid Mesa took the only slot, so Rhystic Study finds it gone. The fold
      # is the point: judged independently, both would have been told yes.
      assert note_for(audit, "Arid Mesa") =~ "exceção 1 de 1"

      assert ceiling_verdict(audit, "Rhystic Study") =~
               "R$ 373,90 passa do teto de R$ 100 e as 1 vaga(s) de exceção já estão ocupadas"
    end

    test "past the limit of expensive cards the next one is refused", %{snapshot: snapshot} do
      {:ok, _v} = Settings.put(:expensive_card_brl, 100)
      {:ok, _v} = Settings.put(:expensive_card_max, 1)

      audit =
        Consults.audit(
          snapshot,
          [priced(:add, "Arid Mesa"), priced(:add, "Rhystic Study")],
          :upgrade
        )

      assert note_for(audit, "Arid Mesa") =~ "carta cara 1 de 1"

      assert [problem] = Map.get(audit.problems, {:add, "Rhystic Study"})
      assert problem =~ "já tem 1 carta(s) acima de R$ 100"
    end

    # Cutting an expensive card and adding another has not changed the shape of
    # the deck, and an engine that only counted upwards would say it had.
    test "cutting an expensive card frees its slot in the same answer", %{snapshot: snapshot} do
      {:ok, _v} = Settings.put(:expensive_card_brl, 100)
      {:ok, _v} = Settings.put(:expensive_card_max, 1)

      in_deck = %{priced(:cut, "Arid Mesa") | name: "Arid Mesa"}
      snapshot = %{snapshot | main: snapshot.main ++ [entry_for("Arid Mesa")]}

      audit = Consults.audit(snapshot, [in_deck, priced(:add, "Rhystic Study")], :upgrade)

      refute Map.has_key?(audit.problems, {:add, "Rhystic Study"})
    end

    # The whole point of a separate land ceiling: a land gets a hard wall and
    # no exception slots, because an expensive land is the easiest way to spend
    # a lot of money and win nothing.
    test "a land is judged by the land ceiling, and cannot buy its way past it",
         %{snapshot: snapshot} do
      {:ok, _v} = Settings.put(:upgrade_land_max_brl, 100)

      audit = Consults.audit(snapshot, [priced(:add, "Arid Mesa")], :upgrade)

      assert [problem] = audit.problems[{:add, "Arid Mesa"}]
      assert problem =~ "teto de R$ 100"
    end

    # The quota is a fact about the list the owner owns, not about the question
    # he happened to ask, so it holds on a lens that has no ceilings at all.
    test "the quota holds on every lens, ceiling or not", %{snapshot: snapshot} do
      {:ok, _v} = Settings.put(:expensive_card_brl, 100)
      {:ok, _v} = Settings.put(:expensive_card_max, 1)

      audit =
        Consults.audit(
          snapshot,
          [priced(:add, "Arid Mesa"), priced(:add, "Rhystic Study")],
          :full
        )

      assert Map.has_key?(audit.problems, {:add, "Rhystic Study"})
    end

    # Refusing a card because we do not know what it costs would be inventing
    # a fact about it.
    test "a card with no known price is not refused", %{snapshot: snapshot} do
      {:ok, _v} = Settings.put(:upgrade_max_brl, 1)
      {:ok, _v} = Settings.put(:exception_card_max, 0)
      unpriced = %{priced(:add, "Rhystic Study") | price_usd: nil}

      audit = Consults.audit(snapshot, [unpriced], :upgrade)

      refute ceiling_verdict(audit, "Rhystic Study")
      assert audit.notes == %{}
    end

    defp entry_for(name), do: CardEntry.new(Cards.get_by_name(name), 1, [])
  end

  describe "the run's budget" do
    setup do
      CatalogueFixture.seed!(~w(sol_ring forest rhystic_study))

      {:ok, deck} =
        Decks.import_from_text("1 Sol Ring\n4 Forest", %{name: "Deck Orçado", source: :paste})

      snapshot =
        deck
        |> Deck.changeset(%{color_identity: ["G", "U"]})
        |> Repo.update!()
        |> Decks.snapshot()

      %{snapshot: snapshot}
    end

    # Per-card ceilings cannot answer "what is this whole round costing me".
    test "an add that crosses the total is refused, with the running total", %{snapshot: snapshot} do
      suggestion = priced(:add, "Rhystic Study")

      audit =
        Audit.run(
          snapshot,
          [suggestion],
          %{},
          Settings.baselines(),
          %{card: nil, land: nil},
          budget: 100,
          spent: Decimal.new(90)
        )

      assert [problem] = audit.problems[{:add, "Rhystic Study"}]
      assert problem =~ "orçamento da rodada"
    end

    test "with room left it passes", %{snapshot: snapshot} do
      audit =
        Audit.run(
          snapshot,
          [priced(:add, "Rhystic Study")],
          %{},
          Settings.baselines(),
          %{card: nil, land: nil},
          budget: 10_000,
          spent: Decimal.new(0)
        )

      refute audit.problems[{:add, "Rhystic Study"}]
    end

    test "no budget set refuses nothing", %{snapshot: snapshot} do
      audit = Audit.run(snapshot, [priced(:add, "Rhystic Study")], %{}, Settings.baselines())

      refute audit.problems[{:add, "Rhystic Study"}]
    end
  end

  describe "the salt contract" do
    # Identity widened to UG on the struct, not in the database: the point of
    # these tests is the salt guard, and an identity refusal would mask it.
    defp temur_snapshot, do: %{snapshot() | color_identity: ["G", "U"]}

    # The snapshot is built FIRST because building it is what seeds the
    # catalogue; a suggestion built before that resolves to no card at all.
    defp audit_with(name, opts) do
      snapshot = temur_snapshot()
      suggestion = sugg(:add, name)
      {:ok, _roles} = Cards.classify_card(suggestion.card)

      Audit.run(
        snapshot,
        [suggestion],
        Cards.roles_by_card_ids([suggestion.card.id]),
        Settings.baselines(),
        %{card: nil, land: nil},
        opts
      )
    end

    test "an add carrying a tactic the owner avoids is refused, with the reason" do
      audit = audit_with("Counterspell", avoid: %{counter: "counters"})

      assert [problem] = audit.problems[{:add, "Counterspell"}]
      assert problem =~ "evitar counters"
    end

    test "the same add passes when the owner did not avoid it" do
      audit = audit_with("Counterspell", avoid: %{})

      refute audit.problems[{:add, "Counterspell"}]
    end

    test "avoiding a tactic the card does not carry refuses nothing" do
      audit = audit_with("Counterspell", avoid: %{mill: "mill"})

      refute audit.problems[{:add, "Counterspell"}]
    end
  end
end
