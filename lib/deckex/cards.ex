defmodule Deckex.Cards do
  @moduledoc """
  The card catalogue: the local, permanent cache of Scryfall card data.

  `resolve_names/1` is the entry point every import uses. Cards already known
  are read from Postgres; only genuinely new ones cost a Scryfall request. Since
  a card is immutable and the catalogue is global, the cost of importing decks
  falls towards zero as the collection grows.
  """

  alias Deckex.Cards.Card
  alias Deckex.Cards.CardQuery
  alias Deckex.Cards.CardRole
  alias Deckex.Cards.Name
  alias Deckex.Cards.RoleAI
  alias Deckex.Cards.RoleMatch
  alias Deckex.Cards.Roles
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.Error
  alias Deckex.Repo
  alias Deckex.Scryfall

  defdelegate get_by_name(name), to: CardQuery
  defdelegate list_by_normalized_names(names), to: CardQuery
  defdelegate list_by_ids(ids), to: CardQuery
  defdelegate roles_for(card), to: CardQuery, as: :list_roles
  defdelegate roles_by_card_ids(ids), to: CardQuery

  @doc """
  Resolves card names to `Card` structs, fetching and caching whatever is
  missing.

  Returns the resolved cards plus the names Scryfall could not resolve — those
  are reported to the user by name, never silently dropped.
  """
  @spec resolve_names([String.t()]) ::
          {:ok, %{cards: [Card.t()], not_found: [String.t()]}} | {:error, Error.t()}
  def resolve_names([]), do: {:ok, %{cards: [], not_found: []}}

  def resolve_names(names) when is_list(names) do
    # Deduplicate on the normalized key, but keep one original spelling per key
    # — Scryfall is queried with a real name, not our lookup key.
    wanted = Enum.uniq_by(names, &Name.normalize/1)
    known = CardQuery.list_by_normalized_names(Enum.map(wanted, &Name.normalize/1))
    known_keys = MapSet.new(known, & &1.name_normalized)

    missing = Enum.reject(wanted, &MapSet.member?(known_keys, Name.normalize(&1)))

    with {:ok, %{found: found, not_found: not_found}} <- fetch_missing(missing),
         {:ok, inserted} <- insert_all(found) do
      {:ok, %{cards: known ++ inserted, not_found: not_found}}
    end
  end

  defp fetch_missing([]), do: {:ok, %{found: [], not_found: []}}

  # Scryfall is asked for the card's REAL name, not our lossy lookup key and not
  # the raw decklist line: "Cultivate (M21) 177" and "juzam djinn" both resolve
  # to nothing.
  defp fetch_missing(names), do: names |> Enum.map(&Name.display/1) |> Scryfall.fetch_by_names()

  # Ordered by oracle_id, and that is load-bearing: two connections inserting
  # the same cards in different orders deadlock in Postgres (40P01). Scryfall
  # returns them in whatever order it likes, so we impose one here. The same law
  # is written down in `Deckex.CatalogueFixture` for the same reason.
  defp insert_all(scryfall_cards) do
    scryfall_cards
    |> Enum.sort_by(& &1["oracle_id"])
    |> Enum.reduce_while({:ok, []}, fn scryfall_card, {:ok, acc} ->
      case insert_card(scryfall_card) do
        {:ok, card} -> {:cont, {:ok, [card | acc]}}
        {:error, changeset} -> {:halt, invalid_card_error(scryfall_card, changeset)}
      end
    end)
    |> case do
      {:ok, cards} -> {:ok, Enum.reverse(cards)}
      {:error, _reason} = error -> error
    end
  end

  defp insert_card(scryfall_card) do
    attrs = ScryfallMapper.to_attrs(scryfall_card)

    %Card{}
    |> Card.changeset(attrs)
    # Upsert rather than plain insert, for two reasons. A concurrent import may
    # have inserted this card between our read and this write, and re-fetching a
    # card we already hold is the natural moment to refresh the advisory price
    # and the EDHREC rank — the only fields that legitimately change.
    #
    # Note `on_conflict: :nothing` would NOT work here: UUID primary keys are
    # generated client-side, so a skipped insert still returns a struct carrying
    # an id that was never written, and the caller would hold a phantom card.
    |> Repo.insert(
      on_conflict: {:replace, [:price_usd, :prices_updated_at, :edhrec_rank, :updated_at]},
      conflict_target: :oracle_id,
      returning: true
    )
  end

  @doc """
  Runs the rule engine over `card` and persists what it finds.

  Idempotent: re-running replaces a rule verdict with the fresh one. A
  `:manual` role is left untouched — the user's correction is permanent.
  """
  @spec classify_card(Card.t()) :: {:ok, [CardRole.t()]}
  def classify_card(%Card{} = card) do
    protected =
      card
      |> CardQuery.list_roles()
      |> Enum.filter(&(&1.source == :manual))
      |> MapSet.new(& &1.kind)

    roles =
      card
      |> Roles.classify()
      |> Enum.reject(&MapSet.member?(protected, &1.kind))
      |> Enum.map(&upsert_role!(card, &1, :rule))

    {:ok, roles}
  end

  @doc """
  Reclassifies the whole catalogue against today's rules, returning how many
  cards were touched.

  Adding a role to the vocabulary makes every previously-stored card stale: it
  was classified when the rule did not exist, so a guard reading that role
  silently misses them — a rule that looks enforced and is not. Run this once
  when a rule ships.
  """
  @spec reclassify_all!() :: non_neg_integer()
  def reclassify_all! do
    CardQuery.list_all_by_oracle_id()
    |> Enum.map(&classify_card/1)
    |> length()
  end

  @doc """
  Classifies every card in `cards`: rules first for free, then one AI call for
  whatever the rules could not place. Returns how many cards each path handled.

  The rule pass is committed before the AI is called, so an AI failure never
  costs the work the rules already did.
  """
  @spec classify_all([Card.t()]) ::
          {:ok, %{rules: non_neg_integer(), ai: non_neg_integer()}} | {:error, Error.t()}
  def classify_all(cards) do
    {residue, handled} = cards |> in_lock_order() |> Enum.split_with(&Roles.residue?/1)

    Enum.each(handled, &classify_card/1)

    with {:ok, ai_matches} <- RoleAI.classify(residue) do
      Enum.each(residue, fn card ->
        ai_matches
        |> Map.get(card.id, [])
        |> Enum.each(&upsert_role!(card, &1, :ai))
      end)

      {:ok, %{rules: length(handled), ai: map_size(ai_matches)}}
    end
  end

  @doc """
  Runs only the rule pass over `cards`. Free and instant, so it happens inline
  during import; the AI pass is what goes to a worker.
  """
  @spec classify_all_by_rules([Card.t()]) :: {:ok, %{rules: non_neg_integer()}}
  def classify_all_by_rules(cards) do
    handled = cards |> in_lock_order() |> Enum.reject(&Roles.residue?/1)

    Enum.each(handled, &classify_card/1)

    {:ok, %{rules: length(handled)}}
  end

  # Writing `card_roles` takes a lock per card, so the order cards are visited
  # in is the order locks are taken in. `resolve_names/1` returns known cards in
  # whatever order Postgres felt like, which means two callers classifying
  # overlapping cards can deadlock (40P01). One global order, as everywhere else
  # a card is written.
  defp in_lock_order(cards), do: Enum.sort_by(cards, & &1.oracle_id)

  @doc """
  Re-reads the Commander Format Panel's Game Changers list and applies it to
  the catalogue.

  Every card fetched from now on carries the flag already — Scryfall puts
  `game_changer` on the card object. This exists for the two cases that flag
  cannot cover: cards catalogued before the field was mapped, and the days
  the Panel revises the list, when a card already in the catalogue changes
  status without anyone re-fetching it.

  Cards that fall OFF the list are unmarked too. A restriction that outlives
  its own list is worse than no restriction, because it looks authoritative.
  """
  @spec refresh_game_changers() :: {:ok, %{marked: non_neg_integer()}} | {:error, Error.t()}
  def refresh_game_changers do
    with {:ok, cards} <- Scryfall.search("is:gamechanger") do
      oracle_ids = Enum.map(cards, & &1["oracle_id"])

      {marked, _} = CardQuery.set_game_changers(oracle_ids)

      {:ok, %{marked: marked}}
    end
  end

  @doc "Whether the rules failed to place this card, meaning the AI must see it."
  @spec residue?(Card.t()) :: boolean()
  defdelegate residue?(card), to: Roles

  @doc """
  Records a role chosen by the user. Manual roles are never overwritten by a
  later rule or AI pass, and they are the signal for improving the rules.
  """
  @spec set_role_manually(Card.t(), atom(), String.t()) :: {:ok, CardRole.t()}
  def set_role_manually(%Card{} = card, kind, evidence) do
    {:ok, upsert_role!(card, RoleMatch.new(kind, :high, evidence), :manual)}
  end

  defp upsert_role!(card, %RoleMatch{} = match, source) do
    %CardRole{}
    |> CardRole.changeset(%{
      card_id: card.id,
      kind: match.kind,
      confidence: match.confidence,
      source: source,
      evidence: match.evidence
    })
    |> Repo.insert!(
      on_conflict: {:replace, [:confidence, :source, :evidence, :updated_at]},
      conflict_target: [:card_id, :kind],
      returning: true
    )
  end

  defp invalid_card_error(scryfall_card, changeset) do
    {:error,
     Error.new(
       :cards_not_found,
       "A Scryfall devolveu uma carta que não consegui gravar.",
       %{name: scryfall_card["name"], errors: inspect(changeset.errors)}
     )}
  end
end
