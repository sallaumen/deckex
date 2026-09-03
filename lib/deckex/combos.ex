defmodule Deckex.Combos do
  @moduledoc """
  What this deck's cards do *together*, from Commander Spellbook.

  Every measurement in this app reads one card at a time. That is why a stage
  cut Sam, Loyal Attendant: alone she is a 2/4 nobody plays, and the line she
  makes with Prize Pig lives in neither card's text, neither card's rank, nor
  any count the engine takes. A combo database is the one source that answers
  "what do these two do together" as a fact rather than an inference.

  Two halves, and the second is the one an optimization wants:

    * **assembled** — the deck already has every piece. These are lines the
      owner may not know he owns, and cards a round must not casually cut.
    * **one card away** — every piece but one. Each of these is a single named
      card that turns a pile into a line, which is a better answer to "what
      should this deck add" than any amount of generic card quality.

  Refreshed in the background, never during a render, and the failure mode is
  keeping what was already there: a combo list from yesterday describes the
  deck better than an empty one.
  """

  require Logger

  alias Deckex.Cards.Name
  alias Deckex.Decks
  alias Deckex.Decks.Deck
  alias Deckex.Error
  alias Deckex.Events
  alias Deckex.Repo
  alias Deckex.Spellbook

  @empty %{"assembled" => [], "one_card_away" => []}

  @doc """
  Asks Commander Spellbook what this list does, and stores the answer.

  One request per call. On failure the deck keeps the combos it already had and
  stays flagged stale, so the next attempt tries again rather than the app
  pretending the deck has none.
  """
  @spec refresh(Deck.t()) :: {:ok, Deck.t()} | {:error, Error.t()}
  def refresh(%Deck{} = deck) do
    snapshot = Decks.snapshot(deck)
    main = Enum.map(snapshot.main, & &1.card.name)
    commanders = Enum.map(snapshot.commanders, & &1.card.name)
    present = MapSet.new(main ++ commanders, &Name.normalize/1)

    with {:ok, answer} <- Spellbook.find_combos(main, commanders) do
      combos = build(answer, present)

      Logger.info(
        "combos: #{length(combos["assembled"] || [])} montados, " <>
          "#{length(combos["one_card_away"] || [])} a uma carta"
      )

      {:ok, store(deck, combos)}
    end
  end

  @doc "The combos on a deck, always shaped, never nil."
  @spec for_deck(Deck.t()) :: %{String.t() => [map()]}
  def for_deck(%Deck{combos: nil}), do: @empty
  def for_deck(%Deck{combos: combos}), do: Map.merge(@empty, combos)

  @doc "Whether this deck has ever been asked about."
  @spec asked?(Deck.t()) :: boolean()
  def asked?(%Deck{combos_updated_at: at}), do: not is_nil(at)

  @doc """
  Marks a deck's combos as no longer describing its list.

  Called wherever the dossier is marked stale, and for the same reason: a list
  that changed has combos about a list that no longer exists.
  """
  @spec mark_stale(Deck.t()) :: :ok
  def mark_stale(%Deck{combos: nil}), do: :ok

  def mark_stale(%Deck{combos_stale: true}), do: :ok

  def mark_stale(%Deck{} = deck) do
    deck |> Deck.changeset(%{combos_stale: true}) |> Repo.update!()

    :ok
  end

  defp build(%{included: included, almost: almost}, present) do
    shown = one_card_away(almost, present)

    %{
      "assembled" => Enum.map(included, &Spellbook.summarise/1),
      "one_card_away" => shown,
      # What the cap hid. An app that trims a list and does not say so has told
      # the reader there were twenty when there were ninety.
      "one_card_away_total" => length(almost)
    }
  end

  # Probed against the owner's own deck: twelve cards produced twenty-four
  # almost-combos, several of them the same missing card twice. A hundred-card
  # list produces enough to drown the prompt it is meant to sharpen.
  #
  # So one line per **card to add**, which is the unit he acts in — he buys a
  # card, not a combo — keeping the line that produces the most, and capped.
  # The total is carried alongside so nothing is dropped silently.
  @shown 20

  defp one_card_away(almost, present) do
    found =
      almost
      |> Enum.map(&Spellbook.summarise/1)
      |> Enum.flat_map(fn combo ->
        case Spellbook.missing_piece(combo, present) do
          nil -> []
          card -> [Map.put(combo, "missing", card)]
        end
      end)
      |> Enum.sort_by(&length(&1["produces"]), :desc)
      |> Enum.uniq_by(& &1["missing"])

    Enum.take(found, @shown)
  end

  defp store(deck, combos) do
    saved =
      deck
      |> Deck.changeset(%{
        combos: combos,
        combos_stale: false,
        combos_updated_at: DateTime.utc_now(:second)
      })
      |> Repo.update!()

    Events.broadcast_deck_updated(saved)

    saved
  end
end
