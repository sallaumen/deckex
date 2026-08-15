defmodule Deckex.Analysis.Mesa do
  @moduledoc """
  How much of other people's game this deck spends, and whether it is built for
  the speed its table actually plays at.

  The research on what ruins a Commander game is unusually consistent, and it
  does not point at power: it points at **table time somebody else does not get
  to play**. Extra turns, untap denial, taxing statics and forced sacrifice all
  take the same thing from the other three players, and no lens here measured
  any of it.

  This counts and names. It does not score — a number out of ten would be the
  power level this project exists to not build.

  The second half is the table's own clock. `table_close_turn` is not a
  universal truth, it is a fact about the owner's pod: games that end on turn
  seven punish a deck that does nothing until turn five, and the same deck is
  fine where games run to twelve. The engine cannot measure someone else's
  table, so the owner states it and every lens gets to use it.
  """

  alias Deckex.Analysis.Baselines
  alias Deckex.Analysis.DeckSnapshot
  alias Deckex.Analysis.Finding

  # Each of these takes turns, actions or untap steps away from the other
  # players. `theft` is here because spending your turn playing someone else's
  # permanents is time they are not playing them.
  @costly_roles [:extra_turn, :stax, :taxation, :hoser, :forced_sacrifice, :theft]

  @doc "What this deck takes from the rest of the table."
  @spec measure(DeckSnapshot.t()) :: map()
  def measure(%DeckSnapshot{} = snapshot) do
    nonlands = DeckSnapshot.nonlands(snapshot)

    by_role =
      Map.new(@costly_roles, fn role ->
        {role, nonlands |> DeckSnapshot.with_role(role) |> length()}
      end)

    cards =
      @costly_roles
      |> Enum.flat_map(&DeckSnapshot.with_role(nonlands, &1))
      |> DeckSnapshot.names()
      |> Enum.uniq()

    %{table_time: length(cards), by_role: by_role, cards: cards}
  end

  @spec findings(DeckSnapshot.t(), Baselines.t()) :: [Finding.t()]
  def findings(%DeckSnapshot{} = snapshot, %Baselines{} = baselines) do
    %{table_time: count, cards: cards} = measure(snapshot)

    if count > baselines.table_time_max do
      [
        Finding.new(
          "mesa.table_time_high",
          :warning,
          :mesa,
          "O deck toma tempo dos outros jogadores",
          "#{count} cartas tiram turnos, ações ou destravamento da mesa (alvo: até " <>
            "#{baselines.table_time_max}). Não é sobre poder — é sobre quanto tempo as " <>
            "outras pessoas passam sem jogar.",
          evidence: %{table_time: count, target: baselines.table_time_max},
          card_names: cards
        )
      ]
    else
      []
    end
  end
end
