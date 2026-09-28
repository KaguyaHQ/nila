defmodule Nila.Gst.Sales.ReportReview do
  @moduledoc "Actionable report checks shared by the month overview and report review."
  alias Nila.Gst.Sales.{ReturnSources, Review}
  alias Nila.Gst.Money

  def build(workings, reports \\ nil) do
    reports = reports || Map.get(workings, :return_reports, [])

    Enum.flat_map(reports, fn report ->
      invoices =
        Enum.filter(workings.active_invoices, &(&1["return_report_dump_id"] == report["dump_id"]))

      rows = Enum.filter(report["rows"], &(&1["section"] in ~w(b2cs hsn_b2b hsn_b2c doc_issue)))

      row_tasks =
        Enum.flat_map(rows, fn row ->
          errors = ReturnSources.row_issues(Map.put(row, "dump_id", report["dump_id"]))

          if errors == [],
            do: [],
            else: [
              task(report, "row:#{row["source_filename"]}:#{row["sheet"]}:#{row["row"]}", %{
                "kind" => "row",
                "title" => row_title(row),
                "message" => Enum.map_join(errors, " ", & &1["message"]),
                "sheet" => row["sheet"],
                "source_filename" => row["source_filename"],
                "row" => row["row"],
                "fields" => edit_fields(row),
                "values" => row["values"],
                "rows" => [row]
              })
            ]
        end)

      notes =
        invoices
        |> Enum.filter(&(ReturnSources.invoice_checks([&1]) != []))
        |> Enum.group_by(fn invoice ->
          {invoice["return_report_section"], invoice["place_of_supply"],
           invoice["original_sale_category"],
           Enum.any?(invoice["line_items"] || [], &((&1["igst_amount"] || 0) != 0))}
        end)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {{section, pos, category, interstate?}, group} ->
          ids = Enum.map(group, & &1["id"]) |> Enum.sort()

          task(report, "notes:" <> Jason.encode!([section, pos, category, interstate?]), %{
            "kind" => "notes",
            "title" =>
              "Check #{length(group)} #{if section == "CDNUR", do: "unregistered", else: "registered"} credit/debit notes",
            "message" =>
              "Set the place of supply#{if section == "CDNUR", do: " and original sale category", else: ""} for the notes below.",
            "sheet" => "notes",
            "source_ids" => ids,
            "fields" =>
              if(section == "CDNUR",
                do: ~w(place_of_supply original_sale_category),
                else: ~w(place_of_supply)
              ),
            "values" => Map.take(hd(group), ~w(place_of_supply original_sale_category)),
            "rows" =>
              report["rows"]
              |> Enum.filter(fn row -> Enum.any?(group, &source_row?(&1, row)) end)
              |> Enum.map(fn row ->
                invoice = Enum.find(group, &source_row?(&1, row))
                Map.put(row, "source_id", invoice["id"])
              end)
          })
        end)

      b2cs_notes =
        Enum.filter(
          invoices,
          &(&1["return_report_section"] == "CDNUR" and &1["original_sale_category"] == "b2cs")
        )

      basis =
        if notes == [] and b2cs_notes != [] and
             not is_boolean(report["b2cs_before_notes"]) do
          sales = report["rows"] |> Enum.filter(&(&1["section"] == "b2cs")) |> sum("txval")

          deduction =
            b2cs_notes
            |> Enum.reduce(0, fn invoice, acc ->
              acc +
                Enum.sum(
                  Enum.map(invoice["line_items"] || [], &Money.paise(&1["taxable_value"] || 0))
                ) *
                  if(invoice["document_type"] == "debit_note", do: -1, else: 1)
            end)

          [
            task(report, "basis", %{
              "kind" => "basis",
              "title" => "Do B2CS totals already include these notes?",
              "message" => "Choose whether to deduct the notes from the supplied sales totals.",
              "sheet" => "report",
              "row" => 0,
              "fields" => ["b2cs_before_notes"],
              "values" => %{},
              "amounts" => %{
                "before" => sales / 100,
                "notes" => deduction / 100,
                "after" => (sales - deduction) / 100
              },
              "rows" =>
                Enum.filter(
                  report["rows"],
                  &(&1["section"] == "b2cs" or
                      (&1["section"] == "cdnur" and
                         Enum.any?(b2cs_notes, fn note -> source_row?(note, &1) end)))
                )
            })
          ]
        else
          []
        end

      covered_ids = Enum.flat_map(notes, & &1["source_ids"])

      invoice_tasks =
        Review.build(workings).needs_you
        |> Enum.filter(&(&1.source_id in Enum.map(invoices, fn i -> i["id"] end)))
        |> Enum.reject(&(&1.source_id in covered_ids))
        |> Enum.map(fn item ->
          task(report, "invoice:#{item.source_id}", %{
            "kind" => "invoice",
            "title" => "Check #{item.invoice["invoice_number"]}",
            "message" =>
              Enum.map_join(
                item.actionable_issues,
                " ",
                &(&1["message"] || "Review invoice details.")
              ),
            "source_ids" => [item.source_id],
            "fields" => [],
            "values" => %{},
            "rows" => []
          })
        end)

      # Show reconciliation after treatment decisions, so one unresolved cause
      # does not appear again as several tax-total differences.
      reconciliation =
        if notes == [] and basis == [] and row_tasks == [] do
          workings.issues
          |> Enum.filter(
            &(&1["code"] == "return_report_invalid" and &1["source_id"] == nil and
                &1["status"] != "resolved" and
                not String.starts_with?(&1["target"] || "", "return_report:#{report["dump_id"]}:"))
          )
          |> Enum.group_by(fn issue ->
            String.split(issue["target"] || "", ":") |> Enum.take(2) |> Enum.join(":")
          end)
          |> Enum.map(fn {key, issues} ->
            task(report, key, %{
              "kind" => if(key == "return_report:overlap", do: "uploads", else: "reconciliation"),
              "title" =>
                case key do
                  "return_report:overlap" -> "Check overlapping uploads"
                  "return_report:hsn_missing" -> "HSN details needed"
                  _ -> "Check summary totals"
                end,
              "message" => Enum.map_join(issues, " ", & &1["message"]),
              "fields" => [],
              "values" => %{},
              "rows" => Enum.filter(rows, &(&1["section"] in ~w(b2cs hsn_b2b hsn_b2c)))
            })
          end)
        else
          []
        end

      row_tasks ++ notes ++ basis ++ invoice_tasks ++ reconciliation
    end)
  end

  defp sum(rows, field), do: Enum.sum(Enum.map(rows, &Money.paise(&1["values"][field] || 0)))

  defp source_row?(invoice, row) do
    case invoice["source_refs"] do
      refs when is_list(refs) ->
        Enum.any?(refs, fn ref ->
          ref["source_filename"] == row["source_filename"] and
            ref["sheet"] == row["sheet"] and ref["row"] == row["row"]
        end)

      _ ->
        (invoice["source_sheet"] || invoice["return_report_section"]) == row["sheet"] and
          row["row"] in (invoice["source_rows"] || [])
    end
  end

  defp task(report, id, values),
    do:
      Map.merge(
        %{
          "id" =>
            "#{report["dump_id"]}:" <>
              Base.url_encode64(:crypto.hash(:sha256, id), padding: false),
          "dump_id" => report["dump_id"],
          "basis" => report["basis"],
          "filename" => report["filename"],
          "source_ids" => [],
          "sheet" => "",
          "row" => 0
        },
        values
      )

  defp row_title(%{"section" => "doc_issue", "values" => v}),
    do: "Document category: #{v["nature"]}"

  defp row_title(%{"section" => s, "values" => v}) when s in ~w(hsn_b2b hsn_b2c),
    do: "HSN/SAC #{v["hsn_sc"]}"

  defp row_title(_), do: "Check B2CS summary"
  def fields("doc_issue"), do: ~w(doc_num from to totnum cancel net_issue)
  def fields("b2cs"), do: ~w(pos rate txval iamt camt samt csamt)
  def fields(_), do: ~w(hsn_sc uqc qty rate txval iamt camt samt csamt)

  defp edit_fields(row) do
    missing = Enum.filter(fields(row["section"]), &(row["values"][&1] in [nil, ""]))
    if missing == [], do: fields(row["section"]), else: missing
  end
end
