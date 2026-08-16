defmodule Deckex.Repo.Migrations.CreateOptimizationMarks do
  @moduledoc """
  The cards the owner flagged while a run was going, and what he has to say
  about each.

  A run takes half an hour and reads as a wall of paragraphs. The owner spots
  a wrong call in stage 2 — a card whose text the model misread — and by stage
  9 there is nowhere to put that. This is the place: mark it while reading,
  say why at the end, and let one last stage act on it.
  """
  use Ecto.Migration

  def change do
    create table(:optimization_marks, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :optimization_id,
          references(:optimizations, type: :uuid, on_delete: :delete_all),
          null: false

      add :card_name, :string, null: false

      # What the pipeline had done to the card when it was marked — the note
      # reads differently against a cut than against an add.
      add :action, :string
      add :note, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:optimization_marks, [:optimization_id, :card_name])
  end
end
