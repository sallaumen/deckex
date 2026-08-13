defmodule DeckexWeb.ExportController do
  @moduledoc "Downloads a consult's suggestion table as CSV."
  use DeckexWeb, :controller

  alias Deckex.Consults
  alias Deckex.Consults.Suggestions

  def consult_csv(conn, %{"id" => id}) do
    case Consults.fetch(id) do
      {:ok, consult} -> send_csv(conn, consult)
      {:error, error} -> conn |> put_status(:not_found) |> text(error.message)
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
