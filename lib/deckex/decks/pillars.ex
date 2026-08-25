defmodule Deckex.Decks.Pillars do
  @moduledoc """
  Which cards this deck cannot lose, proposed from what the app already knows.
  Pure: a deck's cards, its dossier and its notes in, proposals out.

  Locking cards one at a time is work, and work nobody does is protection
  nobody has. But most of the answer is already written down: the scout wrote a
  dossier naming the interactions that give this deck its identity and the
  cards that close a game, and the owner wrote notes during past reviews about
  cards a stage read wrong. A card named in either is a card somebody already
  decided mattered — it just never became a rule.

  So this proposes rather than decides, and every proposal carries the sentence
  that produced it. A list of card names with no evidence is a list nobody can
  check, and the whole point of the Cartas screen is that the owner is the one
  who decides.

  What it deliberately cannot find: a combo nobody has written about yet. Two
  cards that are unremarkable apart and lethal together leave no trace in prose
  until someone notices them, and noticing is what the `:pilares` consult is
  for. This is the free half.
  """

  alias Deckex.Cards.Card
  alias Deckex.Cards.Name
  alias Deckex.Decks.CardNote

  # Short names collide with ordinary words, and a false proposal costs more
  # attention than a missing one — he is reading these to approve them.
  @min_name_length 4

  @type source :: :ia | :dossier | :review
  @type proposal :: %{
          name: String.t(),
          reason: String.t(),
          source: source(),
          stance: CardNote.stance()
        }

  @doc """
  Cards worth locking, with the sentence behind each.

  `cards` is the deck's cards; `dossier` its written plan, or nil; `notes` the
  rules it already carries; `ai_rows` a `:pilares` consult's answer, or nothing.

  A card already carrying a stance is never re-proposed from prose — the app
  arguing with a decision he already made is worse than a gap. The model's own
  reading is allowed through anyway, because "you left this as an observation
  and here is why it is load-bearing" is an argument worth reading once.

  Ordered by how much each source knows: the model read the cards, the dossier
  described the deck, a review note is one card the owner already explained.
  """
  @spec propose([%{card: Card.t(), board: atom()}], map() | nil, [CardNote.t()], [map()]) ::
          [proposal()]
  def propose(cards, dossier, notes, ai_rows \\ []) do
    stances = Map.new(notes, &{&1.card_name, &1.stance})

    (from_ai(cards, ai_rows) ++ from_dossier(cards, dossier) ++ from_reviews(notes))
    |> Enum.reject(&settled?(Map.get(stances, &1.name), &1.stance))
    |> Enum.uniq_by(& &1.name)
  end

  # A proposal has to say something the deck's rules do not already say.
  # Proposing "make this an observation" about a card that is already an
  # observation is how nineteen rows of nothing ended up on the screen, each
  # carrying the same sentence as the row it duplicated.
  #
  # The one case worth reopening is upward: "you left this as an observation,
  # and here is why it is actually load-bearing" is an argument, and the model
  # is allowed to make it once.
  defp settled?(nil, _proposed), do: false
  defp settled?(:note, :locked), do: false
  defp settled?(_already_decided, _proposed), do: true

  # A model naming a card the deck does not hold is proposing an add, and this
  # screen does not add cards. Resolved through the normalizer so a spelling
  # that differs from the catalogue's still lands on the right card, and the
  # name stored is the deck's, never the model's.
  defp from_ai(_cards, rows) when rows in [nil, []], do: []

  defp from_ai(cards, rows) do
    by_key = Map.new(candidates(cards), &{Name.normalize(&1.name), &1.name})

    for %{"carta" => written} = row <- rows,
        name = Map.get(by_key, Name.normalize(written)),
        name != nil,
        do: %{name: name, reason: row["motivo"] || "", source: :ia, stance: :locked}
  end

  # The commander is protected by the engine already, and basic lands are not
  # anybody's pillar — proposing either is noise in a list read for approval.
  defp candidates(cards) do
    cards
    |> Enum.reject(&(&1.board == :commander or Card.basic_land?(&1.card)))
    |> Enum.map(& &1.card)
    |> Enum.filter(&(String.length(front_face(&1.name)) >= @min_name_length))
  end

  # `plano` and `fraquezas` are excluded on purpose. The plan names cards as
  # examples and the weaknesses name them as problems; only the synergies and
  # the win lines name a card because the deck needs it.
  defp from_dossier(_cards, nil), do: []

  defp from_dossier(cards, dossier) do
    prose =
      ["sinergias", "linhas_de_vitoria"]
      |> Enum.map(&Map.get(dossier, &1))
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" ")

    found =
      for card <- candidates(cards),
          sentence = mentioning_sentence(prose, front_face(card.name)),
          sentence != nil,
          do: %{name: card.name, reason: sentence, source: :dossier}

    crowd = Enum.frequencies_by(found, & &1.reason)

    Enum.map(found, &Map.put(&1, :stance, dossier_stance(crowd[&1.reason])))
  end

  # **One sentence naming eight cards is an observation about the deck, not
  # eight orders.** This is the correction to the first version of this sweep,
  # and the owner paid for the lesson: a dossier's synergy paragraph lists the
  # cards in a package, the sweep turned every one of them into an untouchable,
  # and three real decks came out with 22%, 29% and 32% of their cuttable cards
  # locked. A pipeline that cannot cut a third of the deck cannot improve it —
  # which is exactly what the `:pilares` briefing warns the model against, while
  # the free sweep was doing it by default.
  #
  # A sentence written about one card is a different claim, and keeps its order.
  defp dossier_stance(1), do: :locked
  defp dossier_stance(_several_cards_in_one_sentence), do: :note

  # A note a review left behind cost the owner a run to notice and a review to
  # write. He explained the card once; the only thing missing was the order.
  defp from_reviews(notes) do
    for %CardNote{stance: :note, source: :review, note: note} = row <- notes,
        is_binary(note),
        do: %{name: row.card_name, reason: note, source: :review, stance: :locked}
  end

  defp front_face(name), do: name |> String.split("//") |> hd() |> String.trim()

  # The sentence, not just the fact of the mention: he is approving these, and
  # "Prize Pig" on its own tells him nothing he did not already know.
  defp mentioning_sentence(prose, name) do
    needle = String.downcase(name)

    prose
    |> String.split(~r/(?<=[.!?])\s+/)
    |> Enum.find(&String.contains?(String.downcase(&1), needle))
    |> trim_sentence()
  end

  defp trim_sentence(nil), do: nil

  defp trim_sentence(sentence) do
    case String.trim(sentence) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
