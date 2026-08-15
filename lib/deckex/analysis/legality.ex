defmodule Deckex.Analysis.Legality do
  @moduledoc """
  Whether this deck is a legal Commander deck at all.

  Every other lens asks how good the deck is. This one asks whether you can put
  it on the table, and it was missing: the audit checks colour identity, the
  singleton rule, Commander legality and deck size on every card an **AI**
  suggests, and nothing ever checked the same things about the deck the owner
  actually imported. A list pasted with 103 cards, or with a card outside the
  commander's identity, was measured and reported on as if it were fine.

  Four rules, all countable, none of them opinions:

  - **Exactly 100 cards**, commanders included. Found on a real deck the day
    this shipped, sitting at 103.
  - **Inside the commander's colour identity.** A card outside it is not merely
    bad, it is illegal — the same sentence the briefing has told models since
    the beginning.
  - **Singleton**, except basic lands and the cards whose own text lifts the
    rule. Asked of the card, never of a list of names.
  - **Commander-legal**, as Scryfall reports it. Banned lists are revised; a
    list written down here would be wrong within months.

  A deck with no commander declared has no colour identity to check against, so
  the identity rule stays quiet rather than calling every card illegal. Pasting
  a list without its commander block is a common import, not a broken deck.
  """

  alias Deckex.Analysis.Baselines
  alias Deckex.Analysis.CardEntry
  alias Deckex.Analysis.DeckSnapshot
  alias Deckex.Analysis.Finding
  alias Deckex.Cards.Card

  @deck_size 100

  @doc "The four counts behind the findings."
  @spec measure(DeckSnapshot.t()) :: map()
  def measure(%DeckSnapshot{} = snapshot) do
    %{
      size: size(snapshot),
      target_size: @deck_size,
      outside_identity: DeckSnapshot.names(outside_identity(snapshot)),
      duplicated: DeckSnapshot.names(duplicated(snapshot)),
      banned: DeckSnapshot.names(banned(snapshot))
    }
  end

  @spec findings(DeckSnapshot.t(), Baselines.t()) :: [Finding.t()]
  def findings(%DeckSnapshot{} = snapshot, %Baselines{} = _baselines) do
    measured = measure(snapshot)

    Enum.reject(
      [
        size_finding(measured),
        identity_finding(measured, snapshot),
        singleton_finding(measured),
        banned_finding(measured)
      ],
      &is_nil/1
    )
  end

  defp size(%DeckSnapshot{main: main, commanders: commanders}) do
    Enum.sum(Enum.map(main ++ commanders, & &1.quantity))
  end

  defp size_finding(%{size: @deck_size}), do: nil

  defp size_finding(%{size: size}) do
    {direction, gap} =
      if size > @deck_size,
        do: {"a mais", size - @deck_size},
        else: {"a menos", @deck_size - size}

    Finding.new(
      "legality.deck_size",
      :critical,
      :legality,
      "O deck não tem 100 cartas",
      "#{size} cartas contando o comandante — #{gap} #{direction}. Commander exige exatamente " <>
        "100, então esta lista não pode ir para a mesa como está.",
      evidence: %{size: size, target: @deck_size}
    )
  end

  # No commander, no identity to judge against. Pasting a list without its
  # commander block is a common import, not a deck full of illegal cards.
  defp outside_identity(%DeckSnapshot{commanders: []}), do: []

  defp outside_identity(%DeckSnapshot{main: main, color_identity: identity}) do
    Enum.filter(main, fn %CardEntry{card: card} -> card.color_identity -- identity != [] end)
  end

  defp identity_finding(%{outside_identity: []}, _snapshot), do: nil

  defp identity_finding(%{outside_identity: names}, snapshot) do
    Finding.new(
      "legality.outside_identity",
      :critical,
      :legality,
      "Cartas fora da identidade de cor",
      "#{length(names)} carta(s) usam cor que #{commander_name(snapshot)} não tem " <>
        "(#{identity_label(snapshot.color_identity)}). Fora da identidade não é ruim, é ilegal.",
      evidence: %{outside: length(names), identity: snapshot.color_identity},
      card_names: names
    )
  end

  defp commander_name(%DeckSnapshot{commanders: [%CardEntry{card: card} | _rest]}), do: card.name
  defp commander_name(_none), do: "o comandante"

  defp identity_label([]), do: "incolor"
  defp identity_label(identity), do: Enum.join(identity, "")

  defp duplicated(%DeckSnapshot{main: main}) do
    Enum.filter(main, fn %CardEntry{card: card, quantity: quantity} ->
      quantity > 1 and not Card.basic_land?(card) and not Card.any_number_allowed?(card)
    end)
  end

  defp singleton_finding(%{duplicated: []}), do: nil

  defp singleton_finding(%{duplicated: names}) do
    Finding.new(
      "legality.singleton",
      :critical,
      :legality,
      "Cópias repetidas de carta singleton",
      "#{length(names)} carta(s) aparecem mais de uma vez. Commander só aceita uma cópia, fora " <>
        "terrenos básicos e as cartas cujo próprio texto libera a regra.",
      evidence: %{duplicated: length(names)},
      card_names: names
    )
  end

  defp banned(%DeckSnapshot{main: main, commanders: commanders}) do
    Enum.reject(main ++ commanders, & &1.card.commander_legal)
  end

  defp banned_finding(%{banned: []}), do: nil

  defp banned_finding(%{banned: names}) do
    Finding.new(
      "legality.not_legal",
      :critical,
      :legality,
      "Cartas que não são legais em Commander",
      "#{length(names)} carta(s) estão marcadas como não-legais pela Scryfall. A lista de " <>
        "banidas muda; esta leitura vem do dado da carta, não de uma lista escrita aqui.",
      evidence: %{banned: length(names)},
      card_names: names
    )
  end
end
