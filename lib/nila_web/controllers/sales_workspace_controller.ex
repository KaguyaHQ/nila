defmodule NilaWeb.SalesWorkspaceController do
  use NilaWeb, :controller

  alias Nila.Clients
  alias Nila.Gst.Intake.Dumps
  alias Nila.Gst.Sales.{Invoice, Months, Review}
  alias Nila.Gst.Sales.Review.{Resolutions, Values}
  alias NilaWeb.Components.Gst.Month.{Helpers, SalesWorkspace}

  def show(conn, %{"client_id" => id, "period" => period}) do
    scope = conn.assigns.current_scope

    with :ok <- access(scope),
         {:ok, client_id} <- client_id(id),
         {:ok, date} <- period_date(period),
         {:ok, client} <- Clients.get_client(scope.current_org.id, client_id) do
      org_id = scope.current_org.id

      {month, workings} =
        case Months.get_by_period(org_id, client.id, period) do
          {:ok, month} ->
            {month, Resolutions.effective_workings(month)}

          {:error, :not_found} ->
            {nil, %{source_invoices: [], active_invoices: [], issues: [], derived: nil}}
        end

      review = Review.build(workings)
      active_ids = MapSet.new(workings.active_invoices, & &1["id"])
      review_ids = MapSet.new(review.needs_you, & &1.source_id)
      base = "/gst/#{client.id}/#{period}/sales"
      dumps = Dumps.list(org_id, client.id, period) |> Enum.filter(&(&1.kind == "sales"))
      totals = if workings.derived, do: Values.filed_totals(workings.derived)

      rows =
        Enum.map(workings.source_invoices, fn invoice ->
          item = Enum.find(review.all, &(&1.source_id == invoice["id"]))

          issues =
            if item, do: Enum.filter(item.actionable_issues, &(&1["status"] == "open")), else: []

          figures = Invoice.extracted_totals(invoice)

          status =
            cond do
              not MapSet.member?(active_ids, invoice["id"]) -> "excluded"
              MapSet.member?(review_ids, invoice["id"]) -> "needs_review"
              true -> "ready"
            end

          %{
            id: invoice["id"],
            number: invoice["invoice_number"] || "—",
            date: invoice["invoice_date"],
            customer: invoice["buyer_name"] || "—",
            gstin: invoice["buyer_gstin"],
            status: status,
            taxable: Helpers.rupees(figures.taxable),
            tax: Helpers.rupees(figures.tax),
            reason:
              case issues do
                [issue | _] -> NilaWeb.Gst.SalesIssuePresentation.register_reason(issue)
                [] -> nil
              end,
            path:
              if(status != "excluded",
                do:
                  "/gst/#{client.id}/#{period}/sales/invoices/#{URI.encode_www_form(invoice["id"])}"
              )
          }
        end)

      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> json(%{
        client: %{id: client.id, name: client.name},
        clients: Enum.map(Clients.list_clients(org_id), &%{id: &1.id, name: &1.name}),
        user: %{name: scope.user.name, org: scope.current_org.name},
        period: period,
        month_label: Calendar.strftime(date, "%B %Y"),
        can_upload: Nila.Accounts.Policy.can?(scope, :edit_records),
        deadline: Nila.Gst.Filing.Calendar.due_dates(period).gstr1,
        invoice_count: length(workings.active_invoices),
        review_count: length(review.needs_you),
        month_issue_count: review.month_issue_count,
        taxable: Helpers.rupees(totals && totals.taxable),
        tax: Helpers.rupees(totals && totals.tax),
        rows: rows,
        sections: SalesWorkspace.summary_rows(workings, client, period),
        details:
          NilaWeb.Gst.SalesWorkspaceDetails.build(workings, client, period,
            filed: month != nil and month.filed_at != nil
          ),
        exports:
          NilaWeb.Gst.SalesExportState.build(scope, month, workings, dumps, client, period),
        uploads: %{
          files: Enum.sum(Enum.map(dumps, &length(&1.file_keys))),
          unfinished: Dumps.unresolved?(dumps, "sales")
        },
        links: %{
          upload:
            "/gst/upload?" <>
              URI.encode_query(%{client_id: client.id, period: period, kind: "sales"}),
          uploads: base <> "/uploads",
          working: base,
          purchases: "/gst/#{client.id}/#{period}/purchases"
        }
      })
    else
      {:error, :unauthenticated} -> error(conn, 401, "Sign in to continue.")
      {:error, :forbidden} -> error(conn, 403, "Verify your account and join a firm to continue.")
      {:error, :invalid} -> error(conn, 400, "Choose a valid client and month.")
      {:error, :not_found} -> error(conn, 404, "This client is not available.")
    end
  end

  defp access(nil), do: {:error, :unauthenticated}
  defp access(%{user: %{confirmed_at: nil}}), do: {:error, :forbidden}
  defp access(%{current_org: nil}), do: {:error, :forbidden}
  defp access(_), do: :ok

  defp client_id(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 and id <= 9_223_372_036_854_775_807 -> {:ok, id}
      _ -> {:error, :invalid}
    end
  end

  defp period_date(period) do
    with true <- Regex.match?(~r/\A\d{4}-\d{2}\z/, period),
         {:ok, date} <- Date.from_iso8601(period <> "-01"),
         true <- date.year >= 2017 do
      {:ok, date}
    else
      _ -> {:error, :invalid}
    end
  end

  defp error(conn, status, message),
    do:
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_status(status)
      |> json(%{error: message})
end
