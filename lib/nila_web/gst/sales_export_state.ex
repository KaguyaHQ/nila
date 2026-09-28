defmodule NilaWeb.Gst.SalesExportState do
  @moduledoc "Download availability shared by the sales workspace and portal JSON endpoint."

  alias Nila.Accounts.Policy
  alias Nila.Gst.{Issues, Sales.Workings}
  alias Nila.Gst.Intake.Dumps
  alias Nila.Gst.Sales.{Review, Gstr1.Readiness}

  def json_ready?(%{filed_at: filed_at}, _workings) when not is_nil(filed_at), do: true
  def json_ready?(_month, workings), do: Workings.reviewable?(workings.issues)

  def build(scope, month, workings, dumps, client, period) do
    base = "/gst/#{client.id}/#{period}/sales"

    common =
      cond do
        not Policy.can?(scope, :export) ->
          [
            %{
              id: "permission",
              message: "Your role cannot download working files.",
              path: nil,
              external: false
            }
          ]

        month == nil or not Workings.has_return_data?(workings) ->
          [
            %{
              id: "empty",
              message: "Add sales files to make downloads available.",
              path: base <> "/upload",
              external: false
            }
          ]

        Dumps.unresolved?(dumps, "sales") ->
          [
            %{
              id: "uploads",
              message: "Finish reading or resolve failed uploads before exporting.",
              path: base <> "/uploads",
              external: false
            }
          ]

        Readiness.period_issues(workings.active_invoices, period) != [] ->
          [
            %{
              id: "period",
              message: "Correct or exclude invoices outside this working period.",
              path: base <> "/register",
              external: false
            }
          ]

        true ->
          []
      end

    required =
      if json_ready?(month, workings),
        do: [],
        else: required_blockers(workings, client.id, period)

    json_blockers = common ++ required
    draft? = required != []

    %{
      status:
        cond do
          common != [] ->
            "Downloads need attention."

          draft? ->
            "The draft working is available. Resolve the remaining checks before downloading GSTR-1 JSON."

          month && month.filed_at ->
            "Filed working files are available."

          true ->
            "Working files are ready for review."
        end,
      items: [
        %{
          id: "workings",
          label: "GST sales working",
          format: "XLSX",
          url: "/gstr1/#{client.id}/#{period}/workings.xlsx",
          enabled: common == [],
          reason: first_message(common)
        },
        %{
          id: "json",
          label: "GSTR-1",
          format: "JSON",
          url: "/gstr1/#{client.id}/#{period}/return.json",
          enabled: json_blockers == [],
          reason: first_message(json_blockers)
        }
      ],
      blockers: Enum.uniq_by(json_blockers, & &1.id)
    }
  end

  defp required_blockers(workings, client_id, period) do
    review = Review.build(workings)

    report_ids =
      for invoice <- workings.active_invoices, invoice["return_report_dump_id"], do: invoice["id"]

    report_blockers =
      Nila.Gst.Sales.ReportReview.build(workings)
      |> Enum.map(fn task ->
        %{
          id: task["id"],
          message: task["title"],
          path: report_task_path(task, client_id, period),
          external: false
        }
      end)

    other_blockers =
      workings.issues
      |> Issues.normalize_all()
      |> Enum.filter(&(Workings.blocking?(&1) or (&1["status"] == "open" and Issues.gating?(&1))))
      |> Enum.reject(fn issue ->
        report_ids != [] and
          (issue["code"] == "return_report_invalid" or issue["source_id"] in report_ids)
      end)
      |> Enum.map(fn issue ->
        target = Workings.issue_key(issue)

        owners =
          Enum.filter(review.all, fn item ->
            Enum.any?(item.actionable_issues, &(Workings.issue_key(&1) == target))
          end)

        {path, external?} =
          case owners do
            [item] ->
              {"/gst/#{client_id}/#{period}/sales/invoices/#{URI.encode_www_form(item.source_id)}",
               false}

            [] ->
              {if(Nila.Gst.Sales.Review.MonthChecks.supported?(issue),
                 do:
                   "/gst/#{client_id}/#{period}/sales?" <>
                     URI.encode_query(%{"returnTask" => target})
               ), false}

            _ ->
              {"/gst/#{client_id}/#{period}/sales/register", false}
          end

        message =
          case owners do
            [item] ->
              "#{item.invoice["invoice_number"] || "Invoice"}: #{NilaWeb.Gst.SalesIssuePresentation.register_reason(issue)}"

            _ ->
              issue["message"] || "Review this sales check."
          end

        %{
          id: target,
          message: message,
          path: path,
          external: external?
        }
      end)

    case report_blockers ++ other_blockers do
      [] ->
        [
          %{
            id: "remaining",
            message: "Resolve the remaining sales checks.",
            path: "/gst/#{client_id}/#{period}/sales/register?filter=needs_review",
            external: false
          }
        ]

      blockers ->
        blockers
    end
  end

  defp report_task_path(task, client_id, period) do
    base = "/gst/#{client_id}/#{period}/sales"

    case task["kind"] do
      "invoice" ->
        base <>
          "/register?" <>
          URI.encode_query(%{
            "selected" => List.first(task["source_ids"] || []),
            "filter" => "needs_review"
          })

      "notes" ->
        base <>
          "/register?" <>
          URI.encode_query(%{"returnTask" => task["id"], "filter" => "needs_review"})

      "uploads" ->
        base <> "/uploads"

      _ ->
        base <> "?" <> URI.encode_query(%{"returnTask" => task["id"]})
    end
  end

  defp first_message([first | _]), do: first.message
  defp first_message([]), do: nil
end
