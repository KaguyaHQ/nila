defmodule NilaWeb.SalesMonthChecksController do
  use NilaWeb, :controller
  alias Nila.Accounts.Policy
  alias Nila.Clients
  alias Nila.Gst.Intake.Dumps
  alias Nila.Gst.Sales.{Months, SourcePacket, Workings}
  alias Nila.Gst.Sales.Review.{MonthChecks, Resolutions}

  def show(conn, params), do: dispatch(conn, params, :show)
  def decision(conn, params), do: dispatch(conn, params, :decision)

  defp dispatch(conn, %{"client_id" => id, "period" => period} = params, action) do
    scope = conn.assigns[:current_scope]

    with :ok <- access(scope, action),
         {client_id, ""} when client_id > 0 and client_id <= 9_223_372_036_854_775_807 <-
           Integer.parse(id),
         true <- Regex.match?(~r/\A\d{4}-\d{2}\z/, period),
         {:ok, date} <- Date.from_iso8601(period <> "-01"),
         true <- date.year >= 2017,
         {:ok, client} <- Clients.get_client(scope.current_org.id, client_id),
         {:ok, month} <- Months.get_by_period(scope.current_org.id, client.id, period),
         :ok <- perform(action, month, scope, params),
         {:ok, month} <- Months.get_by_period(scope.current_org.id, client.id, period) do
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> json(project(scope, client, month))
    else
      {:error, :unauthenticated} ->
        error(conn, 401, "Sign in to continue.")

      {:error, :forbidden} ->
        error(conn, 403, "Your role cannot change monthly checks.")

      {:error, :not_found} ->
        error(conn, 404, "This sales month is not available.")

      {:error, :filed} ->
        error(conn, 409, "This month is filed. Its checks cannot be changed.")

      {:error, :stale} ->
        error(conn, 409, "The sales evidence changed. Refresh and check it again.")

      {:error, :unsupported_confirmation} ->
        error(conn, 422, "This check cannot be confirmed here. Review its source invoices.")

      _ ->
        error(conn, 400, "Choose a valid client, month and check.")
    end
  end

  defp access(nil, _), do: {:error, :unauthenticated}
  defp access(%{user: %{confirmed_at: nil}}, _), do: {:error, :forbidden}
  defp access(%{current_org: nil}, _), do: {:error, :forbidden}
  defp access(_, :show), do: :ok

  defp access(scope, _),
    do: if(Policy.can?(scope, :edit_records), do: :ok, else: {:error, :forbidden})

  defp perform(:show, _, _, _), do: :ok

  defp perform(:decision, month, scope, params) do
    case Resolutions.decide_month_check(
           month,
           scope,
           params["target"],
           params["basis"],
           params["action"]
         ) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp project(scope, client, month) do
    filed? = not is_nil(month.filed_at)
    can_edit = Policy.can?(scope, :edit_records) and not filed?
    dumps = Dumps.effective(month.org_id, client.id, month.period, "sales")
    base = "/gst/#{client.id}/#{month.period}/sales"
    latest = Resolutions.latest_decisions(month.id)

    checks =
      Resolutions.effective_workings(month).issues
      |> Enum.filter(&MonthChecks.supported?/1)
      |> Enum.map(fn issue ->
        {title, label, explanation} = wording(issue["code"])

        sources =
          dumps
          |> Enum.filter(&(is_nil(issue["dump_id"]) or issue["dump_id"] == &1.id))
          |> Enum.flat_map(fn dump ->
            dump.file_keys
            |> Enum.with_index()
            |> Enum.map(fn {_key, index} ->
              %{
                id: dump.id,
                name: SourcePacket.original_name(dump),
                url: "/gst/#{client.id}/#{month.period}/original/#{dump.id}/#{index}"
              }
            end)
          end)

        %{
          target: Workings.issue_key(issue),
          code: issue["code"],
          title: title,
          message: issue["message"],
          status: issue["status"] || "open",
          basis: MonthChecks.request_basis(issue, latest[Workings.issue_key(issue)]),
          confirm_label: label,
          confirmation_text: explanation,
          sources: sources,
          action_paths: [
            %{label: "Document series", path: base <> "/sections/documents"},
            %{label: "Review invoices", path: base <> "/register"},
            %{label: "Add missing PDFs", path: base <> "/upload"}
          ]
        }
      end)

    %{
      client: %{id: client.id, name: client.name, gstin: client.gstin},
      period: month.period,
      can_edit: can_edit,
      lock_reason:
        cond do
          filed? -> "This month is filed. Its checks cannot be changed."
          not can_edit -> "Your role can view these checks but cannot change them."
          true -> nil
        end,
      checks: checks
    }
  end

  defp wording("sequence_gaps"),
    do:
      {"Missing document numbers", "Confirm these numbers were cancelled",
       "I checked the document series and cancellation records. These missing numbers are genuine cancellations. If bills are missing, add them first; if numbers were read incorrectly, correct the invoices."}

  defp wording("pages_unaccounted"),
    do:
      {"Pages with no extracted invoice", "Confirm no bill was missed on these pages",
       "I opened the original pages listed above and checked that no sales invoice, credit note or debit note was missed. If a bill was missed, add or correct its source before confirming."}

  defp wording("evidence_unavailable"),
    do:
      {"Rendered bill pages unavailable", "Confirm invoices match the original",
       "I opened the original file and checked its extracted invoices against it. This confirmation records that check; it does not restore the missing page images."}

  defp error(conn, status, message),
    do:
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_status(status)
      |> json(%{error: message})
end
