defmodule Deckex.Scryfall.HttpTest do
  # async: false — Req.Test stubs are process-owned and the throttle config is
  # global.
  use ExUnit.Case, async: false

  alias Deckex.Error
  alias Deckex.Scryfall.Http

  describe "fetch_by_names/1" do
    test "returns empty results without calling out for an empty list" do
      assert {:ok, %{found: [], not_found: []}} = Http.fetch_by_names([])
    end

    test "posts names as identifiers and returns the found cards" do
      Req.Test.stub(Http, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"identifiers" => [%{"name" => "Sol Ring"}]} = Jason.decode!(body)

        Req.Test.json(conn, %{"data" => [%{"name" => "Sol Ring"}], "not_found" => []})
      end)

      assert {:ok, %{found: [%{"name" => "Sol Ring"}], not_found: []}} =
               Http.fetch_by_names(["Sol Ring"])
    end

    test "reports unresolved names by name" do
      Req.Test.stub(Http, fn conn ->
        Req.Test.json(conn, %{
          "data" => [],
          "not_found" => [%{"name" => "Not A Real Card"}]
        })
      end)

      assert {:ok, %{found: [], not_found: ["Not A Real Card"]}} =
               Http.fetch_by_names(["Not A Real Card"])
    end

    test "chunks into batches of 75, the endpoint's documented maximum" do
      Req.Test.stub(Http, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        %{"identifiers" => identifiers} = Jason.decode!(body)
        send(self(), {:batch, length(identifiers)})

        Req.Test.json(conn, %{"data" => [], "not_found" => []})
      end)

      names = Enum.map(1..80, &"Card #{&1}")
      assert {:ok, %{found: []}} = Http.fetch_by_names(names)

      assert_received {:batch, 75}
      assert_received {:batch, 5}
    end

    test "merges results across batches" do
      Req.Test.stub(Http, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        %{"identifiers" => identifiers} = Jason.decode!(body)
        found = Enum.map(identifiers, &%{"name" => &1["name"]})

        Req.Test.json(conn, %{"data" => found, "not_found" => []})
      end)

      names = Enum.map(1..80, &"Card #{&1}")
      assert {:ok, %{found: found}} = Http.fetch_by_names(names)
      assert length(found) == 80
    end

    test "turns a non-200 response into a domain error" do
      Req.Test.stub(Http, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)

      assert {:error, %Error{code: :scryfall_unavailable, details: %{status: 503}}} =
               Http.fetch_by_names(["Sol Ring"])
    end

    test "turns a transport failure into a domain error" do
      Req.Test.stub(Http, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %Error{code: :scryfall_unavailable}} = Http.fetch_by_names(["Sol Ring"])
    end
  end
end
