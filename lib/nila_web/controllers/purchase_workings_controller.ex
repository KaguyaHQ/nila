defmodule NilaWeb.PurchaseWorkingsController do
  use NilaWeb, :controller
  alias Nila.Accounts.Policy
  alias Nila.Gst.Purchase.Workings.Xlsx
  alias NilaWeb.Gst.PurchaseWorkspace

  def download(conn, %{"client_id" => client_id, "period" => period}) do
    scope = conn.assigns.current_scope

    with true <- Policy.can?(scope, :export),
         {:ok, %{workings: %{} = workings} = data} <-
           PurchaseWorkspace.load(scope, client_id, period),
         {:ok, bytes} <-
           Xlsx.build(workings, data.client, period,
             review: data.review,
             status:
               if(data.signed_off?, do: "Recorded sign-off snapshot", else: "Prepared for review")
           ) do
      send_download(conn, {:binary, bytes},
        filename: "purchase_working_#{data.client.id}_#{period}.xlsx",
        content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      )
    else
      false -> conn |> put_status(:forbidden) |> text("Your role cannot download workings.")
      _ -> conn |> put_status(:not_found) |> text("Purchase workings not found.")
    end
  end
end
