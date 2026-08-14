defmodule Deckex.Analysis.Bracket do
  @moduledoc """
  Which Commander Bracket this deck is allowed to claim.

  The Commander Format Panel's five brackets are defined by **rules**, not by
  taste: a bracket permits so many Game Changers, and forbids mass land
  denial, chained extra turns and early two-card combos. Counting is what this
  engine does, so counting is what it does here.

  It reports a **floor**, never a verdict. Two of the five criteria — whether a
  two-card combo exists, and whether the deck actually closes before the
  bracket's turn expectation — need knowledge of the card pool, which belongs
  to the model. Naming a bracket we cannot prove would be the same overreach
  as inventing a price.

      floor 1  0 Game Changers, no mass land denial, no chained extra turns
      floor 3  1–3 Game Changers
      floor 4  4+ Game Changers, or mass land denial, or chained extra turns

  There is no floor 2 or 5: brackets 1 and 2 share their deckbuilding rules
  (they differ in theme and expected turn count, neither of which is on the
  decklist), and bracket 5 is bracket 4's rules with a cEDH metagame around
  them, which no decklist can prove either.
  """

  alias Deckex.Analysis.CardEntry
  alias Deckex.Analysis.DeckSnapshot

  @type t :: %__MODULE__{
          floor: 1 | 3 | 4,
          game_changers: [CardEntry.t()],
          mass_land_denial: [CardEntry.t()],
          extra_turns: [CardEntry.t()],
          reasons: [String.t()],
          open_questions: [String.t()]
        }

  # A consult freezes the whole report as JSON, so the bracket travels with it.
  @derive Jason.Encoder
  defstruct floor: 1,
            game_changers: [],
            mass_land_denial: [],
            extra_turns: [],
            reasons: [],
            open_questions: []

  @doc "The lowest bracket whose deckbuilding rules `snapshot` provably satisfies."
  @spec floor(DeckSnapshot.t()) :: t()
  def floor(%DeckSnapshot{} = snapshot) do
    considered = snapshot.commanders ++ snapshot.main
    changers = Enum.filter(considered, & &1.card.game_changer)
    denial = Enum.filter(considered, &CardEntry.has_role?(&1, :mass_land_denial))
    turns = Enum.filter(considered, &CardEntry.has_role?(&1, :extra_turn))

    %__MODULE__{
      floor: floor_for(length(changers), denial, turns),
      game_changers: changers,
      mass_land_denial: denial,
      extra_turns: turns,
      reasons: reasons(changers, denial, turns),
      open_questions: open_questions()
    }
  end

  @doc "The pt-BR name of a bracket."
  @spec name(1..5) :: String.t()
  def name(1), do: "Exhibition"
  def name(2), do: "Core"
  def name(3), do: "Upgraded"
  def name(4), do: "Optimized"
  def name(5), do: "cEDH"

  @doc "How many turns a bracket expects a game to last, as a sentence."
  @spec turn_expectation(1..5) :: String.t()
  def turn_expectation(1), do: "pelo menos 9 turnos"
  def turn_expectation(2), do: "pelo menos 8 turnos"
  def turn_expectation(3), do: "pelo menos 6 turnos"
  def turn_expectation(4), do: "pelo menos 4 turnos"
  def turn_expectation(5), do: "pode acabar em qualquer turno"

  @doc """
  How much room is left before the deck leaves bracket 3, or nil when the
  question no longer applies.

  Three Game Changers is the ceiling of bracket 3, and it is a ceiling people
  walk into by accident: a single suggested card can be the fourth.
  """
  @spec game_changer_headroom(t()) :: non_neg_integer() | nil
  def game_changer_headroom(%__MODULE__{floor: 4}), do: nil
  def game_changer_headroom(%__MODULE__{game_changers: changers}), do: 3 - length(changers)

  defp floor_for(count, denial, turns) do
    cond do
      count >= 4 or denial != [] or turns != [] -> 4
      count >= 1 -> 3
      true -> 1
    end
  end

  defp reasons(changers, denial, turns) do
    [
      changer_reason(length(changers)),
      list_reason(denial, "negação de terreno em massa"),
      list_reason(turns, "turno extra encadeável")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp changer_reason(0), do: "Nenhum Game Changer."
  defp changer_reason(1), do: "1 Game Changer — o teto do Bracket 3 é 3."

  defp changer_reason(count) when count <= 3 do
    "#{count} Game Changers — o teto do Bracket 3 é 3."
  end

  defp changer_reason(count), do: "#{count} Game Changers, acima do teto de 3 do Bracket 3."

  defp list_reason([], _label), do: nil

  defp list_reason(entries, label) do
    "#{length(entries)} carta(s) de #{label}: #{DeckSnapshot.names(entries) |> Enum.join(", ")}."
  end

  # The engine cannot answer these from a decklist. They are printed as
  # questions so the gap is visible rather than quietly filled in.
  defp open_questions do
    [
      "Tem combo de duas cartas que ganha na hora? Onde tem, o Bracket 3 só aceita se não montar antes do turno 6.",
      "O deck fecha o jogo antes do turno que o bracket espera?"
    ]
  end
end
