defmodule Nila.Eval.Gstr1Diff do
  @moduledoc """
  Field-level diff of a derived GSTR-1 against a filed return.

  Eval-only — the product never scores itself — but it lives in `lib/` rather
  than a script because the mix task needs it in dev and `mix precommit` needs
  to compile it. Lifted verbatim from the retired script that preceded it;
  `Nila.Eval.bridge/1` reproduces the pre-lift baselines to prove the lift was
  faithful.

  `rows/2` is the contract every surface renders — the markdown report today,
  the workbench's derived-vs-filed mode next. Each row is one compared field:

      %{"scope", "key", "field", "derived", "filed", "match"}

  `score/1` folds rows into the percentage a CA reads. The tolerances and
  ignored fields in `policy/0` shape that number as much as the extraction
  prompt does, so a run record carries them.
  """

  @diff_tolerance 0.01
  @val_tolerance 1.0
  @ignored_invoice_fields ~w(chksum flag updby cflag)

  @invoice_fields ~w(ctin inum idt val pos rchrg inv_typ)
  @item_fields ~w(rt txval camt samt iamt csamt)
  @hsn_fields ~w(hsn_sc rt txval camt samt iamt)
  @doc_fields ~w(from to totnum net_issue cancel)

  @doc """
  The comparison rules, recorded alongside every score.

  `val` gets a wider tolerance because auditor entry convention varies between
  whole-rupee rounding and paise on the invoice total; the ignored fields are
  portal bookkeeping (`chksum` is a hash of the row, `flag`/`updby`/`cflag` are
  filing-state markers) that no derivation can or should reproduce.
  """
  def policy do
    %{
      "tolerance" => @diff_tolerance,
      "val_tolerance" => @val_tolerance,
      "ignored_invoice_fields" => @ignored_invoice_fields
    }
  end

  @doc "Scored diff: `%{score, matches, total, mismatches, rows}`."
  def diff(derived, filed) do
    rows = rows(derived, filed)
    Map.put(score(rows), "rows", rows)
  end

  @doc "One row per compared field, invoice rows first, then HSN, then doc issue."
  def rows(derived, filed) do
    invoice_rows_diff(derived, filed) ++ hsn_diff(derived, filed) ++ doc_diff(derived, filed)
  end

  @doc "Folds rows into the match percentage."
  def score(rows) do
    matches = Enum.count(rows, & &1["match"])
    total = length(rows)

    %{
      "score" => if(total == 0, do: 0.0, else: Float.round(matches * 100 / total, 2)),
      "matches" => matches,
      "total" => total,
      "mismatches" => Enum.reject(rows, & &1["match"])
    }
  end

  defp invoice_rows_diff(derived, filed) do
    derived_rows = invoice_rows(derived)
    filed_rows = invoice_rows(filed)
    keys = (Map.keys(derived_rows) ++ Map.keys(filed_rows)) |> Enum.uniq() |> Enum.sort()

    Enum.flat_map(keys, fn key ->
      derived_row = derived_rows[key] || %{}
      filed_row = filed_rows[key] || %{}

      invoice_checks =
        Enum.map(@invoice_fields, fn field ->
          row("invoice", key, field, derived_row[field], filed_row[field])
        end)

      item_checks =
        Enum.map(@item_fields, fn field ->
          row(
            "invoice_item",
            key,
            field,
            get_in(derived_row, ["itm_det", field]),
            get_in(filed_row, ["itm_det", field])
          )
        end)

      invoice_checks ++ item_checks
    end)
  end

  # One row per (counterparty, invoice, rate) bucket — the grain the portal
  # files at, and the grain a mismatch is argued at.
  defp invoice_rows(gstr1) do
    for ctin_block <- gstr1["b2b"] || [],
        inv <- ctin_block["inv"] || [],
        item <- inv["itms"] || [],
        reduce: %{} do
      acc ->
        key = "#{ctin_block["ctin"]}|#{inv["inum"]}|#{get_in(item, ["itm_det", "rt"])}"

        value =
          inv
          |> Map.drop(@ignored_invoice_fields)
          |> Map.put("ctin", ctin_block["ctin"])
          |> Map.put("itm_det", item["itm_det"] || %{})

        Map.put(acc, key, value)
    end
  end

  defp hsn_diff(derived, filed) do
    derived_rows = hsn_rows(derived)
    filed_rows = hsn_rows(filed)
    keys = (Map.keys(derived_rows) ++ Map.keys(filed_rows)) |> Enum.uniq() |> Enum.sort()

    Enum.flat_map(keys, fn key ->
      Enum.map(@hsn_fields, fn field ->
        row(
          "hsn",
          key,
          field,
          get_in(derived_rows, [key, field]),
          get_in(filed_rows, [key, field])
        )
      end)
    end)
  end

  defp hsn_rows(gstr1) do
    for hsn <- get_in(gstr1, ["hsn", "hsn_b2b"]) || [], reduce: %{} do
      acc -> Map.put(acc, "#{hsn["hsn_sc"]}|#{hsn["rt"]}", hsn)
    end
  end

  defp doc_diff(derived, filed) do
    derived_doc = first_doc(derived)
    filed_doc = first_doc(filed)

    Enum.map(@doc_fields, fn field ->
      row("doc_issue", "doc_issue", field, derived_doc[field], filed_doc[field])
    end)
  end

  defp first_doc(gstr1) do
    get_in(gstr1, ["doc_issue", "doc_det", Access.at(0), "docs", Access.at(0)]) || %{}
  end

  defp row(scope, key, field, derived, filed) do
    %{
      "scope" => scope,
      "key" => key,
      "field" => field,
      "derived" => derived,
      "filed" => filed,
      "match" => equivalent?(field, derived, filed)
    }
  end

  defp equivalent?("val", a, b) when is_number(a) or is_number(b),
    do: close?(a, b, @val_tolerance)

  defp equivalent?(_field, a, b) when is_number(a) or is_number(b),
    do: close?(a, b, @diff_tolerance)

  defp equivalent?(_field, a, b), do: normalize_blank(a) == normalize_blank(b)

  defp close?(a, b, tolerance), do: abs(num(a) - num(b)) <= tolerance + 0.000001

  defp normalize_blank(nil), do: nil
  defp normalize_blank(value) when is_binary(value), do: String.trim(value)
  defp normalize_blank(value), do: value

  defp num(nil), do: 0
  defp num(value) when is_integer(value), do: value / 1
  defp num(value) when is_float(value), do: value

  defp num(value) when is_binary(value) do
    case value |> String.replace(",", "") |> String.replace(~r/[^0-9.\-]/, "") |> Float.parse() do
      {number, _rest} -> number
      :error -> 0
    end
  end
end
