defmodule DeckexWeb.Clock do
  @moduledoc """
  Timestamps as the person in front of the screen reads them.

  Two problems, one answer. **The offset:** everything is stored in UTC, and a
  version marked at 19:57 in São Paulo printed as "15/08 22:57" — a number that
  is right about the instant and wrong about the afternoon it happened in.
  **The shape:** "15/08 22:57" makes you do arithmetic to answer the only
  question anyone asks of a timestamp here, which is "was that just now, or
  was that ages ago".

  The offset comes from the operating system — `:calendar` reads the machine's
  own zone — rather than from a time zone database added as a dependency. This
  app runs on its owner's laptop, in its owner's timezone, and the OS already
  knows which one that is. A deployed multi-user version would need the real
  database; this one would only be carrying it to answer a question it can
  already answer.
  """

  @doc """
  A UTC timestamp as a sentence: `agora`, `há 12 min`, `hoje 19:57`,
  `ontem 22:10`, `13/08 17:24`, `04/11/2025`.

  The scale changes with the distance, because that is how the answer is
  used: minutes matter for something that just happened and nothing else does,
  and the year matters only once it is not this one.
  """
  @spec moment(DateTime.t() | NaiveDateTime.t() | nil) :: String.t()
  def moment(nil), do: ""

  def moment(timestamp) do
    local = local(timestamp)
    seconds = NaiveDateTime.diff(local(now()), local)

    cond do
      seconds < 60 -> "agora"
      seconds < 3600 -> "há #{div(seconds, 60)} min"
      today?(local) -> "hoje #{time(local)}"
      yesterday?(local) -> "ontem #{time(local)}"
      this_year?(local) -> "#{day(local)} #{time(local)}"
      true -> Calendar.strftime(local, "%d/%m/%Y")
    end
  end

  @doc "Day and time in the machine's own zone: `13/08 17:24`."
  @spec stamp(DateTime.t() | NaiveDateTime.t() | nil) :: String.t()
  def stamp(nil), do: ""

  def stamp(timestamp) do
    local = local(timestamp)

    "#{day(local)} #{time(local)}"
  end

  @doc "A stored UTC timestamp moved into the machine's own zone."
  @spec local(DateTime.t() | NaiveDateTime.t()) :: NaiveDateTime.t()
  def local(%DateTime{} = timestamp), do: timestamp |> DateTime.to_naive() |> local()

  def local(%NaiveDateTime{} = timestamp) do
    {date, time} = NaiveDateTime.to_erl(timestamp)

    {date, time}
    |> :calendar.universal_time_to_local_time()
    |> NaiveDateTime.from_erl!()
  end

  defp now, do: DateTime.utc_now()

  defp today?(local), do: NaiveDateTime.to_date(local) == NaiveDateTime.to_date(local(now()))

  defp yesterday?(local) do
    NaiveDateTime.to_date(local) ==
      now() |> local() |> NaiveDateTime.to_date() |> Date.add(-1)
  end

  defp this_year?(local), do: local.year == local(now()).year

  defp day(local), do: Calendar.strftime(local, "%d/%m")
  defp time(local), do: Calendar.strftime(local, "%H:%M")
end
