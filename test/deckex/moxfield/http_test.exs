defmodule Deckex.Moxfield.HttpTest do
  # async: false — Req.Test stubs are process-owned. DataCase, not ExUnit.Case:
  # the User-Agent is a setting now, so building a request reads the database.
  use Deckex.DataCase, async: false

  alias Deckex.Error
  alias Deckex.Moxfield
  alias Deckex.Moxfield.Http

  describe "public_id_from_url/1" do
    test "extracts the id from a deck URL" do
      assert {:ok, "kq9g4t81QUSl-5Vk7dTu2A"} =
               Moxfield.public_id_from_url("https://moxfield.com/decks/kq9g4t81QUSl-5Vk7dTu2A")
    end

    test "tolerates a trailing slash and query string" do
      assert {:ok, "abc123"} =
               Moxfield.public_id_from_url("https://www.moxfield.com/decks/abc123/?utm=x")
    end

    test "accepts a bare id" do
      assert {:ok, "abc123"} = Moxfield.public_id_from_url("abc123")
    end

    test "rejects a URL that is not a Moxfield deck" do
      assert {:error, %Error{code: :moxfield_not_found}} =
               Moxfield.public_id_from_url("https://example.com/oi")
    end
  end

  describe "fetch_deck/1 error mapping" do
    test "a Cloudflare 403 becomes a blocked error that points at pasting" do
      # This is the response an honest User-Agent actually gets, verified
      # against the live endpoint on 2026-08-13.
      Req.Test.stub(Http, fn conn ->
        Plug.Conn.send_resp(conn, 403, "<html>Cloudflare</html>")
      end)

      assert {:error, %Error{code: :moxfield_blocked} = error} = Http.fetch_deck("abc123")
      assert error.message =~ "colar"
    end

    test "a 404 becomes a not-found error" do
      Req.Test.stub(Http, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

      assert {:error, %Error{code: :moxfield_not_found}} = Http.fetch_deck("abc123")
    end

    test "a 401 becomes a private-deck error that points at pasting" do
      Req.Test.stub(Http, fn conn -> Plug.Conn.send_resp(conn, 401, "") end)

      assert {:error, %Error{code: :moxfield_private} = error} = Http.fetch_deck("abc123")
      assert error.message =~ "colar"
    end

    test "any other status becomes a blocked error rather than a crash" do
      Req.Test.stub(Http, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)

      assert {:error, %Error{code: :moxfield_blocked}} = Http.fetch_deck("abc123")
    end

    test "a transport failure becomes a blocked error" do
      Req.Test.stub(Http, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %Error{code: :moxfield_blocked}} = Http.fetch_deck("abc123")
    end

    # The setting is the whole point: the day Moxfield approves a User-Agent,
    # pasting it into Ajustes is what turns the 403 into a working sync.
    test "sends the User-Agent from Ajustes, not a hardcoded one" do
      {:ok, _value} = Deckex.Settings.put(:moxfield_user_agent, "deckex/1.0 (approved)")

      Req.Test.stub(Http, fn conn ->
        assert ["deckex/1.0 (approved)"] = Plug.Conn.get_req_header(conn, "user-agent")

        Plug.Conn.send_resp(conn, 404, "")
      end)

      assert {:error, _error} = Http.fetch_deck("abc123")
    end

    test "falls back to the declared default when nothing is stored" do
      Req.Test.stub(Http, fn conn ->
        assert ["deckex/0.1 (personal deck analysis tool)"] =
                 Plug.Conn.get_req_header(conn, "user-agent")

        Plug.Conn.send_resp(conn, 404, "")
      end)

      assert {:error, _error} = Http.fetch_deck("abc123")
    end

    test "maps a successful payload through the mapper" do
      body = "test/support/fixtures/moxfield/deck.json" |> File.read!() |> Jason.decode!()

      Req.Test.stub(Http, fn conn -> Req.Test.json(conn, body) end)

      assert {:ok, %{name: "Iroh das Lontra", decklist: decklist}} = Http.fetch_deck("abc123")
      assert decklist =~ "Sol Ring"
    end
  end
end
