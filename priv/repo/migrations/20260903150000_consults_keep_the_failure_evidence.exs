defmodule Deckex.Repo.Migrations.ConsultsKeepTheFailureEvidence do
  use Ecto.Migration

  def change do
    alter table(:consults) do
      # `error` is one pt-BR sentence for the owner. These two are the evidence
      # behind it: the code the app branches on, and the raw detail the adapter
      # already built and then dropped on the floor.
      #
      # A run failed with "A IA retornou erro." and nothing else — not on the
      # screen, not in the terminal. The `claude` CLI had said exactly what was
      # wrong, in `details.result`, and no column existed to hold it.
      add :error_code, :string
      add :error_details, :map
    end
  end
end
