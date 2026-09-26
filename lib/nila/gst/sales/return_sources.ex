defmodule Nila.Gst.Sales.ReturnSources do
  @moduledoc "Combines supplied return summaries with invoice-derived sections, retaining source evidence."
  alias Nila.Gst.Sales.Gstr1
  alias Nila.Gst.Sales.Gstr1.Documents
  alias Nila.Gst.Money
  alias Nila.Gst.StateCodes

  def from_dumps(dumps) do
    for dump <- dumps, dump.status == "extracted", report = dump.meta["return_report"] do
      report |> Map.put("dump_id", dump.id) |> Map.put("filename", dump.meta["original_name"])
    end
  end

  def apply(projection, invoices, reports) do
    supplied =
      for report <- reports,
          row <- report["rows"],
          row["section"] in ~w(b2cs hsn_b2b hsn_b2c doc_issue nil),
          do:
            Map.merge(row, %{
              "dump_id" => report["dump_id"],
              "filename" => row["source_filename"] || report["filename"]
            })

    ordinary = Enum.reject(invoices, & &1["return_report_section"])
    derived = projection.derived
    # A supplied B2CS total can already include the notes. Do not deduct twice.
    included_notes =
      for invoice <- invoices,
          invoice["return_report_section"] == "CDNUR",
          Enum.any?(
            reports,
            &(&1["dump_id"] == invoice["return_report_dump_id"] and
                &1["b2cs_before_notes"] == false)
          ),
          do: invoice

    already_included = Gstr1.derive(included_notes, Map.take(derived, ~w(gstin fp)))["b2cs"] || []

    reversals =
      Enum.map(already_included, fn row ->
        Enum.reduce(
          ~w(txval iamt camt samt csamt),
          row,
          &Map.update(&2, &1, 0, fn amount -> -amount end)
        )
      end)

    derived = Map.update!(derived, "b2cs", &combine_b2cs(&1 ++ reversals))

    hsn =
      if reports == [],
        do: derived["hsn"] || %{},
        else: Gstr1.derive(ordinary, Map.take(derived, ~w(gstin fp)))["hsn"]

    hsn =
      Enum.reduce(~w(hsn_b2b hsn_b2c), hsn, fn key, acc ->
        rows = supplied |> Enum.filter(&(&1["section"] == key)) |> Enum.map(&hsn_entry/1)
        Map.update(acc, key, rows, &(&1 ++ rows))
      end)

    b2cs = for row <- supplied, row["section"] == "b2cs", do: b2cs_entry(row)

    docs =
      for row <- supplied, row["section"] == "doc_issue", entry = document_entry(row), do: entry

    nil_rows =
      for row <- supplied,
          row["section"] == "nil",
          Enum.any?(~w(nil_amt expt_amt ngsup_amt), &((row["values"][&1] || 0) != 0)),
          do: nil_entry(row)

    derived =
      derived
      |> Map.put("hsn", hsn)
      |> Map.update(
        "nil",
        %{"inv" => nil_rows},
        &Map.update(&1, "inv", nil_rows, fn existing -> existing ++ nil_rows end)
      )
      |> Map.update("b2cs", b2cs, &combine_b2cs(&1 ++ b2cs))
      |> Map.put(
        "doc_issue",
        if(reports == [],
          do: derived["doc_issue"],
          else: %{"doc_det" => combine_documents(Documents.derive(ordinary)["doc_det"] ++ docs)}
        )
      )

    issues = Enum.flat_map(supplied, &row_issues/1) ++ report_checks(reports, invoices, derived)
    {%{projection | derived: derived}, issues, supplied}
  end

  def invoice_issues(issues, invoices, reports) do
    covered =
      MapSet.new(
        for i <- invoices,
            i["return_report_section"],
            Enum.any?(reports, fn report -> report["dump_id"] == i["return_report_dump_id"] end),
            do: i["id"]
      )

    Enum.reject(issues, fn issue ->
      issue["code"] in ~w(missing_hsn_sac missing_uom) and
        MapSet.member?(covered, issue["source_id"])
    end)
  end

  def invoice_checks(invoices) do
    Enum.flat_map(invoices, fn invoice ->
      fields =
        cond do
          invoice["return_report_section"] in ~w(CDNR CDNUR) and
              invoice["place_of_supply"] in [nil, ""] ->
            ["place_of_supply"]

          invoice["return_report_section"] == "CDNUR" and
            invoice["original_sale_category"] == "b2cl" and
              invoice["place_of_supply"] == String.slice(invoice["seller_gstin"] || "", 0, 2) ->
            ["original_sale_category"]

          true ->
            []
        end

      if fields == [],
        do: [],
        else: [
          %{
            "code" => "return_report_invalid",
            "level" => "blocking",
            "source_id" => invoice["id"],
            "fields" => fields,
            "message" =>
              if(fields == ["place_of_supply"],
                do:
                  "The credit-note report does not state place of supply. Confirm it from the original sale.",
                else:
                  "The report labels this note B2CL, but its place of supply is the supplier's state. Confirm the original sale category."
              )
          }
        ]
    end)
  end

  def row_issues(row) do
    v = row["values"]

    required =
      case row["section"] do
        "doc_issue" -> ~w(from to totnum cancel net_issue)
        "b2cs" -> ~w(pos rate txval iamt camt samt csamt)
        "nil" -> ~w(description nil_amt expt_amt ngsup_amt)
        _ -> ~w(hsn_sc uqc qty rate txval iamt camt samt csamt)
      end

    errors = for key <- required, v[key] in [nil, ""], do: "#{key} is missing"

    errors =
      errors ++
        for key <- ~w(rate pos hsn_sc uqc),
            v[key] not in [nil, ""],
            not valid_summary_field?(row["section"], key, v[key]),
            do: "#{key} is invalid"

    errors =
      if row["section"] == "b2cs" and valid_summary_field?("b2cs", "pos", v["pos"]) and
           is_binary(v["seller_gstin"]) and
           Enum.all?(~w(iamt camt samt), &is_number(v[&1])) do
        local? = v["pos"] == String.slice(v["seller_gstin"], 0, 2)

        mismatch? =
          if local? do
            Money.paise(v["iamt"]) != 0 or
              abs(Money.paise(v["camt"]) - Money.paise(v["samt"])) > 1
          else
            Money.paise(v["camt"]) != 0 or Money.paise(v["samt"]) != 0
          end

        if mismatch?, do: errors ++ ["Tax amounts do not match the place of supply"], else: errors
      else
        errors
      end

    errors =
      errors ++
        cond do
          row["section"] == "doc_issue" and is_nil(document_entry(row)) ->
            ["Choose the statutory document type for #{v["nature"]}"]

          (row["section"] == "doc_issue" and v["totnum"]) && v["cancel"] && v["net_issue"] &&
              v["totnum"] - v["cancel"] != v["net_issue"] ->
            ["Issued count does not equal total less cancelled"]

          row["section"] == "b2cs" and (v["type"] != "OE" or v["etin"] not in [nil, ""]) ->
            ["E-commerce summary treatment is not supported by this report reader"]

          true ->
            []
        end

    errors =
      if (v["tcs"] || 0) != 0,
        do: errors ++ ["TCS treatment needs a separate supported return section"],
        else: errors

    Enum.map(errors, &issue(row, &1))
  end

  def valid_summary_field?(_section, "rate", value),
    do: is_number(value) and value >= 0 and value <= 100

  def valid_summary_field?("b2cs", "pos", value),
    do:
      is_binary(value) and Regex.match?(~r/\A\d{2}\z/, value) and
        not is_nil(StateCodes.name_for(value))

  def valid_summary_field?(section, "hsn_sc", value) when section in ~w(hsn_b2b hsn_b2c),
    do: is_binary(value) and Regex.match?(~r/\A\d{2,8}\z/, value)

  def valid_summary_field?(section, "uqc", value) when section in ~w(hsn_b2b hsn_b2c),
    do: is_binary(value) and Regex.match?(~r/\A[A-Z]{2,4}\z/, value)

  def valid_summary_field?(_section, _field, _value), do: true

  defp report_checks(reports, invoices, derived) do
    unsupported =
      for invoice <- invoices,
          invoice["return_report_section"],
          v <- invoice["return_report_values"] || [],
          (v["csamt"] || 0) != 0 or v["etin"] not in [nil, ""] or (v["tcs"] || 0) != 0 or
            v["invoice_type"] not in [nil, "R"],
          do: %{
            "code" => "return_report_invalid",
            "level" => "blocking",
            "source_id" => invoice["id"],
            "message" =>
              "This report row has cess, e-commerce or a special invoice type that needs supported filing treatment.",
            "fields" => []
          }

    notes =
      Enum.filter(
        invoices,
        &(&1["return_report_section"] == "CDNUR" and
            (&1["original_sale_category"] == "b2cs" or invoice_checks([&1]) != []))
      )

    basis =
      for report <- reports,
          notes != [],
          not is_boolean(report["b2cs_before_notes"]),
          do: %{
            "code" => "return_report_invalid",
            "level" => "blocking",
            "invoice" => nil,
            "target" => "return_report:#{report["dump_id"]}:basis",
            "fields" => [],
            "message" =>
              "Confirm whether the supplied B2CS totals are before credit/debit notes. This determines whether to subtract the notes."
          }

    # Comparisons are independent controls, not inputs used to force a match.
    reconciliation =
      if Enum.any?(reports, &(&1["format"] in [nil, "gstr1_sections_v1"])) do
        reconcile(derived, ~w(hsn_b2b hsn_b2c))
      else
        supplied_hsn =
          for report <- reports,
              report["format"] == "standard_gstr1_sections",
              row <- report["rows"],
              row["section"] in ~w(hsn_b2b hsn_b2c),
              uniq: true,
              do: row["section"]

        reconcile(derived, supplied_hsn)
      end

    missing_hsn =
      for report <- reports,
          report["format"] in ~w(standard_gstr1_sections ultino_register kpn_register),
          {invoice_section, hsn_section} <- [{"b2b", "hsn_b2b"}, {"b2cs", "hsn_b2c"}],
          report_invoices =
            Enum.filter(invoices, &(&1["return_report_dump_id"] == report["dump_id"])),
          Enum.any?(report["rows"], &(&1["section"] == invoice_section)) or
            Enum.any?(report_invoices, &(Gstr1.filing_table(&1) == invoice_section)),
          not Enum.any?(report["rows"], &(&1["section"] == hsn_section)) do
        %{
          "code" => "return_report_invalid",
          "level" => "blocking",
          "invoice" => nil,
          "target" => "return_report:hsn_missing:#{report["dump_id"]}:#{hsn_section}",
          "fields" => [],
          "message" =>
            "This file has #{String.upcase(invoice_section)} sales but no HSN summary for those sales. Add the HSN details to complete the return."
        }
      end

    overlap =
      if reports != [] and Enum.any?(invoices, &is_nil(&1["return_report_section"])),
        do: [
          %{
            "code" => "return_report_invalid",
            "level" => "blocking",
            "invoice" => nil,
            "target" => "return_report:overlap",
            "fields" => [],
            "message" =>
              "This month contains both a section report and separate invoices. Remove overlapping sources before exporting; combining their summary coverage is not supported yet."
          }
        ],
        else: []

    unsupported ++ basis ++ reconciliation ++ missing_hsn ++ overlap
  end

  defp reconcile(derived, supplied_hsn) do
    for {key, tables} <- [{"hsn_b2b", ~w(b2b cdnr)}, {"hsn_b2c", ~w(b2cs b2cl cdnur)}],
        key in supplied_hsn,
        field <- ~w(txval iamt camt samt),
        actual = total(get_in(derived, ["hsn", key]) || [], field),
        expected = return_total(derived, tables, field),
        abs(actual - expected) > 100 do
      %{
        "code" => "return_report_invalid",
        "level" => "blocking",
        "invoice" => nil,
        "target" => "return_report:#{key}:#{field}",
        "fields" => [],
        "message" =>
          "#{key} #{field}: supplied HSN totals differ from the return by ₹#{Float.round((actual - expected) / 100, 2)}. Check the source summaries and notes."
      }
    end
  end

  defp return_total(derived, tables, field) do
    Enum.reduce(tables, 0, fn table, sum ->
      entries = derived[table] || []

      sum +
        case table do
          "b2cs" ->
            total(entries, field)

          "cdnur" ->
            Enum.sum(for note <- entries, do: note_total(note, field))

          "cdnr" ->
            Enum.sum(for group <- entries, note <- group["nt"] || [], do: note_total(note, field))

          _ ->
            Enum.sum(
              for group <- entries,
                  inv <- group["inv"] || [],
                  item <- inv["itms"] || [],
                  do: Money.paise(get_in(item, ["itm_det", field]) || 0)
            )
        end
    end)
  end

  defp note_total(note, field),
    do:
      if(note["ntty"] == "C", do: -1, else: 1) *
        Enum.sum(
          for item <- note["itms"] || [],
              do: Money.paise(get_in(item, ["itm_det", field]) || item[field] || 0)
        )

  defp total(rows, field), do: Enum.sum(Enum.map(rows, &Money.paise(&1[field] || 0)))

  defp hsn_entry(row) do
    row["values"]
    |> Map.take(~w(hsn_sc desc uqc qty txval iamt camt samt csamt))
    |> Map.put("rt", row["values"]["rate"])
    |> Map.put("num", row["row"] - 1)
  end

  defp nil_entry(row) do
    v = row["values"]
    label = v["description"] || ""
    supply = if String.starts_with?(label, "Intra-State"), do: "INTRA", else: "INTR"

    recipient =
      if String.ends_with?(label, "registered persons") and
           not String.contains?(label, "unregistered"), do: "B2B", else: "B2C"

    v |> Map.take(~w(nil_amt expt_amt ngsup_amt)) |> Map.put("sply_ty", supply <> recipient)
  end

  defp b2cs_entry(row) do
    v = row["values"]
    pos = String.slice(v["pos"] || "", 0, 2)
    seller_state = String.slice(v["seller_gstin"] || "", 0, 2)

    supply =
      if pos != "" and seller_state != "",
        do: if(pos == seller_state, do: "INTRA", else: "INTER"),
        else: v["supply"]

    v
    |> Map.take(~w(txval iamt camt samt csamt))
    |> Map.merge(%{
      "rt" => v["rate"],
      "pos" => pos,
      "typ" => v["type"],
      "sply_ty" => supply
    })
  end

  defp combine_b2cs(rows) do
    rows
    |> Enum.map(fn row ->
      if is_number(row["rt"]), do: Map.update!(row, "rt", &(&1 * 1.0)), else: row
    end)
    |> Enum.group_by(&Map.take(&1, ~w(rt pos typ sply_ty)))
    |> Enum.sort()
    |> Enum.map(fn {identity, group} ->
      Map.merge(identity, Map.new(~w(txval iamt camt samt csamt), &{&1, total(group, &1) / 100}))
    end)
  end

  defp document_entry(row) do
    v = row["values"]

    counts = Enum.map(~w(totnum cancel net_issue), &v[&1])
    valid_counts = Enum.all?(counts, &(is_number(&1) and &1 >= 0 and &1 == trunc(&1)))
    kind = if v["doc_num"] in 1..12 and valid_counts, do: v["doc_num"]

    if kind,
      do: %{
        "doc_num" => kind,
        "docs" => [
          v
          |> Map.take(~w(from to totnum cancel net_issue))
          |> then(fn entry ->
            Enum.reduce(
              ~w(totnum cancel net_issue),
              entry,
              &Map.update!(&2, &1, fn n -> trunc(n) end)
            )
          end)
          |> Map.put("num", row["row"] - 1)
        ]
      }
  end

  defp combine_documents(entries) do
    entries
    |> Enum.group_by(& &1["doc_num"])
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {kind, groups} ->
      docs =
        groups
        |> Enum.flat_map(& &1["docs"])
        |> Enum.with_index(1)
        |> Enum.map(fn {doc, index} -> Map.put(doc, "num", index) end)

      %{"doc_num" => kind, "docs" => docs}
    end)
  end

  defp issue(row, message),
    do: %{
      "code" => "return_report_invalid",
      "level" => "blocking",
      "invoice" => nil,
      "target" =>
        "return_report:#{row["dump_id"]}:#{row["source_filename"]}:#{row["sheet"]}:#{row["row"]}:#{message}",
      "fields" => [],
      "message" => "#{row["sheet"]}, row #{row["row"]}: #{message}."
    }
end
