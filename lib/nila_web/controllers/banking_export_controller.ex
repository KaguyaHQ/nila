defmodule NilaWeb.BankingExportController do
  use NilaWeb, :controller

  alias Nila.Banking
  alias Nila.Banking.Tally

  def tally(conn, %{"id" => id} = params) do
    org_id = conn.assigns.current_scope.current_org.id
    export = Map.get(params, "export", %{})

    with {:ok, statement} <- Banking.get_statement(org_id, id),
         {:ok, xml} <-
           Tally.build(statement,
             bank_ledger_name: export["bank_ledger_name"],
             from: export["from"],
             to: export["to"]
           ) do
      filename = "bank_#{statement.bank_code}_#{statement.id}_tally.xml"

      conn
      |> put_resp_content_type("application/xml")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
      |> send_resp(200, xml)
    else
      {:error, :no_transactions} ->
        conn
        |> put_status(:unprocessable_entity)
        |> text("No transactions fall in that date range")

      {:error, :invalid_statement} ->
        conn |> put_status(:unprocessable_entity) |> text("Invalid bank ledger or date range")

      {:error, _reason} ->
        conn |> put_status(:not_found) |> text("Not found")
    end
  end
end
