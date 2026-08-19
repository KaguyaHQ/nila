defmodule NilaWeb.Gstr1Controller do
  @moduledoc """
  Serves a worked sales month's artifacts through the org-membership check:
  the portal-shaped GSTR-1 JSON (the file an auditor uploads to the portal)
  and the scanned page evidence. Tenant comes from `current_scope`, never a
  URL param — same discipline as `GstEvidenceController`.
  """
  use NilaWeb, :controller

  alias Nila.Clients
  alias Nila.Gst.Filing.{Signoffs, TallyPrime, WinmanGstr1}
  alias Nila.Gst.Sales.Months, as: SalesMonths
  alias Nila.Gst.Sales.Resolutions, as: SalesResolutions
  alias Nila.TallyDevices
  alias Nila.TallyJobs
  alias Nila.TallySync

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

  def tally_export(
        conn,
        %{
          "client_id" => client_id,
          "period" => period,
          "tally" => %{"company_id" => company_id}
        }
      ) do
    org_id = conn.assigns.current_scope.current_org.id

    case SalesMonths.get_by_period(org_id, client_id, period) do
      {:ok, sales_month} ->
        conn
        |> enqueue_tally_result(sales_month, period, company_id)
        |> redirect(to: ~p"/gst/#{client_id}/#{period}")

      {:error, _reason} ->
        conn
        |> put_status(:not_found)
        |> text("Not found")
    end
  end

  def tally_export(conn, %{"client_id" => client_id, "period" => period}) do
    org_id = conn.assigns.current_scope.current_org.id

    case SalesMonths.get_by_period(org_id, client_id, period) do
      {:ok, _sales_month} ->
        conn
        |> put_flash(:error, "Choose an open Tally company before sending.")
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

  defp tally_projection(sales_month, period) do
    sales_month
    |> SalesResolutions.effective_workings()
    |> Map.put(:period, period)
  end

  defp tally_export_error(:no_active_sales), do: "There are no active sales vouchers to export"

  defp tally_export_error(:invalid_sales_data),
    do: "Sales data contains fields Tally cannot import"

  defp enqueue_tally_result(conn, sales_month, period, company_id) do
    org_id = conn.assigns.current_scope.current_org.id

    with {company_id, ""} <- Integer.parse(company_id),
         {:ok, company} <-
           TallyDevices.get_open_company(org_id, company_id, sales_month.client_id),
         {:ok, signoff} <- Signoffs.latest_gstr1_signoff(sales_month.id),
         {:ok, items} <-
           TallyPrime.build_items_for_company(tally_projection(sales_month, period), company.name) do
      {ready, blocked} = partition_ready_items(company.id, items)

      case enqueue_ready_items(company, signoff.id, ready) do
        {:ok, jobs} ->
          conn
          |> maybe_put_tally_jobs_flash(jobs, company.name)
          |> maybe_put_blocked_vouchers_flash(blocked)

        {:error, reason} ->
          tally_enqueue_error(conn, reason)
      end
    else
      :error ->
        put_flash(conn, :error, "Choose an open Tally company before sending.")

      {:error, :not_found} ->
        put_flash(conn, :error, "That Tally company is no longer available.")

      {:error, :no_active_sales} ->
        put_flash(conn, :error, "There are no active sales vouchers to send to Tally.")

      {:error, :invalid_sales_data} ->
        put_flash(conn, :error, "Sales data contains fields Tally cannot import.")

      {:error, _reason} ->
        put_flash(conn, :error, "Nila could not queue the Tally import.")

      _invalid ->
        put_flash(conn, :error, "Choose an open Tally company before sending.")
    end
  end

  defp partition_ready_items(company_id, items) do
    missing =
      company_id
      |> TallySync.missing_ledgers(Enum.flat_map(items, & &1.ledger_names))
      |> MapSet.new(&String.downcase/1)

    Enum.reduce(items, {[], []}, fn item, {ready, blocked} ->
      missing_for_item =
        Enum.filter(item.ledger_names, &MapSet.member?(missing, String.downcase(&1)))

      if missing_for_item == [] do
        {[item | ready], blocked}
      else
        {ready, [Map.put(item, :missing_ledgers, missing_for_item) | blocked]}
      end
    end)
    |> then(fn {ready, blocked} -> {Enum.reverse(ready), Enum.reverse(blocked)} end)
  end

  defp enqueue_ready_items(_company, _signoff_id, []), do: {:ok, []}

  defp enqueue_ready_items(company, signoff_id, items) do
    TallyJobs.enqueue_vouchers(company, items,
      source_prefix: tally_source_prefix(signoff_id, company.id)
    )
  end

  defp maybe_put_tally_jobs_flash(conn, [], _company), do: conn

  defp maybe_put_tally_jobs_flash(conn, jobs, company),
    do: put_flash(conn, :info, tally_jobs_message(jobs, company))

  defp maybe_put_blocked_vouchers_flash(conn, []), do: conn

  defp maybe_put_blocked_vouchers_flash(conn, blocked) do
    invoices = Enum.map_join(blocked, ", ", & &1.invoice_number)

    ledgers =
      blocked
      |> Enum.flat_map(& &1.missing_ledgers)
      |> Enum.uniq()
      |> Enum.join(", ")

    put_flash(
      conn,
      :error,
      "Held back #{length(blocked)} #{plural(length(blocked), "voucher")} (#{invoices}). Resolve #{if(length(blocked) == 1, do: "its", else: "their")} missing Tally ledgers, sync the company, then retry: #{ledgers}."
    )
  end

  defp tally_enqueue_error(conn, :batch_too_large) do
    put_flash(
      conn,
      :error,
      "This voucher is too large to send directly. Download the Tally XML instead."
    )
  end

  defp tally_enqueue_error(conn, _reason),
    do: put_flash(conn, :error, "Nila could not queue the Tally import.")

  defp tally_jobs_message(jobs, company) do
    queued = Enum.count(jobs, fn {_job, disposition} -> disposition in [:created, :retried] end)
    existing = length(jobs) - queued

    cond do
      queued > 0 and existing > 0 ->
        "Queued #{queued} sales #{plural(queued, "voucher")} for #{company}; #{existing} already had a result or was in progress."

      queued > 0 ->
        "Queued #{queued} sales #{plural(queued, "voucher")} for #{company}."

      true ->
        "All #{existing} sales #{plural(existing, "voucher")} already have a result or are in progress for #{company}."
    end
  end

  defp tally_source_prefix(signoff_id, company_id),
    do: "gstr1:#{signoff_id}:company:#{company_id}:voucher:"

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
