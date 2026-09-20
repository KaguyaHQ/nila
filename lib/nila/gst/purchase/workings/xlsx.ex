defmodule Nila.Gst.Purchase.Workings.Xlsx do
  @moduledoc "Exports the existing purchase projection as a review working, not a return."
  alias Nila.Gst.Purchase.{Reconciliation, Register, Workings}

  @body [:text_wrap, {:font_name, "Arial"}, {:valign, :top}]
  @money @body ++ [{:num_format, "#,##0.00;(#,##0.00);\"-\""}]
  @header @body ++ [:bold, {:bg_color, "#E7E7E7"}]

  def build(workings, client, period, opts \\ []) do
    title = "#{client.name} · #{client.gstin} · #{period}"
    status = Keyword.get(opts, :status, "Prepared for review")
    review = Keyword.fetch!(opts, :review)
    books = Map.new(Workings.books_invoices(workings.recon), &{&1["id"], &1})
    case_lines = Map.get(workings, :case_lines, [])

    register =
      Enum.map(workings.rows, fn row ->
        source = books[row["id"]] || %{}
        decision = decision_for(case_lines, "books", row["id"])

        [
          row["id"],
          row["vendor_name"],
          row["vendor_gstin"],
          row["document_type"],
          row["invoice_number"],
          display(row["invoice_date"]),
          row["bucket_label"],
          money(row["taxable_paise"]),
          money(row["cgst_paise"]),
          money(row["sgst_paise"]),
          money(row["igst_paise"]),
          money(row["cess_paise"]),
          money(row["total_paise"]),
          row["verdict"],
          row["recon_note"],
          row["accepted_reason"],
          row["flag_summary"],
          source["source_sheet"],
          Enum.join(source["source_rows"] || [], ", "),
          Enum.join(row["pages"] || [], ", "),
          decision_label(decision),
          decision_reason(decision)
        ]
      end)

    reviews =
      Enum.map(review.all, fn item ->
        source_rows = Enum.filter(workings.rows, &(&1["id"] in item.member_ids))
        flags = source_rows |> Enum.flat_map(&(&1["flags"] || [])) |> Enum.uniq()

        needs_review? =
          not item.resolved or Enum.any?(source_rows, &(&1["bucket"] == "value_mismatch")) or
            Enum.any?(source_rows, &Register.needs_review?/1)

        [
          item.id,
          item.vendor,
          item.invoice_number,
          Atom.to_string(item.kind),
          item.type,
          if(needs_review?, do: "Needs review", else: "Recorded / paired"),
          item.reason,
          item.outcome,
          item.verb,
          money(item.tax_paise),
          Enum.join(item.member_ids, ", "),
          Enum.map_join(item.counterparts, ", ", & &1["invoice_number"]),
          Enum.map_join(item.counterparts, ", ", &Reconciliation.gstr2b_ref/1),
          Enum.map_join(flags, "; ", &(&1["reason"] || &1["code"]))
        ]
      end)

    blocks =
      Enum.map(workings.itc["blocks"] || [], fn block ->
        [
          block["block_id"],
          block["vendor"],
          block["invoice_number"],
          block["reason"],
          block["state"],
          money(block["tax_paise"])
        ]
      end)

    portal =
      Enum.map(Workings.gstr2b_invoices(workings.recon), fn document ->
        tax = document["tax_paise"] || %{}
        decision = decision_for(case_lines, "gstr2b", Reconciliation.gstr2b_ref(document))

        [
          Reconciliation.gstr2b_ref(document),
          document["vendor_name"],
          document["vendor_gstin"],
          document["document_type"] || "invoice",
          document["invoice_number"],
          display(document["invoice_date"]),
          money(document["taxable_paise"]),
          money(tax["cgst"]),
          money(tax["sgst"]),
          money(tax["igst"]),
          money(tax["cess"]),
          money(document["total_paise"]),
          decision_label(decision),
          decision_reason(decision)
        ]
      end)

    sheets = [
      summary(workings, title, status),
      table(
        "Register",
        title,
        "Source amounts in INR. Credit notes retain positive source values; document type identifies the adjustment.",
        [
          "Source ID",
          "Supplier",
          "GSTIN",
          "Document type",
          "Invoice",
          "Date",
          "Reconciliation",
          "Taxable",
          "CGST",
          "SGST",
          "IGST",
          "CESS",
          "Invoice total",
          "Finding",
          "Explanation",
          "Recorded reason",
          "Checks",
          "Source sheet",
          "Source rows",
          "Source pages",
          "ITC decision",
          "ITC decision reason"
        ],
        register
      ),
      table(
        "GSTR-2B",
        title,
        "Effective 2B records used by this working; source amounts in INR.",
        [
          "2B reference",
          "Supplier",
          "GSTIN",
          "Document type",
          "Invoice",
          "Date",
          "Taxable",
          "CGST",
          "SGST",
          "IGST",
          "CESS",
          "Invoice total",
          "ITC decision",
          "ITC decision reason"
        ],
        portal
      ),
      table(
        "Review",
        title,
        "Pairing is separate from ITC eligibility. Value mismatches remain visible even when already paired.",
        [
          "Review ID",
          "Supplier",
          "Invoice",
          "Kind",
          "Finding",
          "Review state",
          "Explanation",
          "Outcome",
          "Decision",
          "Tax at stake",
          "Books IDs",
          "2B invoices",
          "2B references",
          "Checks to review"
        ],
        reviews
      ),
      table(
        "ITC checks",
        title,
        "Existing recommendations and reviewer decisions; recommended does not mean approved.",
        ["Check ID", "Supplier", "Invoice", "Reason", "Decision state", "Tax"],
        blocks
      ),
      treatment_sheet(case_lines, title)
    ]

    XlsxWriter.generate(sheets)
  end

  defp treatment_sheet(lines, title) do
    heads = ~w(cgst sgst igst cess)

    rows =
      lines
      |> Enum.filter(&(&1[:document_type] in ~w(invoice debit_note)))
      |> Enum.map(fn line ->
        opening = line[:outstanding_heads] || %{}
        treatment = line[:treatment_heads] || %{}
        claim = treatment["claim"] || %{}
        later = treatment["later"] || %{}
        exclude = treatment["exclude"] || %{}
        pending = if line[:treatment] == "undecided", do: opening, else: %{}
        closing = Map.new(heads, &{&1, (later[&1] || 0) + (pending[&1] || 0)})

        [
          line[:case_id],
          line[:vendor],
          line[:supplier_gstin],
          line[:invoice_number],
          line[:origin_period],
          line[:treatment],
          line[:later_reason],
          line[:exclude_reason],
          line[:treatment_note],
          Enum.join(source_refs(line, "gstr2b"), ", ")
        ] ++
          Enum.flat_map([opening, claim, later, exclude, pending, closing], fn amounts ->
            Enum.map(heads, &money(amounts[&1] || 0))
          end)
      end)

    headers =
      [
        "Case ID",
        "Supplier",
        "GSTIN",
        "Invoice",
        "Origin period",
        "Treatment",
        "Later reason",
        "Exclude reason",
        "Reviewer note",
        "2B references"
      ] ++
        for group <- [
              "Opening",
              "Claim this month",
              "Carry later",
              "Exclude",
              "Pending",
              "Closing carry"
            ],
            head <- heads,
            do: "#{group} #{String.upcase(head)}"

    table(
      "ITC treatment",
      title,
      "Per-head opening = claim + carry later + exclude + pending. Closing carry = later + pending. Source amounts remain on Register and GSTR-2B.",
      headers,
      rows
    )
  end

  defp summary(workings, title, status) do
    treatment_summary(workings.itc, title, status)
  end

  defp treatment_summary(itc, title, status) do
    rows = [
      ["Imported GSTR-2B tax (source, this period)", money(itc["reported_2b_paise"])],
      ["Opening outstanding credit (all origins)", money(itc["opening_outstanding_paise"])],
      ["Claim this period", money(itc["current_claim_paise"])],
      ["Carry for later", money(itc["later_paise"])],
      ["Exclude", money(itc["excluded_paise"])],
      ["Pending decision", money(itc["pending_paise"])],
      ["Opening control (should be zero)", {:formula, "B6-SUM(B7:B10)"}],
      ["Closing carry", money(itc["closing_outstanding_paise"])],
      ["Carry control (should be zero)", {:formula, "B12-SUM(B8,B10)"}],
      ["Review status", status],
      [
        "Basis",
        "Source amounts and treatment are shown separately. This working is not filing approval."
      ],
      ["Formula calculation", "Open in Excel with calculation enabled to refresh the controls."]
    ]

    table(
      "ITC working",
      title,
      "Amounts in INR. Opening includes carried credit from earlier periods; imported 2B is this period's source amount.",
      ["Particulars", "Amount / note"],
      rows
    )
  end

  defp table(name, title, note, headers, rows) do
    sheet =
      XlsxWriter.new_sheet(name)
      |> XlsxWriter.merge_range(0, 0, 0, length(headers) - 1, title, format: @header)
      |> XlsxWriter.merge_range(1, 0, 1, length(headers) - 1, note, format: @body)
      |> XlsxWriter.set_row_height(1, 36)
      |> XlsxWriter.freeze_panes(4, 0)

    sheet =
      Enum.with_index(headers)
      |> Enum.reduce(sheet, fn {header, col}, acc ->
        acc
        |> XlsxWriter.write(3, col, header, format: @header)
        |> XlsxWriter.set_column_width(col, if(length(headers) == 2, do: 65, else: 24))
      end)

    sheet =
      rows
      |> Enum.with_index(4)
      |> Enum.reduce(sheet, fn {cells, row}, acc ->
        cells
        |> Enum.with_index()
        |> Enum.reduce(acc, fn {value, col}, s -> cell(s, row, col, value) end)
      end)

    if rows == [],
      do: sheet,
      else: XlsxWriter.set_autofilter(sheet, 3, 0, length(rows) + 3, length(headers) - 1)
  end

  defp cell(sheet, row, col, {:money, nil}),
    do: XlsxWriter.write_blank(sheet, row, col, format: @money)

  defp cell(sheet, row, col, {:money, value}),
    do: XlsxWriter.write(sheet, row, col, value / 100, format: @money)

  defp cell(sheet, row, col, {:formula, formula}),
    do: XlsxWriter.write_formula(sheet, row, col, formula, format: @money)

  defp cell(sheet, row, col, nil), do: XlsxWriter.write_blank(sheet, row, col, format: @body)

  defp cell(sheet, row, col, value),
    do: XlsxWriter.write(sheet, row, col, display(value), format: @body)

  defp money(value), do: {:money, value}

  defp decision_for(lines, kind, ref) do
    Enum.find(lines, &(ref in source_refs(&1, kind)))
  end

  defp source_refs(line, kind), do: (get_in(line, [:source_refs, kind]) || %{}) |> Map.values()
  defp decision_label(nil), do: nil
  defp decision_label(line), do: line[:treatment]
  defp decision_reason(nil), do: nil

  defp decision_reason(line),
    do: Enum.join(Enum.reject([line[:later_reason], line[:exclude_reason]], &is_nil/1), "; ")

  defp display(nil), do: ""
  defp display(value), do: to_string(value)
end
