defmodule DeckexWeb.PageController do
  use DeckexWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
