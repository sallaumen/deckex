defmodule DeckexWeb.ContentSecurityPolicyTest do
  use DeckexWeb.ConnCase, async: true

  defp policy(conn) do
    [header] = Plug.Conn.get_resp_header(conn, "content-security-policy")

    header |> String.split("; ") |> Map.new(&List.to_tuple(String.split(&1, " ", parts: 2)))
  end

  test "every page carries the policy", %{conn: conn} do
    directives = conn |> get(~p"/") |> policy()

    assert directives["default-src"] == "'self'"
  end

  test "card art is allowed, and only from Scryfall", %{conn: conn} do
    directives = conn |> get(~p"/") |> policy()

    assert directives["img-src"] =~ "https://cards.scryfall.io"
    refute directives["img-src"] =~ "*"
  end

  test "the LiveView socket can connect", %{conn: conn} do
    assert conn |> get(~p"/") |> policy() |> Map.fetch!("connect-src") =~ "ws"
  end

  # The one grant that would actually matter. Inline *styles* are allowed
  # because a `style` attribute is inline by definition; inline *scripts* are
  # what a CSP exists to stop, and no amount of convenience earns them.
  test "inline scripts stay forbidden", %{conn: conn} do
    directives = conn |> get(~p"/") |> policy()

    assert directives["script-src"] == "'self'"
    refute directives["script-src"] =~ "unsafe"
  end

  test "the app cannot be framed", %{conn: conn} do
    assert conn |> get(~p"/") |> policy() |> Map.fetch!("frame-ancestors") == "'none'"
  end
end
