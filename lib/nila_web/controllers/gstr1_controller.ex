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
  alias Nila.Gst.Sales.Months, as: SalesMonths
  alias Nila.Gst.Sales.Resolutions, as: SalesResolutions

  def return_json(conn, %{"client_id" => client_id, "period" => period}) do
    org_id = conn.assigns.current_scope.current_org.id

    case SalesMonths.get_by_period(org_id, client_id, period) do
      {:ok, sales_month} ->
        derived = SalesResolutions.effective_workings(sales_month).derived
        filename = "gstr1_#{derived["gstin"]}_#{period}.json"

        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
        |> send_resp(200, Jason.encode!(derived))

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
         {:ok, workbook} <-
           WinmanGstr1.build(SalesResolutions.effective_workings(sales_month), client, period) do
      filename = "gstr1_#{client.gstin || client.id}_#{period}_winman_b2b.xlsm"

      conn
      |> put_resp_content_type("application/vnd.ms-excel.sheet.macroEnabled.12", nil)
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
      |> send_resp(200, workbook)
    else
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

  def tally_export(conn, %{"client_id" => client_id, "period" => period}) do
    org_id = conn.assigns.current_scope.current_org.id

    case SalesMonths.get_by_period(org_id, client_id, period) do
      {:ok, sales_month} ->
        projection =
          sales_month
          |> SalesResolutions.effective_workings()
          |> Map.put(:period, period)

        conn
        |> tally_result(TallyPrime.push(projection))
        |> redirect(to: ~p"/gst/#{client_id}/#{period}")

      {:error, _reason} ->
        conn
        |> put_status(:not_found)
        |> text("Not found")
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

  defp tally_result(conn, {:ok, result}) do
    imported = result.created + result.altered + result.combined
    duplicate = if result.ignored == 1, do: "duplicate", else: "duplicates"

    message =
      "Tally imported #{imported} sales #{plural(imported, "voucher")}." <>
        if(result.ignored > 0, do: " Ignored #{result.ignored} #{duplicate}.", else: "")

    put_flash(conn, :info, message)
  end

  defp tally_result(conn, {:error, {:partial_import, result}}) do
    imported = result.created + result.altered + result.combined

    put_flash(
      conn,
      :error,
      "Tally acknowledged only part of the batch (#{imported} imported, #{result.ignored} ignored). Check Tally before retrying."
    )
  end

  defp tally_result(conn, {:error, {:tally_rejected, result}}) do
    imported = result.created + result.altered + result.combined

    detail =
      case result.line_errors do
        [] ->
          failures = max(result.errors, result.exceptions)
          "Tally rejected the import with #{failures} #{plural(failures, "error")}."
        errors -> errors |> Enum.join("; ") |> String.slice(0, 300)
      end

    prefix = if imported > 0, do: "Tally imported #{imported} before failing. ", else: ""
    put_flash(conn, :error, prefix <> detail)
  end

  defp tally_result(conn, {:error, :no_active_sales}),
    do: put_flash(conn, :error, "There are no active sales vouchers to send to Tally")

  defp tally_result(conn, {:error, :invalid_sales_data}),
    do: put_flash(conn, :error, "Sales data contains fields Tally cannot import")

  defp tally_result(conn, {:error, {:http_status, status}}),
    do: put_flash(conn, :error, "Tally returned HTTP #{status}")

  defp tally_result(conn, {:error, _reason}),
    do:
      put_flash(
        conn,
        :error,
        "TallyPrime did not confirm the import. Check Tally before retrying."
      )

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"

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
