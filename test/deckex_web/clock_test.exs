defmodule DeckexWeb.ClockTest do
  use ExUnit.Case, async: true

  alias DeckexWeb.Clock

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  describe "moment/1 — the scale follows the distance" do
    test "something that just happened says so" do
      assert Clock.moment(ago(10)) == "agora"
    end

    test "minutes matter while they are minutes" do
      assert Clock.moment(ago(12 * 60)) == "há 12 min"
    end

    # The one question anyone asks of a timestamp here is "was that just now or
    # ages ago", and "hoje 19:57" answers it without arithmetic.
    test "today is named, not dated" do
      moment = Clock.moment(ago(5 * 3600))

      assert moment =~ "hoje" or moment =~ "ontem"
    end

    test "an older one carries the day" do
      assert Clock.moment(ago(6 * 24 * 3600)) =~ ~r"^\d\d/\d\d \d\d:\d\d$"
    end

    test "another year carries the year" do
      assert Clock.moment(ago(400 * 24 * 3600)) =~ ~r"^\d\d/\d\d/\d\d\d\d$"
    end

    test "nothing renders as nothing, never as a crash" do
      assert Clock.moment(nil) == ""
      assert Clock.stamp(nil) == ""
    end
  end

  describe "local/1" do
    # The bug this exists to fix: a version marked at 19:57 in São Paulo
    # printed "22:57", right about the instant and wrong about the afternoon.
    test "moves a stored UTC timestamp into the machine's own zone" do
      utc = ~N[2026-08-15 22:57:00]

      # Whatever the machine's zone is, the conversion is the OS's own answer —
      # this app runs on its owner's laptop and the OS already knows the zone.
      expected =
        utc
        |> NaiveDateTime.to_erl()
        |> :calendar.universal_time_to_local_time()
        |> NaiveDateTime.from_erl!()

      assert Clock.local(utc) == expected
    end

    test "a DateTime and its naive twin land on the same wall clock" do
      utc = DateTime.from_naive!(~N[2026-08-15 22:57:00], "Etc/UTC")

      assert Clock.local(utc) == Clock.local(~N[2026-08-15 22:57:00])
    end
  end
end
