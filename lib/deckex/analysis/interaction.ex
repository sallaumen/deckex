defmodule Deckex.Analysis.Interaction do
  @moduledoc """
  What the deck can do about an opponent.

  **Counterspells are counted but excluded from `:answers`.** A counterspell is
  a dead card once the threat has resolved; against an aggressive deck only spot
  removal and sweepers actually address a board. Summing the two into a single
  "interaction" figure hides exactly the failure this lens exists to surface.
  """

  alias Deckex.Analysis.Baselines
  alias Deckex.Analysis.CardEntry
  alias Deckex.Analysis.DeckSnapshot
  alias Deckex.Analysis.Finding

  @answer_roles [:spot_removal, :board_wipe]
  @all_roles [:counter, :spot_removal, :board_wipe, :protection, :graveyard_hate]

  @spec measure(DeckSnapshot.t()) :: map()
  def measure(snapshot) do
    nonlands = DeckSnapshot.nonlands(snapshot)
    interactive = Enum.filter(nonlands, &interactive?/1)

    %{
      counters: count_role(nonlands, :counter),
      spot_removal: count_role(nonlands, :spot_removal),
      board_wipes: count_role(nonlands, :board_wipe),
      protection: count_role(nonlands, :protection),
      graveyard_hate: count_role(nonlands, :graveyard_hate),
      answers: nonlands |> Enum.filter(&answer?/1) |> DeckSnapshot.count(),
      instant_speed: interactive |> Enum.filter(&CardEntry.instant?/1) |> DeckSnapshot.count(),
      sorcery_speed: interactive |> Enum.reject(&CardEntry.instant?/1) |> DeckSnapshot.count()
    }
  end

  @spec findings(DeckSnapshot.t(), Baselines.t()) :: [Finding.t()]
  def findings(snapshot, baselines) do
    measured = measure(snapshot)
    nonlands = DeckSnapshot.nonlands(snapshot)

    Enum.concat([
      total_low(measured, nonlands, baselines),
      total_high(measured, nonlands, baselines),
      board_wipes(measured, nonlands, baselines),
      sorcery_heavy(measured, baselines),
      no_protection(measured)
    ])
  end

  defp total_low(%{counters: counters, answers: answers}, nonlands, b)
       when counters + answers < b.interaction_floor do
    [
      Finding.new(
        "interaction.total_low",
        :critical,
        :interaction,
        "Interação insuficiente",
        "#{counters + answers} peças de interação (alvo: #{b.interaction_target}). " <>
          "Desse total, #{answers} respondem a algo que já resolveu — " <>
          "contra-magia não desfaz dano.",
        evidence: %{
          total: counters + answers,
          answers: answers,
          counters: counters,
          target: b.interaction_target
        },
        card_names: nonlands |> Enum.filter(&interactive?/1) |> DeckSnapshot.names()
      )
    ]
  end

  defp total_low(_measured, _nonlands, _baselines), do: []

  # The band's ceiling. No source argues more interaction is always better, and
  # the failure at the top end is documented: a table where nobody can keep a
  # permanent is a table where nobody gets to play. It is the same complaint
  # people make about stax, arrived at from the other direction.
  defp total_high(%{counters: counters, answers: answers}, nonlands, b)
       when counters + answers > b.interaction_max do
    [
      Finding.new(
        "interaction.too_much",
        :warning,
        :interaction,
        "Interação demais para a mesa respirar",
        "#{counters + answers} peças de interação (a faixa vai até #{b.interaction_max}). " <>
          "Passando disso o deck deixa de ter plano próprio e passa a impedir o dos outros " <>
          "— é a reclamação que se faz de stax, chegando pelo outro lado.",
        evidence: %{total: counters + answers, max: b.interaction_max},
        card_names: nonlands |> Enum.filter(&interactive?/1) |> DeckSnapshot.names()
      )
    ]
  end

  defp total_high(_measured, _nonlands, _baselines), do: []

  defp board_wipes(%{board_wipes: 0}, _nonlands, _baselines) do
    [
      Finding.new(
        "interaction.no_board_wipes",
        :critical,
        :interaction,
        "Nenhuma varredura",
        "O deck não tem como resetar um campo que fugiu do controle.",
        evidence: %{board_wipes: 0}
      )
    ]
  end

  defp board_wipes(%{board_wipes: wipes}, nonlands, b) when wipes < b.board_wipe_target do
    [
      Finding.new(
        "interaction.board_wipes_low",
        :warning,
        :interaction,
        "Só #{wipes} varredura",
        "Contra deck agressivo, uma varredura só precisa ser a certa na hora certa. " <>
          "O alvo é #{b.board_wipe_target}.",
        evidence: %{board_wipes: wipes, target: b.board_wipe_target},
        card_names: nonlands |> DeckSnapshot.with_role(:board_wipe) |> DeckSnapshot.names()
      )
    ]
  end

  defp board_wipes(_measured, _nonlands, _baselines), do: []

  defp sorcery_heavy(%{instant_speed: fast, sorcery_speed: slow}, b)
       when slow > fast and slow + fast >= b.interaction_floor do
    [
      Finding.new(
        "interaction.sorcery_speed_heavy",
        :warning,
        :interaction,
        "Interação lenta demais",
        "#{slow} peças em sorcery contra #{fast} em instant. " <>
          "Responder só no seu turno entrega o tempo pro oponente.",
        evidence: %{sorcery: slow, instant: fast}
      )
    ]
  end

  defp sorcery_heavy(_measured, _baselines), do: []

  defp no_protection(%{protection: 0}) do
    [
      Finding.new(
        "interaction.no_protection",
        :warning,
        :interaction,
        "Nada protege o comandante",
        "Sem proteção, cada remoção do oponente custa um recomprar do comandante.",
        evidence: %{protection: 0}
      )
    ]
  end

  defp no_protection(_measured), do: []

  defp count_role(entries, role) do
    entries |> DeckSnapshot.with_role(role) |> DeckSnapshot.count()
  end

  defp answer?(entry), do: Enum.any?(@answer_roles, &CardEntry.has_role?(entry, &1))
  defp interactive?(entry), do: Enum.any?(@all_roles, &CardEntry.has_role?(entry, &1))
end
