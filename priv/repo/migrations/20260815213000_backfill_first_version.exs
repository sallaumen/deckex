defmodule Deckex.Repo.Migrations.BackfillFirstVersion do
  @moduledoc """
  Gives every deck that predates versioning its v1.

  Without it the four decks already on the table open the history screen on
  "nenhuma versão ainda" and stay that way until someone marks one by hand —
  which means the first optimization applied to them would have nothing to
  compare against. The list here is the deck as it stands today, which is the
  honest label: we do not know what it looked like when it was imported.

  Written against the tables rather than the contexts on purpose. A migration
  runs against the schema of its own day; `Deckex.Decks.Versions` is free to
  change tomorrow.
  """
  use Ecto.Migration

  import Ecto.Query

  def up do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for deck_id <- decks_without_versions() do
      {commanders, rows} = working_state(deck_id)

      repo().insert_all("deck_versions", [
        %{
          id: Uniq.UUID.uuid7(:raw),
          deck_id: deck_id,
          number: 1,
          origin: "import",
          label: "Como está hoje",
          list: %{"rows" => rows},
          commanders: commanders,
          changes: %{"applied" => []},
          inserted_at: now,
          updated_at: now
        }
      ])
    end
  end

  # Irreversible by choice: dropping versions to undo a backfill would delete
  # history a person may have built on top of it.
  def down, do: :ok

  defp decks_without_versions do
    repo().all(
      from(d in "decks",
        left_join: v in "deck_versions",
        on: v.deck_id == d.id,
        where: is_nil(v.id),
        select: d.id
      )
    )
  end

  defp working_state(deck_id) do
    cards =
      repo().all(
        from(dc in "deck_cards",
          join: c in "cards",
          on: c.id == dc.card_id,
          where: dc.deck_id == ^deck_id,
          select: %{name: c.name, quantity: dc.quantity, board: dc.board}
        )
      )

    {commanders, main} = Enum.split_with(cards, &(&1.board == "commander"))

    {Enum.map(commanders, & &1.name),
     Enum.map(main, &%{"name" => &1.name, "quantity" => &1.quantity})}
  end
end
