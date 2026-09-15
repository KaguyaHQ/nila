defmodule NilaWeb.Gstr1Controller do
  @moduledoc """
  Serves a worked sales month's artifacts through the org-membership check:
  the portal-shaped GSTR-1 JSON (the file an auditor uploads to the portal)
  and the scanned page evidence. Tenant comes from `current_scope`, never a
  URL param — same discipline as `GstEvidenceController`.
  """
  use NilaWeb, :controller

  alias Nila.Clients
  alias Nila.Gst.Filing.{TallyPrime, WinmanGstr1}
  alias Nila.Gst.Sales.Gstr1.Packet, as: Gstr1Packet
  alias Nila.Gst.Sales.Months, as: SalesMonths
  alias Nila.Gst.Sales.Review.Resolutions, as: SalesResolutions
  alias Nila.Gst.Sales.Tally.Packet, as: TallyPacket
  alias Nila.Gst.Sales.Workings.Xlsx, as: WorkingsXlsx

  plug :require_finished_uploads
       when action in [
              :return_json,
              :winman_b2b,
              :workings_xlsx,
              :tally_download,
              :sales_bills_tally_download,
              :sales_bills_gstr1_download
            ]

  defp require_finished_uploads(conn, _) do
    org_id = conn.assigns.current_scope.current_org.id

    dumps =
      case conn.params do
        %{"client_id" => client_id, "period" => period} ->
          Nila.Gst.Intake.Dumps.list(org_id, client_id, period)

        %{"client_id" => client_id, "batch_ref" => ref} ->
          case TallyPacket.fetch(org_id, client_id, ref) do
            {:ok, dumps} -> dumps
            _ -> []
          end
      end

    if Nila.Gst.Intake.Dumps.unresolved?(dumps, "sales") do
      conn
      |> put_status(:unprocessable_entity)
      |> text("Finish reading or resolve failed uploads before exporting")
      |> halt()
    else
      conn
    end
  end

  def return_json(conn, %{"client_id" => client_id, "period" => period}) do
    org_id = conn.assigns.current_scope.current_org.id

    case SalesMonths.get_by_period(org_id, client_id, period) do
      {:ok, sales_month} ->
        projection = SalesResolutions.effective_workings(sales_month)
        derived = projection.derived
        filename = "gstr1_#{derived["gstin"]}_#{period}.json"

        cond do
          require_active_sales(projection) == {:error, :no_active_sales} ->
            conn
            |> put_status(:unprocessable_entity)
            |> text("Exports are unavailable until invoices are added")

          same_period?(projection, period) ->
            conn
            |> put_resp_content_type("application/json")
            |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
            |> send_resp(200, Jason.encode!(derived))

          true ->
            conn
            |> put_status(:unprocessable_entity)
            |> text("Correct or exclude invoices outside this working period")
        end

      {:error, _} ->
        conn
        |> put_status(:not_found)
        |> text("Not found")
    end
  end

  def winman_b2b(conn, %{"client_id" => client_id, "period" => period}) do
    org_id = conn.assigns.current_scope.current_org.id

    with {:ok, sales_month} <- SalesMonths.get_by_period(org_id, client_id, period),
         {:ok, client} <- Clients.get_client(org_id, client_id),
         projection <- SalesResolutions.effective_workings(sales_month),
         :ok <- require_active_sales(projection),
         true <- same_period?(projection, period),
         {:ok, workbook} <-
           WinmanGstr1.build(projection, client, period) do
      filename = "gstr1_#{client.gstin || client.id}_#{period}_winman_b2b.xlsm"

      conn
      |> put_resp_content_type("application/vnd.ms-excel.sheet.macroEnabled.12", nil)
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
      |> send_resp(200, workbook)
    else
      {:error, :no_active_sales} ->
        conn
        |> put_status(:unprocessable_entity)
        |> text("Exports are unavailable until invoices are added")

      false ->
        conn
        |> put_status(:unprocessable_entity)
        |> text("Correct or exclude invoices outside this working period")

      {:error, reason}
      when reason in [:invalid_period, :unsupported_period, :invalid_b2b_data, :too_many_rows] ->
        conn
        |> put_status(:unprocessable_entity)
        |> text(export_error(reason))

      {:error, _reason} ->
        conn
        |> put_status(:not_found)
        |> text("Not found")
    end
  end

  def workings_xlsx(conn, %{"client_id" => client_id, "period" => period}) do
    org_id = conn.assigns.current_scope.current_org.id

    with {:ok, sales_month} <- SalesMonths.get_by_period(org_id, client_id, period),
         {:ok, client} <- Clients.get_client(org_id, client_id),
         projection <- SalesResolutions.effective_workings(sales_month),
         :ok <- require_active_sales(projection),
         true <- same_period?(projection, period),
         resolutions <- SalesResolutions.list_attributed(sales_month.id),
         {:ok, workbook} <-
           WorkingsXlsx.build(projection, client, period,
             status: workbook_status(sales_month),
             resolutions: resolutions,
             invoice_urls:
               Map.new(projection.active_invoices, fn invoice ->
                 path = ~p"/gst/#{client.id}/#{period}/sales/invoices/#{invoice["id"]}"
                 {invoice["id"], NilaWeb.Endpoint.url() <> path}
               end)
           ) do
      name =
        client.name
        |> String.replace(~r/[^\p{L}\p{M}\p{N}]+/u, "_")
        |> String.trim("_")
        |> String.slice(0, 80)

      filename = "gst_sales_working_#{name}_#{client.gstin || client.id}_#{period}.xlsx"
      fallback = String.replace(filename, ~r/[^a-zA-Z0-9_.-]/, "_")

      conn
      |> put_resp_content_type(
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        nil
      )
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="#{fallback}"; filename*=UTF-8''#{URI.encode(filename, &URI.char_unreserved?/1)})
      )
      |> send_resp(200, workbook)
    else
      false ->
        conn
        |> put_status(:unprocessable_entity)
        |> text("Correct or exclude invoices outside this working period")

      {:error, reason} when reason in [:no_active_sales, :invalid_sales_data] ->
        conn
        |> put_status(:unprocessable_entity)
        |> text("Sales workings are unavailable until the sales data is ready")

      {:error, _reason} ->
        conn
        |> put_status(:not_found)
        |> text("Not found")
    end
  end

  defp same_period?(projection, period),
    do: Nila.Gst.Sales.Gstr1.Readiness.period_issues(projection.active_invoices, period) == []

  defp require_active_sales(%{active_invoices: []}), do: {:error, :no_active_sales}
  defp require_active_sales(_projection), do: :ok

  def tally_download(conn, %{"client_id" => client_id, "period" => period}) do
    org_id = conn.assigns.current_scope.current_org.id

    with {:ok, sales_month} <- SalesMonths.get_by_period(org_id, client_id, period),
         {:ok, client} <- Clients.get_client(org_id, client_id),
         {:ok, xml} <- TallyPrime.build(tally_projection(sales_month, period)) do
      filename = "sales_#{client.gstin || client.id}_#{period}_tally.xml"

      conn
      |> put_resp_content_type("application/xml")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
      |> send_resp(200, xml)
    else
      {:error, reason} when reason in [:no_active_sales, :invalid_sales_data] ->
        conn
        |> put_status(:unprocessable_entity)
        |> text(tally_export_error(reason))

      {:error, _reason} ->
        conn
        |> put_status(:not_found)
        |> text("Not found")
    end
  end

  def sales_bills_tally_download(conn, %{
        "client_id" => client_id,
        "batch_ref" => batch_ref
      }) do
    org_id = conn.assigns.current_scope.current_org.id

    with {:ok, dumps} <- TallyPacket.fetch(org_id, client_id, batch_ref),
         {:ok, client} <- Clients.get_client(org_id, client_id),
         {:ok, xml} <- TallyPacket.build_xml(dumps) do
      filename = "sales_#{client.gstin || client.id}_tally.xml"

      conn
      |> put_resp_content_type("application/xml")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
      |> send_resp(200, xml)
    else
      {:error, reason} when reason in [:no_active_sales, :invalid_sales_data] ->
        conn
        |> put_status(:unprocessable_entity)
        |> text(tally_export_error(reason))

      {:error, _reason} ->
        conn
        |> put_status(:not_found)
        |> text("Not found")
    end
  end

  def sales_bills_gstr1_download(conn, %{
        "client_id" => client_id,
        "batch_ref" => batch_ref
      }) do
    org_id = conn.assigns.current_scope.current_org.id

    with {:ok, dumps} <- TallyPacket.fetch(org_id, client_id, batch_ref),
         {:ok, client} <- Clients.get_client(org_id, client_id),
         {:ok, export} <- Gstr1Packet.build(dumps, client.gstin) do
      filename = "gstr1_#{client.gstin}_#{export.period}.json"

      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
      |> send_resp(200, Jason.encode!(export.return))
    else
      {:error, reason} when reason in [:invalid_sales_data, :mixed_periods] ->
        conn
        |> put_status(:unprocessable_entity)
        |> text(gstr1_packet_error(reason))

      {:error, _reason} ->
        conn
        |> put_status(:not_found)
        |> text("Not found")
    end
  end

  # Month-level posting used approval IDs as job identity. Keep this old URL
  # harmless; the sales-bills workflow owns posting and sent-voucher protection.
  def tally_export(conn, %{"client_id" => client_id, "period" => period}) do
    org_id = conn.assigns.current_scope.current_org.id

    case SalesMonths.get_by_period(org_id, client_id, period) do
      {:ok, _sales_month} ->
        conn
        |> put_flash(:info, "Open the sales bills to send vouchers to Tally.")
        |> redirect(to: ~p"/gst/#{client_id}/#{period}/sales")

      {:error, _reason} ->
        conn |> put_status(:not_found) |> text("Not found")
    end
  end

  def evidence(conn, %{"client_id" => client_id, "period" => period, "basename" => basename}) do
    org_id = conn.assigns.current_scope.current_org.id

    case SalesMonths.fetch_evidence(org_id, client_id, period, basename) do
      {:ok, bytes} ->
        conn
        |> put_resp_content_type(content_type(basename))
        |> put_resp_header("cache-control", "private, max-age=300")
        |> send_resp(200, bytes)

      {:error, _reason} ->
        conn
        |> put_status(:not_found)
        |> text("Not found")
    end
  end

  defp tally_projection(sales_month, period) do
    sales_month
    |> SalesResolutions.effective_workings()
    |> Map.put(:period, period)
  end

  defp tally_export_error(:no_active_sales), do: "There are no active sales vouchers to export"

  defp tally_export_error(:invalid_sales_data),
    do: "Sales data contains fields Tally cannot import"

  defp gstr1_packet_error(:invalid_sales_data),
    do: "Resolve the GST issues before downloading the GSTR-1 JSON"

  defp gstr1_packet_error(:mixed_periods),
    do: "This batch contains invoices from more than one filing period"

  defp workbook_status(%{state: "filed"}), do: "Filed"

  defp workbook_status(_sales_month), do: "Working draft"

  defp export_error(:invalid_period), do: "Invalid filing period"
  defp export_error(:unsupported_period), do: "Winman export currently supports FY 2026-27"
  defp export_error(:invalid_b2b_data), do: "B2B data contains fields Winman cannot import"
  defp export_error(:too_many_rows), do: "Winman B2B export supports at most 995 rows"

  defp content_type(basename) do
    case Path.extname(basename) do
      ".png" -> "image/png"
      ext when ext in [".jpg", ".jpeg"] -> "image/jpeg"
      ".webp" -> "image/webp"
      _ -> "application/octet-stream"
    end
  end
end
