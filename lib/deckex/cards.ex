defmodule Deckex.Cards do
  @moduledoc """
  The card catalogue: the local, permanent cache of Scryfall card data.

  `resolve_names/1` is the entry point every import uses. Cards already known
  are read from Postgres; only genuinely new ones cost a Scryfall request. Since
  a card is immutable and the catalogue is global, the cost of importing decks
  falls towards zero as the collection grows.
  """

  require Logger

  alias Deckex.Cards.Card
  alias Deckex.Cards.CardQuery
  alias Deckex.Cards.CardRole
  alias Deckex.Cards.Name
  alias Deckex.Cards.RoleAI
  alias Deckex.Cards.RoleMatch
  alias Deckex.Cards.Roles
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.Error
  alias Deckex.Log
  alias Deckex.Repo
  alias Deckex.Scryfall
  alias Deckex.Workers.RepriceWorker

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
      reprice_unpriced(inserted)
      log_resolution(wanted, known, inserted, not_found)

      {:ok, %{cards: known ++ inserted, not_found: not_found}}
    end
  end

  # The one place that can say what a lookup actually cost. "Já no catálogo" is
  # the number the Scryfall budget law exists to keep high, and it was
  # invisible: nothing told the owner whether importing a deck spent two
  # requests or none.
  defp log_resolution(wanted, known, inserted, not_found) do
    # Every name asked for lands in exactly one of the three, so the line adds
    # up. The first version said "0 buscadas na Scryfall" on a lookup that had
    # just spent a request — true of what came back, misleading about what it
    # cost.
    Logger.info(
      "#{Log.count(length(wanted), "carta pedida", "cartas pedidas")}: " <>
        "#{length(known)} do catálogo, #{length(inserted)} novas, " <>
        "#{Log.count(length(not_found), "não encontrada", "não encontradas")}"
    )

    # A name Scryfall does not have is almost always a typo in a pasted list,
    # and it silently shrinks every count the analysis makes afterwards.
    if not_found != [] do
      Logger.warning(
        "Scryfall não conhece #{Log.count(length(not_found), "carta", "cartas")}: " <>
          Log.names(not_found)
      )
    end
  end

  # A name lookup answers with one printing, usually the newest, and a printing
  # released this month has no market price yet. Left alone, the card sits in
  # the catalogue with a blank where the price goes — and blanks pass every
  # price ceiling, so the guard the owner set stops applying to exactly the
  # cards it cannot see. These get a follow-up pass on the scryfall queue.
  defp reprice_unpriced(cards) do
    case Enum.filter(cards, &is_nil(&1.price_usd)) do
      [] ->
        :ok

      unpriced ->
        {:ok, _job} = RepriceWorker.enqueue(Enum.map(unpriced, & &1.id))

        :ok
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
      on_conflict:
        {:replace,
         [:price_usd, :prices_updated_at, :edhrec_rank, :power, :toughness, :updated_at]},
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

    matches =
      card
      |> Roles.classify()
      |> Enum.reject(&MapSet.member?(protected, &1.kind))

    prune_stale_rules!(card, matches)

    {:ok, Enum.map(matches, &upsert_role!(card, &1, :rule))}
  end

  # A rule that gets tightened has to be able to take a role back. Without
  # this the catalogue only ever accumulates: a card keeps a verdict no rule
  # would give it today, and reclassifying looks like it did nothing.
  #
  # Only `:rule` rows are pruned. An `:ai` verdict was paid for and a
  # `:manual` one is the user's correction; neither is ours to drop.
  defp prune_stale_rules!(card, matches) do
    keep = MapSet.new(matches, & &1.kind)

    card
    |> CardQuery.list_roles()
    |> Enum.filter(&(&1.source == :rule and not MapSet.member?(keep, &1.kind)))
    |> Enum.each(&Repo.delete!/1)
  end

  @doc """
  Maps each of `names` to its Scryfall page, for the names it knows.

  One query for a whole screen: a page that shows fifty card names must not
  make fifty round trips. Names the catalogue has never seen are simply absent
  from the map, and the UI renders them as plain text — an unresolved card has
  nowhere honest to link to.
  """
  @spec uris_for_names([String.t()]) :: %{String.t() => String.t()}
  def uris_for_names(names) when is_list(names), do: for_names(names, & &1.scryfall_uri)

  @doc """
  Maps each of `names` to how much of Commander plays it, for the names it
  knows.

  The other half of the price column. A number in reais cannot tell an owner
  whether a suggestion is any good — this is the fact that can, and it costs
  the same single query.
  """
  @spec ranks_for_names([String.t()]) :: %{String.t() => integer()}
  def ranks_for_names(names) when is_list(names), do: for_names(names, & &1.edhrec_rank)

  # One query for a whole screen, whichever field the screen wants. A name the
  # catalogue has never seen is simply absent, so the UI renders it plainly
  # instead of showing a hole where a fact should be.
  defp for_names([], _field), do: %{}

  defp for_names(names, field) do
    by_normalized =
      names
      |> Enum.map(&Name.normalize/1)
      |> CardQuery.list_by_normalized_names()
      |> Map.new(&{&1.name_normalized, field.(&1)})

    names
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn name, acc ->
      case Map.get(by_normalized, Name.normalize(name)) do
        nil -> acc
        value -> Map.put(acc, name, value)
      end
    end)
  end

  @doc """
  Re-fetches every card in the catalogue, refreshing the fields a re-fetch is
  allowed to change.

  Cards are immutable, so this exists for one situation: the app learned to
  store a field it never stored before, and 159 rows have a hole where the
  data should be. Goes through the same chunked, throttled port as every other
  fetch — the Scryfall budget law does not have an exception for backfills.
  """
  @spec refresh_all!() :: {:ok, non_neg_integer()} | {:error, Error.t()}
  def refresh_all! do
    names = CardQuery.list_all_by_oracle_id() |> Enum.map(& &1.name)

    with {:ok, %{found: found}} <- Scryfall.fetch_by_names(names),
         {:ok, refreshed} <- insert_all(found) do
      {:ok, length(refreshed)}
    end
  end

  @doc """
  Enqueues one stale-only price sweep at application boot.

  The daily cron assumes a server that is awake at 06:00, and a desktop app
  is not: the owner opened the deck page to "preços de 13 dias atrás" because
  the sweep had never had a chance to fire. Uniqueness (one per day, any
  state) makes this free when the cron already ran — and the whole call is
  wrapped so a database that is not up yet cannot stop the app from booting.

  Skipped under `Oban.Testing`: the test suite starts this application before
  the sandbox owns the connection, and a job row written there would leak.
  """
  @spec reprice_stale_on_boot() :: :ok
  def reprice_stale_on_boot do
    unless Application.get_env(:deckex, Oban)[:testing] do
      %{stale: true}
      |> RepriceWorker.new(unique: [period: {1, :day}])
      |> Oban.insert()
    end

    :ok
  rescue
    _boot_race -> :ok
  end

  @doc """
  Re-prices `card` from the cheapest paper printing Scryfall lists.

  The catalogue stores one representative printing per card, and its price is
  the price of *that* printing — which is the price of a specific piece of
  cardboard, not the answer to "what does this card cost me". A card the owner
  would buy for eight reais can be catalogued at forty because the lookup
  happened to return the new-set version, and a card that just got reprinted
  can be catalogued at nothing at all.

  Nothing but the price is touched, and a card Scryfall cannot price keeps what
  it had: repricing may correct a number, never erase one.
  """
  @spec reprice(Card.t()) :: {:ok, Card.t()} | {:error, Error.t()}
  def reprice(%Card{} = card) do
    with {:ok, printings} <- Scryfall.printings(card.oracle_id) do
      case ScryfallMapper.cheapest_usd(printings) do
        nil -> {:ok, card}
        price -> {:ok, card |> Card.price_changeset(price) |> Repo.update!()}
      end
    end
  end

  @doc """
  Re-prices every card in `cards`, reporting what actually moved.

  A card whose printings Scryfall will not serve is logged and skipped rather
  than halting the pass: a price is advisory, and one 404 must not cost the
  other hundred and seventy-eight corrections.
  """
  @spec reprice_all([Card.t()]) :: %{
          checked: non_neg_integer(),
          changed: [%{name: String.t(), from: Decimal.t() | nil, to: Decimal.t()}]
        }
  def reprice_all(cards) when is_list(cards) do
    result =
      cards
      |> in_lock_order()
      |> Enum.reduce(%{checked: 0, changed: []}, &reprice_one/2)
      |> Map.update!(:changed, &Enum.reverse/1)

    Logger.info(
      "preços: #{result.checked} conferidos, #{length(result.changed)} mudaram " <>
        "(#{length(cards)} pedidos)"
    )

    result
  end

  @doc "Every card in the catalogue, in `oracle_id` order."
  @spec list_all() :: [Card.t()]
  defdelegate list_all(), to: CardQuery, as: :list_all_by_oracle_id

  @doc "When the freshest and the stalest price in the catalogue were read."
  defdelegate price_age(), to: CardQuery

  @doc """
  How old a price may get before it is worth reading again.

  A week. Card prices move, and the owner budgets from these numbers — but
  they move slowly enough that a daily sweep of the whole catalogue would spend
  Scryfall's budget to change the third decimal place.
  """
  @spec price_max_age_days() :: pos_integer()
  def price_max_age_days, do: 7

  @doc """
  The cards whose price is older than `price_max_age_days/0`, or absent.

  What the daily sweep and the Ajustes button both work on. Repricing the
  whole catalogue costs one request per card; repricing only what has gone
  stale costs almost nothing once the catalogue has been swept once.
  """
  @spec stale_prices() :: [Card.t()]
  def stale_prices do
    CardQuery.list_stale_prices(DateTime.add(DateTime.utc_now(), -price_max_age_days(), :day))
  end

  defp reprice_one(card, acc) do
    case reprice(card) do
      {:ok, repriced} ->
        record_reprice(acc, card, repriced.price_usd)

      {:error, %Error{} = error} ->
        Logger.warning("preço de #{card.name} não atualizado: #{error.message}")

        acc
    end
  end

  defp record_reprice(acc, card, price) do
    acc = %{acc | checked: acc.checked + 1}

    if moved?(card.price_usd, price) do
      %{acc | changed: [%{name: card.name, from: card.price_usd, to: price} | acc.changed]}
    else
      acc
    end
  end

  defp moved?(nil, nil), do: false
  defp moved?(nil, _new), do: true
  defp moved?(_old, nil), do: false
  defp moved?(old, new), do: not Decimal.equal?(old, new)

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
