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
  alias Deckex.Decks.Versions
  alias Deckex.Optimizations

  def consult_csv(conn, %{"id" => id}) do
    case Consults.fetch(id) do
      {:ok, consult} -> send_csv(conn, consult)
      {:error, error} -> conn |> put_status(:not_found) |> text(error.message)
    end
  end

  def optimization_shopping_txt(conn, %{"id" => id}) do
    with {:ok, run} <- Optimizations.fetch(id),
         {:ok, deck} <- Decks.fetch_deck(run.deck_id) do
      conn
      |> put_resp_content_type("text/plain")
      |> put_resp_header("content-disposition", ~s(attachment; filename="comprar.txt"))
      |> send_resp(200, Optimizations.shopping_list_text(run, deck))
    else
      {:error, error} -> conn |> put_status(:not_found) |> text(error.message)
    end
  end

  def version_diff_txt(conn, %{"id" => id, "from" => from, "to" => to}) do
    with {:ok, deck} <- Decks.fetch_deck(id),
         {:ok, from_version} <- Versions.fetch(deck, String.to_integer(from)),
         {:ok, to_version} <- Versions.fetch(deck, String.to_integer(to)) do
      text = from_version |> Versions.diff(to_version) |> Versions.buy_text()

      conn
      |> put_resp_content_type("text/plain")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="comprar-v#{from}-para-v#{to}.txt")
      )
      |> send_resp(200, text)
    else
      {:error, error} -> conn |> put_status(:not_found) |> text(error.message)
    end
  end

  def deck_diff_txt(conn, %{"from" => from_id, "to" => to_id}) do
    with {:ok, from} <- Decks.fetch_deck(from_id),
         {:ok, to} <- Decks.fetch_deck(to_id) do
      text = from |> Decks.compare(to) |> Versions.buy_text()

      conn
      |> put_resp_content_type("text/plain")
      |> put_resp_header("content-disposition", ~s(attachment; filename="comprar.txt"))
      |> send_resp(200, text)
    else
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
