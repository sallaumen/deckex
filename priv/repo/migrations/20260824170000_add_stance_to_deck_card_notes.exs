defmodule Deckex.Repo.Migrations.AddStanceToDeckCardNotes do
  @moduledoc """
  The owner's word about a card was only ever advice. Now it can be an order.

  He watched a run cut Sam, Loyal Attendant — a card that is half of an
  infinite combo in his list — because the stage read her in isolation and she
  is unremarkable alone. A note saying so reached the next briefing, but a note
  is prose: the engine could not act on it, and the same run could cut her
  again the moment a stage decided the prose was outweighed.

  A stance is the same row saying what he wants done about it: `locked` is
  never cut, enforced by the audit; `wanted` is a card he is asking for;
  `note` is what this table already held. The reason he types stays the same
  text in the same column, because "why" is the part that teaches the model —
  which is why the note is no longer required: an order does not need a
  justification to be an order.
  """
  use Ecto.Migration

  def change do
    alter table(:deck_card_notes) do
      add :stance, :string, null: false, default: "note"

      # A lock with no explanation is still a lock.
      modify :note, :text, null: true, from: {:text, null: false}
    end
  end
end
