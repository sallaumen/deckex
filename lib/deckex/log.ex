defmodule Deckex.Log do
  @moduledoc """
  What every log line in this app carries, and how the numbers in one are
  written.

  This is **not** a wrapper around `Logger`. Wrapping it would replace the
  caller's module and line with this one's on every line in the app, and
  `Logger.info/2` already takes metadata as its second argument. What was
  missing is agreement on *which* metadata — so `deck_id:` here and `deck:`
  there never became two ways to ask the same question.

  ## The two halves of a line

  **The message is a sentence in pt-BR**, written for the person reading a
  terminal at midnight, not for a parser. The owner reads these; every error
  string in this app is already pt-BR, and an English sentence wrapped around
  a pt-BR `error.message` reads worse than either.

  **The metadata is the structured half**: identifiers and counts, set once per
  unit of work with `context/1` and inherited by every line the process writes
  after it. Dev prints only `deck`, because the deck's *name* is the thing the
  owner needs to tell one run from another and the ids are noise on a screen.
  Everything else is still attached, and a JSON backend would emit all of it.

  ## Setting the context

  Call `context/1` at the top of a unit of work — an Oban `perform/1`, a
  LiveView `mount/3` — and everything downstream is tagged for free:

      Deckex.Log.context(deck: deck)
      Logger.info("importou 100 cartas")
      #=> [info] deck=Rograkh importou 100 cartas

  Metadata is per-process, so a worker cannot leak its deck into another job.
  """

  require Logger

  @doc """
  Tags this process's log lines with the things worth grepping for.

  Accepts the structs themselves rather than their fields: a caller that has to
  remember `deck_id: deck.id, deck: deck.name` is a caller that will eventually
  write one and forget the other.

  Unknown keys pass through untouched, so a one-off `Log.context(cards: 12)` is
  still available without teaching this function about it.
  """
  @spec context(keyword() | map()) :: :ok
  def context(bindings), do: bindings |> fields() |> Logger.metadata()

  @doc """
  The same expansion, returned instead of set — for one line rather than a
  whole unit of work.

  Used where there is no unit of work to tag: a LiveView handler that touches
  one deck and moves on has nothing to inherit the context, and tagging the
  process there would leak the deck onto every later line in that socket.

  ## Examples

      Logger.info("importou 100 cartas", Deckex.Log.fields(deck: deck))
  """
  @spec fields(keyword() | map()) :: keyword()
  def fields(bindings), do: Enum.flat_map(bindings, &expand/1)

  # An association nobody preloaded carries no name to print and no id to
  # grep. Dropping it beats dumping `%Ecto.Association.NotLoaded{}` into the
  # metadata, which is what a permissive catch-all would do.
  defp expand({_key, %Ecto.Association.NotLoaded{}}), do: []
  defp expand({_key, nil}), do: []

  defp expand({:deck, %{id: id, name: name}}), do: [deck: name, deck_id: id]

  defp expand({:consult, %{id: id, lens: lens, model: model}}),
    do: [consult_id: id, lens: lens, model: model]

  defp expand({:optimization, %{id: id, mode: mode}}), do: [optimization_id: id, mode: mode]
  defp expand({key, value}), do: [{key, value}]

  @doc """
  A count with its noun, agreeing in number.

  "1 nomes em 1 requisição" is the sound of a log line nobody proofread, and
  this app writes counts on nearly every line it writes.

  ## Examples

      iex> Deckex.Log.count(1, "nome", "nomes")
      "1 nome"

      iex> Deckex.Log.count(0, "requisição", "requisições")
      "0 requisições"
  """
  @spec count(integer(), String.t(), String.t()) :: String.t()
  def count(1, singular, _plural), do: "1 #{singular}"
  def count(n, _singular, plural), do: "#{n} #{plural}"

  @doc """
  A list of names, capped so a line stays a line.

  Written after watching a real import print sixty-five card names into one
  warning. The count is the fact; the names are the hint that lets you guess
  what happened, and five is enough to guess with. The full list belongs on
  the screen, where it can wrap.

  ## Examples

      iex> Deckex.Log.names(["Sol Ring", "Cultivate"])
      "Sol Ring, Cultivate"

      iex> Deckex.Log.names(~w(a b c d e f g), 3)
      "a, b, c e mais 4"

      iex> Deckex.Log.names([])
      "nenhuma"
  """
  @spec names([String.t()], pos_integer()) :: String.t()
  def names(names, limit \\ 5)
  def names([], _limit), do: "nenhuma"

  def names(names, limit) do
    case Enum.split(names, limit) do
      {shown, []} -> Enum.join(shown, ", ")
      {shown, rest} -> "#{Enum.join(shown, ", ")} e mais #{length(rest)}"
    end
  end

  @doc """
  A duration a person can read at a glance.

  Milliseconds below a second, seconds with one decimal below a minute, and
  `m`/`s` above it. A stage of this app's pipeline routinely runs for six
  minutes; `372481ms` is a number you have to do arithmetic on before you know
  whether to worry.

  ## Examples

      iex> Deckex.Log.duration(412)
      "412ms"

      iex> Deckex.Log.duration(6231)
      "6.2s"

      iex> Deckex.Log.duration(372_481)
      "6m12s"

      iex> Deckex.Log.duration(nil)
      "?"
  """
  @spec duration(integer() | nil) :: String.t()
  def duration(nil), do: "?"
  def duration(ms) when ms < 1_000, do: "#{ms}ms"
  def duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1_000, 1)}s"

  def duration(ms) do
    seconds = div(ms, 1_000)

    "#{div(seconds, 60)}m#{rem(seconds, 60)}s"
  end
end
