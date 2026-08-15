defmodule Deckex.Analysis.Fragility do
  @moduledoc """
  Where this deck dies.

  Every other lens asks whether the deck works. This one asks how it loses,
  which is a different question and the one a player actually feels. Three
  fault lines, each countable from data the catalogue already holds:

  **Varredura.** How much of the deck is standing on the battlefield when a
  board wipe resolves — and, crucially, whether its *mana* is standing there
  too. A deck whose ramp lives on creatures does not merely lose its board to a
  wipe, it loses the ability to rebuild. That is also why "run more wipes" is
  the wrong fix for such a deck and the finding says so: a symmetric sweeper
  kills the engine along with the threat. Asymmetric ones are the answer.

  **Cemitério.** Cards whose function needs the graveyard. A deck that treats
  the yard as a second hand hands one card — any exile effect — the power to
  end it.

  **Defesa.** Whether anything is *available* to block. Toughness is the first
  filter — a board of 1/1 tokens is not a defence — but the one that matters is
  the second: a creature that carries the deck's engine is not a blocker, because
  trading your mana or your win condition for four damage costs more than the
  damage. The reference deck holds eight creatures with real toughness and can
  defend with two of them, which is exactly what its owner reports feeling.
  This is the quietest way a Commander deck loses: not out-powered, just
  attacked while everything on the table is too valuable to block with.

  The lens diagnoses and names. What to do about it is the consults' job — they
  already read findings, and they are better at proposing cards than a regex.
  """

  alias Deckex.Analysis.Baselines
  alias Deckex.Analysis.CardEntry
  alias Deckex.Analysis.DeckSnapshot
  alias Deckex.Analysis.Finding

  @graveyard ~r/graveyard|flashback|escape|delve|disturb/i

  @doc "The three exposures, each with the cards behind it."
  @spec measure(DeckSnapshot.t()) :: map()
  def measure(%DeckSnapshot{} = snapshot) do
    %{
      board: board_exposure(snapshot),
      graveyard: graveyard_exposure(snapshot),
      defence: defence(snapshot)
    }
  end

  @spec findings(DeckSnapshot.t(), Baselines.t()) :: [Finding.t()]
  def findings(%DeckSnapshot{} = snapshot, %Baselines{} = baselines) do
    measured = measure(snapshot)

    Enum.reject(
      [
        board_finding(measured.board, snapshot, baselines),
        graveyard_finding(measured.graveyard, baselines),
        defence_finding(measured.defence, baselines)
      ],
      &is_nil/1
    )
  end

  # ── varredura ─────────────────────────────────────────────────────────────

  defp board_exposure(snapshot) do
    creatures = snapshot |> DeckSnapshot.nonlands() |> Enum.filter(&creature?/1)
    mana_creatures = Enum.filter(creatures, &(CardEntry.has_role?(&1, :ramp) or ritual?(&1)))

    %{
      creatures: length(creatures),
      mana_on_creatures: length(mana_creatures),
      mana_cards: DeckSnapshot.names(mana_creatures)
    }
  end

  defp board_finding(
         %{creatures: creatures, mana_on_creatures: on_creatures} = board,
         snapshot,
         b
       ) do
    wipes = snapshot |> DeckSnapshot.nonlands() |> DeckSnapshot.with_role(:board_wipe) |> length()

    if creatures >= b.board_exposure_floor and on_creatures > 0 do
      Finding.new(
        "fragility.board_wipe",
        :warning,
        :fragility,
        "Uma varredura desmonta o deck inteiro",
        "#{creatures} criaturas, e #{on_creatures} delas são a sua mana. Uma varredura " <>
          "simétrica não tira só o campo — tira a mana para reconstruir, e o deck tem " <>
          "#{wipes} varredura(s) própria(s). Mais varredura simétrica piora isso; o que " <>
          "resolve é remoção assimétrica e corpos que sobrevivem.",
        evidence: %{creatures: creatures, mana_on_creatures: on_creatures, board_wipes: wipes},
        card_names: board.mana_cards
      )
    end
  end

  # ── cemitério ─────────────────────────────────────────────────────────────

  defp graveyard_exposure(snapshot) do
    dependent =
      snapshot
      |> DeckSnapshot.nonlands()
      |> Enum.filter(fn entry ->
        CardEntry.has_role?(entry, :recursion) or to_string(entry.card.oracle_text) =~ @graveyard
      end)

    %{count: length(dependent), cards: DeckSnapshot.names(dependent)}
  end

  defp graveyard_finding(%{count: count, cards: cards}, b) do
    if count >= b.graveyard_exposure_floor do
      Finding.new(
        "fragility.graveyard_hate",
        :warning,
        :fragility,
        "O cemitério é a sua segunda mão, e ela é frágil",
        "#{count} cartas precisam do cemitério para funcionar. Um único efeito de exílio " <>
          "na mesa — e eles são comuns — apaga essa parte do deck de uma vez.",
        evidence: %{dependent: count},
        card_names: cards
      )
    end
  end

  # ── defesa ────────────────────────────────────────────────────────────────

  # A creature that IS the deck cannot also be its defence. You do not block
  # with your mana, your draw engine or your win condition — trading them costs
  # more than the damage does, so the body is not available and counting it
  # lies. This is why a deck can hold eight creatures with real toughness and
  # still have nothing to stand in front of an attack.
  @engine_roles [:ramp, :ritual, :fixing, :draw, :cost_reduction, :wincon, :recursion, :tutor]

  defp defence(snapshot) do
    nonlands = DeckSnapshot.nonlands(snapshot)
    bodies = Enum.filter(nonlands, &(creature?(&1) and blocks?(&1)))
    {engine, free} = Enum.split_with(bodies, &engine?/1)
    deterrents = DeckSnapshot.with_role(nonlands, :protection)

    %{
      blockers: length(free),
      blocker_cards: DeckSnapshot.names(free),
      engine_bodies: length(engine),
      engine_cards: DeckSnapshot.names(engine),
      deterrents: length(deterrents)
    }
  end

  defp engine?(entry), do: Enum.any?(@engine_roles, &CardEntry.has_role?(entry, &1))

  defp defence_finding(%{blockers: blockers, engine_bodies: engine} = defence, b) do
    if blockers < b.blockers_target do
      Finding.new(
        "fragility.no_defence",
        :critical,
        :fragility,
        "Nada segura um ataque",
        "Só #{blockers} corpo(s) livre(s) com resistência 3 ou mais (alvo: " <>
          "#{b.blockers_target}). Outras #{engine} criaturas têm resistência para bloquear " <>
          "mas são o motor do deck — trocá-las custa mais que o dano. Com #{defence.deterrents} " <>
          "peça(s) de proteção, você não escolhe quando morre, e o comandante vira o alvo " <>
          "óbvio da mesa.",
        evidence: %{
          blockers: blockers,
          target: b.blockers_target,
          engine_bodies: engine,
          deterrents: defence.deterrents
        },
        card_names: defence.blocker_cards ++ defence.engine_cards
      )
    end
  end

  # ── the small predicates ──────────────────────────────────────────────────

  defp creature?(%CardEntry{card: card}) do
    card.type_line |> to_string() |> String.split("//") |> hd() |> String.contains?("Creature")
  end

  defp ritual?(entry), do: CardEntry.has_role?(entry, :ritual)

  # A body that survives the attack it is blocking. "*" and other printed
  # non-numbers count as no defence rather than as a guess.
  defp blocks?(%CardEntry{card: card}) do
    case Integer.parse(to_string(card.toughness)) do
      {toughness, _rest} -> toughness >= 3
      :error -> false
    end
  end
end
