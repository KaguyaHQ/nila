defmodule NilaWeb.Gst.PurchaseWorkspaceJson do
  @moduledoc "Read-only purchase workspace projection; decisions stay in the existing review flow."
  alias Nila.Accounts.Policy
  alias Nila.Gst.Intake.Dumps
  alias Nila.Gst.Portal.Gstr2b
  alias Nila.Gst.Purchase.{PortalImport, Reconciliation}
  alias NilaWeb.Gst.PurchaseWorkspace, as: Workspace

  def build(scope, data, period, date, params) do
    client = data.client
    base = Workspace.overview_path(client.id, period)
    filter = Workspace.normalize_filter(params["filter"] || "register")
    query = String.slice(params["q"] || "", 0, 200)
    overview = Workspace.overview(data.workings, data.items)

    dumps =
      Dumps.list(scope.current_org.id, client.id, period)
      |> Enum.filter(&(&1.kind in ~w(purchase gstr2b)))

    statement = Gstr2b.saved(scope.current_org.id, client.id, period)
    imported = PortalImport.current_dump(statement, dumps)

    books? =
      overview.books_count > 0 or
        Enum.any?(dumps, &(&1.kind == "purchase" and &1.status == "extracted"))

    portal? =
      overview.portal_count > 0 or
        Enum.any?(dumps, &(&1.kind == "gstr2b" and &1.status == "extracted"))

    processing = Enum.any?(dumps, &(&1.status in ~w(received extracting)))

    needs_import =
      not is_nil(statement) and not is_nil(statement.fetched_at) and
        (is_nil(imported) or imported.status == "failed")

    unresolved = Dumps.unresolved?(dumps, "purchase") or Dumps.unresolved?(dumps, "gstr2b")
    can_edit = Policy.can?(scope, :edit_records) and not data.signed_off?

    complete =
      books? and portal? and not processing and not needs_import and not unresolved and
        overview.remaining == 0 and overview.pending_tax == 0 and overview.stale_count == 0

    rows =
      if filter in ~w(register gstr2b) do
        source_rows(data, period, filter, query)
      else
        data.items
        |> Workspace.filter(filter, query)
        |> Enum.map(&review_row(&1, client.id, period, filter, query))
      end

    carried =
      if filter in ~w(all treatment carried needs_review) do
        data.carried_cases
        |> Workspace.filter_carried(query)
        |> Enum.map(fn line ->
          %{
            id: to_string(line.case_id),
            number: line.invoice_number || "—",
            vendor: line.vendor || "—",
            tax: Workspace.money(Enum.sum(Map.values(line.outstanding_heads))),
            treatment: treatment(line.treatment),
            stale: line.treatment_stale?,
            review_url: review_list_path(client.id, period, "carried", query)
          }
        end)
      else
        []
      end

    %{
      client: %{id: client.id, name: client.name, gstin: client.gstin},
      clients:
        Enum.map(Nila.Clients.list_clients(scope.current_org.id), &%{id: &1.id, name: &1.name}),
      user: %{name: scope.user.name, org: scope.current_org.name},
      period: period,
      month_label: Calendar.strftime(date, "%B %Y"),
      can_edit: can_edit,
      signed_off: data.signed_off?,
      lock_reason:
        cond do
          data.signed_off? -> "This month is signed off or filed. Review is read-only."
          not can_edit -> "Your role can view and export purchases but cannot change them."
          true -> nil
        end,
      processing: processing,
      inputs: %{
        books: %{
          present: books?,
          count: overview.books_count,
          tax: Workspace.money(overview.books_tax)
        },
        portal: %{
          present: portal?,
          count: overview.portal_count,
          tax: Workspace.money(overview.portal_tax),
          fetching: Gstr2b.fetching?(statement),
          needs_import: needs_import
        }
      },
      overview: %{
        complete: complete,
        comparison_available: books? and portal?,
        remaining: overview.remaining,
        buckets:
          Enum.map(
            overview.buckets,
            &%{
              id: &1.id,
              label: &1.label,
              count: &1.count,
              books_tax: Workspace.money(&1.books),
              portal_tax: Workspace.money(&1.portal)
            }
          ),
        itc: %{
          recorded: overview.treatment_recorded?,
          claim: Workspace.money(overview.claim_tax),
          later: Workspace.money(overview.later_tax),
          excluded: Workspace.money(overview.excluded_tax),
          pending: Workspace.money(overview.pending_tax),
          carried_count: overview.carried_count,
          stale_count: overview.stale_count
        }
      },
      filters: Enum.map(Workspace.filters(), fn {id, label} -> %{id: id, label: label} end),
      filter: filter,
      q: query,
      rows: rows,
      carried: carried,
      working: %{
        enabled: not is_nil(data.workings) and Policy.can?(scope, :export),
        url: base <> "/workings.xlsx",
        status:
          cond do
            data.signed_off? -> "Recorded sign-off snapshot"
            complete -> "Ready for review"
            true -> "Draft working"
          end,
        reason:
          cond do
            not Policy.can?(scope, :export) -> "Your role cannot download workings."
            is_nil(data.workings) -> "Fetch GSTR-2B to prepare a working."
            true -> nil
          end
      },
      links: %{
        portal: "/app" <> base,
        review: review_list_path(client.id, period, "needs_review", ""),
        treatment: review_list_path(client.id, period, "treatment", ""),
        carried: review_list_path(client.id, period, "carried", "")
      },
      notice:
        cond do
          data.signed_off? ->
            "Showing the recorded working. Open purchase review to inspect its evidence."

          processing ->
            "Inputs are still processing. The current working may be incomplete."

          unresolved ->
            "An upload needs attention. Open purchase review to resolve it before finishing reconciliation."

          needs_import ->
            "A fetched GSTR-2B statement is waiting to enter reconciliation. Open purchase review to import it."

          not books? and not portal? ->
            "Fetch GSTR-2B to start reviewing purchases."

          not books? ->
            "Books comparison is not available. You can review the GSTR-2B documents and set ITC treatment."

          not portal? ->
            "Fetch and import GSTR-2B to compare it with purchase records."

          true ->
            "Matching does not mean ITC has been claimed."
        end
    }
  end

  defp source_rows(data, period, filter, query) do
    query_lower = query |> String.trim() |> String.downcase()

    Workspace.source_rows(data.workings, filter)
    |> Enum.with_index()
    |> Enum.filter(fn {row, _} ->
      text = Enum.map_join(~w(vendor_name vendor_gstin invoice_number), " ", &(row[&1] || ""))
      String.contains?(String.downcase(text), query_lower)
    end)
    |> Enum.map(fn {row, index} ->
      item =
        Enum.find(data.items, fn item ->
          item.kind != :itc and
            if(filter == "register",
              do: Enum.any?(item.books_members, &(&1["id"] == row["id"])),
              else:
                Enum.any?(
                  item.counterparts,
                  &(Reconciliation.gstr2b_ref(&1) == Reconciliation.gstr2b_ref(row))
                )
            )
        end)

      %{
        id: "#{filter}-#{index}",
        number: row["invoice_number"] || "—",
        date: row["invoice_date"],
        vendor: row["vendor_name"] || "—",
        gstin: row["vendor_gstin"],
        document_type: row["document_type"] || "invoice",
        tax: Workspace.money(Workspace.source_tax(row)),
        tax_paise: Workspace.source_tax(row),
        status: if(item, do: Workspace.label(item), else: "Source record"),
        reason: if(item, do: item.reason),
        review_url: if(item, do: review_path(data.client.id, period, item.id, filter, query))
      }
    end)
  end

  defp review_row(item, client_id, period, filter, query) do
    row = item.books || List.first(item.counterparts) || %{}

    %{
      id: item.id,
      number: item.invoice_number || "—",
      date: row["invoice_date"],
      vendor: item.vendor || "—",
      gstin: row["vendor_gstin"],
      document_type: item.document_type || "invoice",
      tax: Workspace.money(item.tax_paise),
      tax_paise: item.tax_paise,
      status: Workspace.label(item),
      reason: item.reason,
      review_url: review_path(client_id, period, item.id, filter, query)
    }
  end

  defp treatment("claim"), do: "Claim this month"
  defp treatment("later"), do: "Claim later"
  defp treatment("exclude"), do: "Excluded from ITC"
  defp treatment("split"), do: "Split treatment"
  defp treatment(_), do: "Unresolved"

  defp review_list_path(client_id, period, filter, q),
    do:
      Workspace.overview_path(client_id, period) <>
        "/review?" <> URI.encode_query(%{filter: filter, q: q})

  defp review_path(client_id, period, id, filter, q),
    do:
      Workspace.overview_path(client_id, period) <>
        "/review/" <> URI.encode_www_form(id) <> "?" <> URI.encode_query(%{filter: filter, q: q})
end
