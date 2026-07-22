defmodule Nila.Gst.Purchase.Register do
  @moduledoc """
  Builds purchase-register rows from the books invoices, the reconciliation
  result (`Nila.Gst.Purchase.Reconciliation`), and the validation flags (`Nila.Gst.Purchase.Flags`).

  Pure: plain maps in, plain maps out. The row shape is the single source for
  every register rendering — the Excel deliverable, the Typst pack tables —
  so the surfaces cannot drift.
  """

  alias Nila.Formatters

  @bucket_labels %{
    "matched" => "Matched to 2B",
    "value_mismatch" => "Value differs from 2B",
    "needs_human" => "Needs a decision",
    "in_books_not_2b" => "Not in 2B",
    "in_2b_not_books" => "In 2B only"
  }

  @doc """
  One row per books invoice, in page order, followed by rows for 2B-only
  entries. Each row:

      %{
        "id", "pages", "images",
        "invoice_number", "invoice_date", "vendor_name", "vendor_gstin",
        "taxable_paise", "cgst_paise", "sgst_paise", "igst_paise", "total_paise",
        "bucket" => recon bucket key,
        "bucket_label" => human label,
        "accepted_reason" => audited unmatched outcome or nil,
        "verdict" => short operator-language table text,
        "recon_note" => full engine reasoning or match detail,
        "next_action" => drafted follow-up or nil,
        "flags" => [%{"code", "severity", "reason"}],
        "flag_summary" => "code, code" or nil
      }
  """
  def rows(invoices, recon, flags_by_id) do
    bucket_index = bucket_index(recon)

    books_rows =
      invoices
      |> Enum.sort_by(&List.first(&1["pages"] || [0]))
      |> Enum.map(fn inv ->
        {bucket, entry} = Map.get(bucket_index, inv["id"], {"in_books_not_2b", nil})
        flags = Map.get(flags_by_id, inv["id"], [])

        %{
          "id" => inv["id"],
          "pages" => inv["pages"] || [],
          "images" => inv["images"] || [],
          "invoice_number" => inv["invoice_number"],
          "invoice_date" => inv["invoice_date"],
          "vendor_name" => inv["vendor_name"],
          "vendor_gstin" => inv["vendor_gstin"],
          "taxable_paise" => inv["taxable_paise"] || 0,
          "cgst_paise" => tax(inv, "cgst"),
          "sgst_paise" => tax(inv, "sgst"),
          "igst_paise" => tax(inv, "igst"),
          "total_paise" => inv["total_paise"] || 0,
          "bucket" => bucket,
          "bucket_label" => @bucket_labels[bucket],
          "accepted_reason" => entry && entry["accepted_reason"],
          "verdict" => verdict(bucket, entry, flags),
          "recon_note" => recon_note(bucket, entry),
          "next_action" => entry && entry["next_action"],
          "flags" => Enum.map(flags, &Map.take(&1, ["code", "severity", "reason", "section"])),
          "flag_summary" => flag_summary(flags)
        }
      end)

    books_rows ++ g2b_only_rows(recon)
  end

  @doc "Bucket counts plus flag totals for the cover/status page."
  def summary(rows) do
    %{
      "total_invoices" => Enum.count(rows, &(&1["bucket"] != "in_2b_not_books")),
      "buckets" => Enum.frequencies_by(rows, & &1["bucket"]),
      "accepted_unmatched" => Enum.count(rows, &(&1["accepted_reason"] != nil)),
      "flag_counts" =>
        rows
        |> Enum.flat_map(& &1["flags"])
        |> Enum.frequencies_by(& &1["code"]),
      "taxable_paise" =>
        rows
        |> Enum.reject(&(&1["bucket"] == "in_2b_not_books"))
        |> Enum.map(& &1["taxable_paise"])
        |> Enum.sum(),
      "matched_tax_paise" =>
        rows
        |> Enum.filter(&(&1["bucket"] == "matched"))
        |> Enum.map(&(&1["cgst_paise"] + &1["sgst_paise"] + &1["igst_paise"]))
        |> Enum.sum()
    }
  end

  defp bucket_index(recon) do
    for bucket <- ["matched", "value_mismatch", "needs_human", "in_books_not_2b"],
        entry <- recon[bucket] || [],
        books = entry["books"],
        books != nil,
        into: %{} do
      {books["id"], {bucket, entry}}
    end
  end

  defp g2b_only_rows(recon) do
    for entry <- recon["in_2b_not_books"] || [] do
      g = entry["gstr2b"] || entry

      %{
        "id" => nil,
        "pages" => [],
        "images" => [],
        "invoice_number" => g["invoice_number"],
        "invoice_date" => g["invoice_date"],
        "vendor_name" => g["vendor_name"],
        "vendor_gstin" => g["vendor_gstin"],
        "taxable_paise" => g["taxable_paise"] || 0,
        "cgst_paise" => tax(g, "cgst"),
        "sgst_paise" => tax(g, "sgst"),
        "igst_paise" => tax(g, "igst"),
        "total_paise" => g["total_paise"] || 0,
        "bucket" => "in_2b_not_books",
        "bucket_label" => @bucket_labels["in_2b_not_books"],
        "accepted_reason" => nil,
        "verdict" => verdict("in_2b_not_books", entry, []),
        "recon_note" => entry["reason"] && entry["reason"]["message"],
        "next_action" => entry["next_action"],
        "flags" => [],
        "flag_summary" => nil
      }
    end
  end

  defp recon_note("matched", entry) do
    case entry["match_basis"] do
      basis when is_list(basis) -> "matched on " <> Enum.join(basis, " + ")
      _ -> nil
    end
  end

  defp recon_note("value_mismatch", entry) do
    deltas =
      (entry["deltas"] || %{})
      |> Enum.reject(fn {_k, v} -> v == 0 end)
      |> Enum.map_join(", ", fn {k, v} -> "#{k} #{format_delta(v)}" end)

    "differs from 2B: " <> deltas
  end

  defp recon_note(_bucket, entry) do
    entry && entry["reason"] && entry["reason"]["message"]
  end

  defp verdict(_bucket, _entry, [%{"code" => code} | _flags]),
    do: Formatters.issue_label(code)

  defp verdict("in_books_not_2b", %{"accepted_reason" => "await_2b"}, []),
    do: "Awaiting 2B"

  defp verdict("in_books_not_2b", %{"accepted_reason" => "not_claimable"}, []),
    do: "Not claimed this month"

  defp verdict(
         "needs_human",
         %{"reason" => %{"code" => "ambiguous_matches"}} = entry,
         []
       ) do
    case length(entry["candidates"] || []) do
      count when count > 0 -> "#{count} possible 2B matches"
      _count -> Formatters.recon_verdict("ambiguous_matches")
    end
  end

  defp verdict(bucket, entry, []) when bucket in ["matched", "value_mismatch"],
    do: recon_note(bucket, entry)

  defp verdict(_bucket, %{"reason" => %{"code" => code}}, []),
    do: Formatters.recon_verdict(code)

  defp verdict(_bucket, _entry, []), do: nil

  defp format_delta(paise) do
    sign = if paise > 0, do: "+", else: "-"
    sign <> Nila.Formatters.format_money_with_paise(abs(paise))
  end

  defp flag_summary([]), do: nil
  defp flag_summary(flags), do: Enum.map_join(flags, ", ", & &1["code"])

  defp tax(inv, key), do: get_in(inv, ["tax_paise", key]) || 0
end
