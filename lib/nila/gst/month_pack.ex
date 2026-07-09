defmodule Nila.Gst.MonthPack do
  @moduledoc """
  Assembles the month-pack data: the narrative document a partner reads —
  cover summary, reconciliation story, catches, corrections trace, confession
  sheet, and evidence appendix — from the register rows, recon result, flags,
  and corrections.

  Pure and presentation-ready: every money value is formatted here (via
  `Nila.Formatters`) so the Typst template positions text and nothing else.
  Verdict language stays within the locked rules: traces not verdicts, no
  synthesized eligibility number, confessed judgment.
  """

  alias Nila.Formatters

  def build(register_rows, recon, corrections, meta, filed_3b \\ nil) do
    books_rows = Enum.reject(register_rows, &(&1["bucket"] == "in_2b_not_books"))
    g2b_only = Enum.filter(register_rows, &(&1["bucket"] == "in_2b_not_books"))

    %{
      "meta" => meta,
      "cover" => cover(books_rows, g2b_only, recon, corrections),
      "register" => Enum.map(register_rows, &register_line/1),
      "exceptions" => exceptions(register_rows),
      "catches" => catches(books_rows),
      "corrections" => Enum.map(corrections, &correction_line/1),
      "confession" => confession(register_rows),
      "itc" => itc(books_rows, recon, filed_3b),
      "appendix" => appendix(register_rows)
    }
  end

  defp cover(books_rows, g2b_only, recon, corrections) do
    buckets = Enum.frequencies_by(books_rows, & &1["bucket"])
    matched = buckets["matched"] || 0

    flag_count =
      books_rows |> Enum.flat_map(& &1["flags"]) |> length()

    %{
      "invoice_count" => length(books_rows),
      "matched_count" => matched,
      "value_mismatch_count" => buckets["value_mismatch"] || 0,
      "needs_human_count" => buckets["needs_human"] || 0,
      "not_in_2b_count" => buckets["in_books_not_2b"] || 0,
      "in_2b_only_count" => length(g2b_only),
      "flag_count" => flag_count,
      "correction_count" => length(corrections),
      "taxable_total" => books_rows |> sum("taxable_paise") |> money(),
      "matched_tax_total" =>
        recon["matched"]
        |> Enum.map(fn e -> tax_sum(e["books"]) end)
        |> Enum.sum()
        |> money()
    }
  end

  defp register_line(row) do
    %{
      "inum" => row["invoice_number"] || "—",
      "date" => date(row["invoice_date"]),
      "vendor" => row["vendor_name"] || "—",
      "gstin" => row["vendor_gstin"],
      "taxable" => money(row["taxable_paise"]),
      "tax" => money(row["cgst_paise"] + row["sgst_paise"] + row["igst_paise"]),
      "total" => money(row["total_paise"]),
      "bucket" => row["bucket_label"],
      "flags" => row["flag_summary"],
      "pages" => pages_label(row["pages"])
    }
  end

  defp exceptions(rows) do
    for row <- rows, row["bucket"] not in ["matched"], row["bucket"] != nil do
      %{
        "inum" => row["invoice_number"] || "—",
        "vendor" => row["vendor_name"] || "—",
        "amount" => money(row["total_paise"]),
        "bucket" => row["bucket_label"],
        "note" => row["recon_note"],
        "next_action" => distinct_action(row["next_action"], row["recon_note"]),
        "pages" => pages_label(row["pages"])
      }
    end
  end

  defp distinct_action(nil, _note), do: nil

  defp distinct_action(action, note) when is_binary(action) and is_binary(note) do
    if String.contains?(action, note), do: nil, else: action
  end

  defp distinct_action(action, _note), do: action

  defp catches(books_rows) do
    for row <- books_rows, flag <- row["flags"] do
      %{
        "inum" => row["invoice_number"] || "—",
        "vendor" => row["vendor_name"] || "—",
        "severity" => flag["severity"],
        "code" => flag["code"],
        "reason" => flag["reason"],
        "section" => flag["section"],
        "pages" => pages_label(row["pages"])
      }
    end
    |> Enum.sort_by(&severity_rank(&1["severity"]))
  end

  defp correction_line(c) do
    %{
      "inum" => c["invoice"],
      "field" => c["field"],
      "why" => c["why"]
    }
  end

  defp confession(rows) do
    review_rows =
      for row <- rows, flag <- row["flags"], flag["severity"] == "review" do
        %{
          "inum" => row["invoice_number"] || "—",
          "vendor" => row["vendor_name"] || "—",
          "what" => flag["code"],
          "why" => flag["reason"],
          "pages" => pages_label(row["pages"])
        }
      end

    recon_rows =
      for row <- rows, row["bucket"] == "needs_human" do
        %{
          "inum" => row["invoice_number"] || "—",
          "vendor" => row["vendor_name"] || "—",
          "what" => "reconciliation",
          "why" => row["recon_note"],
          "pages" => pages_label(row["pages"])
        }
      end

    review_rows ++ recon_rows
  end

  defp itc(books_rows, recon, filed_3b) do
    matched_2b = recon["matched"] |> Enum.map(&tax_sum(&1["gstr2b"])) |> Enum.sum()

    in_2b_only_tax =
      recon["in_2b_not_books"]
      |> Enum.map(&tax_sum(&1["gstr2b"] || &1))
      |> Enum.sum()

    all_2b =
      (recon["matched"] ++ recon["value_mismatch"])
      |> Enum.map(&tax_sum(&1["gstr2b"]))
      |> Enum.sum()
      |> Kernel.+(in_2b_only_tax)
      |> Kernel.+(awaiting_2b_tax(recon))

    flagged =
      for row <- books_rows,
          flag <- row["flags"],
          flag["code"] in ["personal_expense_17_5", "duplicate_invoice", "gstin_state_mismatch"] do
        %{
          "inum" => row["invoice_number"] || "—",
          "vendor" => row["vendor_name"] || "—",
          "tax" => money(row["cgst_paise"] + row["sgst_paise"] + row["igst_paise"]),
          "code" => flag["code"],
          "section" => flag["section"],
          "reason" => flag["reason"]
        }
      end

    base = %{
      "matched_tax" => money(matched_2b),
      "awaiting_tax" => money(awaiting_2b_tax(recon)),
      "in_2b_only_tax" => money(in_2b_only_tax),
      "total_2b_tax" => money(all_2b),
      "flagged" => flagged,
      "filed_3b" => nil,
      "filed_matches_2b" => nil
    }

    case filed_3b do
      nil ->
        base

      %{"itc" => %{"net_itc_4c" => net}} ->
        filed_total = (net["igst"] || 0) + (net["cgst"] || 0) + (net["sgst"] || 0)

        %{
          base
          | "filed_3b" => money(filed_total),
            "filed_matches_2b" => filed_total == all_2b
        }
    end
  end

  # GST on 2B invoices that recon routed to human (deduped: ambiguous pairs
  # list the same 2B candidate from both books rows).
  defp awaiting_2b_tax(recon) do
    recon["needs_human"]
    |> Enum.flat_map(fn e ->
      case e["candidates"] |> List.wrap() |> List.first() || e["gstr2b"] do
        nil -> []
        g -> [g]
      end
    end)
    |> Enum.uniq_by(fn g -> {g["vendor_gstin"], g["invoice_number"]} end)
    |> Enum.map(&tax_sum/1)
    |> Enum.sum()
  end

  defp appendix(rows) do
    interesting =
      for row <- rows,
          row["images"] != [],
          row["flags"] != [] or row["bucket"] not in ["matched", nil] do
        %{
          "inum" => row["invoice_number"] || "—",
          "vendor" => row["vendor_name"] || "—",
          "bucket" => row["bucket_label"],
          "flags" => row["flag_summary"],
          "images" => row["images"]
        }
      end

    Enum.uniq_by(interesting, & &1["inum"])
  end

  defp severity_rank("error"), do: 0
  defp severity_rank("warning"), do: 1
  defp severity_rank(_), do: 2

  defp sum(rows, key), do: rows |> Enum.map(&(&1[key] || 0)) |> Enum.sum()

  defp tax_sum(inv) do
    tax = inv["tax_paise"] || %{}
    (tax["cgst"] || 0) + (tax["sgst"] || 0) + (tax["igst"] || 0)
  end

  defp money(paise), do: Formatters.format_money_with_paise(paise || 0)

  defp date(nil), do: "—"
  defp date(%Date{} = d), do: Calendar.strftime(d, "%d-%m-%Y")
  defp date(s) when is_binary(s), do: s

  defp pages_label([]), do: "—"
  defp pages_label(pages), do: "p." <> Enum.map_join(pages, ",", &to_string/1)
end
