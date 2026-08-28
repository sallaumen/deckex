defmodule Mix.Tasks.Deckex.Roles.Diff do
  @shortdoc "Diffs rule classification against the stored catalogue"

  @moduledoc """
  Classifies every card in the catalogue with the CURRENT rules and diffs the
  result against the roles stored in the database.

      mix deckex.roles.diff            # read-only report
      mix deckex.roles.diff --apply    # then reclassify the catalogue

  This is the validation that caught every false positive the rules ever
  shipped — Rhystic Study losing draw to a proximity window, a cycling Triome
  becoming a draw engine through reminder text, Mizzix's Mastery turning into
  a board wipe. The workflow is a law: a rule change travels with this diff,
  reviewed line by line, and then with `--apply` (the stale-catalogue law).

  Starts the Repo alone — never the application, never Oban. A `mix run`
  script that starts the app becomes the Oban consumer and dies mid-job when
  the script ends; this task cannot, because Oban is never started.
  """
  use Mix.Task

  import Ecto.Query

  alias Deckex.Cards.Roles

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.config")
    {:ok, _apps} = Application.ensure_all_started(:ecto_sql)
    {:ok, _pid} = Deckex.Repo.start_link(pool_size: 2)

    # Interns the role atoms before `to_existing_atom` meets the strings the
    # database sends back.
    Code.ensure_loaded!(Deckex.Cards.RoleMatch)

    cards = Deckex.Repo.all(Deckex.Cards.Card)

    stored =
      from(r in "card_roles", where: r.source == "rule", select: {r.card_id, r.kind})
      |> Deckex.Repo.all()
      |> Enum.group_by(fn {id, _kind} -> Ecto.UUID.load!(id) end, fn {_id, kind} ->
        String.to_existing_atom(kind)
      end)

    changes =
      for card <- cards,
          old = stored |> Map.get(card.id, []) |> MapSet.new(),
          new = card |> Roles.classify() |> MapSet.new(& &1.kind),
          old != new do
        gained = MapSet.difference(new, old) |> Enum.map(&"+#{&1}")
        lost = MapSet.difference(old, new) |> Enum.map(&"-#{&1}")

        {card.name, Enum.join(gained ++ lost, " ")}
      end

    Mix.shell().info("#{length(cards)} cartas no catálogo · #{length(changes)} mudam")

    for {name, delta} <- Enum.sort(changes) do
      Mix.shell().info("  #{String.pad_trailing(name, 42)} #{delta}")
    end

    if "--apply" in argv do
      count = Deckex.Cards.reclassify_all!()
      Mix.shell().info("reclassificadas: #{count}")
    end
  end
end
