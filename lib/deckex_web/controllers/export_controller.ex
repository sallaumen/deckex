defmodule DeckexWeb.ExportController do
  @moduledoc """
  Downloads: a consult's suggestion table as CSV, and a deck as decklist text.

  The decklist is the same format the app imports, so a deck can go back out
  the door it came in through — into a shop's bulk-add box, into Moxfield, or
  into another copy of this app.
  """
  use DeckexWeb, :controller

  alias Deckex.Consults
  alias Deckex.Consults.Suggestions
  alias Deckex.Decks

  def consult_csv(conn, %{"id" => id}) do
    case Consults.fetch(id) do
      {:ok, consult} -> send_csv(conn, consult)
      {:error, error} -> conn |> put_status(:not_found) |> text(error.message)
    end
  end

  def deck_txt(conn, %{"id" => id}) do
    case Decks.fetch_deck(id) do
      {:ok, deck} -> send_decklist(conn, deck)
      {:error, error} -> conn |> put_status(:not_found) |> text(error.message)
    end
  end

  defp send_decklist(conn, deck) do
    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename(deck)}.txt"))
    |> send_resp(200, Decks.to_decklist_text(deck))
  end

  # A deck called "Iroh das Lontra — otimizado" must not become a path.
  defp filename(deck) do
    deck.name
    |> String.replace(~r/[^\p{L}\p{N}]+/u, "-")
    |> String.trim("-")
    |> String.downcase()
    |> case do
      "" -> "deck"
      name -> name
    end
  end

  defp send_csv(conn, consult) do
    csv = consult |> Suggestions.for_consult() |> Suggestions.to_csv()

    conn
    |> put_resp_content_type("text/csv")
    |> put_resp_header("content-disposition", ~s(attachment; filename="sugestoes.csv"))
    |> send_resp(200, csv)
  end
end
