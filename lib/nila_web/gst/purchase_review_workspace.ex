defmodule NilaWeb.Gst.PurchaseReviewWorkspace do
  @moduledoc "Purchase comparison and audited ITC treatment for the React review screen."
  alias Nila.Accounts.Policy
  alias Nila.Gst.Purchase.{ItcDecisions, ItcReviewBasis, ItcTreatment, Review}
  alias NilaWeb.Gst.PurchaseWorkspace, as: Workspace
  import Ecto.Query

  def load(scope, client_id, period, params) do
    with {:ok, data} <- Workspace.load(scope, client_id, period) do
      filter = Workspace.normalize_filter(params["filter"] || "all")
      q = String.slice(params["q"] || "", 0, 200)
      carried = Enum.map(data.carried_cases, &carried_item(&1, data))
      all = data.items ++ carried

      queue =
        Workspace.filter(data.items, filter, q) ++
          if(filter in ~w(all carried treatment needs_review),
            do:
              Enum.filter(carried, fn item ->
                (filter != "needs_review" or not item.resolved or item.treatment_stale?) and
                  Enum.any?(
                    Workspace.filter_carried(data.carried_cases, q),
                    &(&1.case_id in item.treatment_case_ids)
                  )
              end),
            else: []
          )

      item =
        if params["item_id"], do: Review.lookup(all, params["item_id"]), else: List.first(queue)

      if params["item_id"] && is_nil(item),
        do: {:error, :not_found},
        else:
          {:ok,
           Map.merge(data, %{
             scope: scope,
             period: period,
             filter: filter,
             q: q,
             queue: queue,
             item: item
           })}
    end
  end

  def project(c) do
    books_available =
      Workspace.source_rows(c.workings, "register") != [] or
        Enum.any?(
          Nila.Gst.Intake.Dumps.list(c.scope.current_org.id, c.client.id, c.period),
          &(&1.kind == "purchase" and &1.status == "extracted")
        )

    c = Map.put(c, :books_available, books_available)

    c =
      Map.put(
        c,
        :pending_case_ids,
        if(c.month && c.workings,
          do: ItcReviewBasis.pending_case_ids(c.month, c.workings),
          else: MapSet.new()
        )
      )

    lines = if c.workings, do: c.workings.case_lines, else: []
    ids = Enum.flat_map(c.queue ++ List.wrap(c.item), & &1.treatment_case_ids) |> Enum.uniq()
    tokens = if c.month && c.workings, do: ItcReviewBasis.tokens(c.month, c.workings), else: %{}
    editable = Policy.can?(c.scope, :edit_records) and not c.signed_off?

    %{
      client: %{id: c.client.id, name: c.client.name, gstin: c.client.gstin},
      period: c.period,
      month_label: Calendar.strftime(Date.from_iso8601!(c.period <> "-01"), "%B %Y"),
      can_edit: editable,
      lock_reason:
        cond do
          c.signed_off? -> "This month is signed off or filed. Review is read-only."
          not editable -> "Your role cannot change purchase decisions."
          true -> nil
        end,
      filter: c.filter,
      q: c.q,
      books_available: books_available,
      queue: Enum.map(c.queue, &queue_row(c, &1)),
      item: if(c.item, do: item(c, c.item)),
      cases:
        lines
        |> Enum.filter(&(&1.case_id in ids))
        |> Enum.map(&case_row(c, &1, tokens[&1.case_id], editable)),
      reasons:
        Map.new(~w(later exclude), fn kind ->
          {kind,
           Enum.map(ItcDecisions.reasons(kind), fn {id, label} -> %{id: id, label: label} end)}
        end),
      legacy_url: Workspace.list_path(c.client.id, c.period, c.filter, c.q)
    }
  end

  def decide(c, params, action) do
    with true <- Policy.can?(c.scope, :edit_records),
         false <- c.signed_off?,
         ids when is_list(ids) and ids != [] and length(ids) <= 500 <- params["case_ids"],
         true <- Enum.all?(ids, &(is_integer(&1) and &1 > 0)),
         basis when is_map(basis) <- params["basis"],
         :ok <- selected(c, ids),
         {:ok, attrs} <- values(params["values"], action),
         :ok <- split_selection(ids, attrs) do
      opts = [expected_basis: basis]

      case action do
        :treatment ->
          ItcDecisions.apply(c.scope, c.client.id, c.period, ids, attrs, opts)

        :document when length(ids) == 1 ->
          ItcDecisions.record_document(c.scope, c.client.id, c.period, hd(ids), opts)

        _ ->
          {:error, :invalid_selection}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_selection}
    end
  end

  defp selected(c, ids) do
    allowed = Enum.flat_map(c.queue ++ List.wrap(c.item), & &1.treatment_case_ids)
    if Enum.all?(ids, &(&1 in allowed)), do: :ok, else: {:error, :invalid_selection}
  end

  defp split_selection(ids, %{"choice" => "split"}) when length(ids) != 1,
    do: {:error, :invalid_selection}

  defp split_selection(_, _), do: :ok
  defp values(_, :document), do: {:ok, %{}}

  defp values(%{"choice" => choice} = values, :treatment)
       when choice in ~w(claim later exclude split) do
    attrs = Map.take(values, ~w(choice later_reason exclude_reason note))

    if choice == "split" do
      heads =
        Map.new(~w(claim later exclude), fn part ->
          {part,
           Map.new(~w(cgst sgst igst cess), fn head ->
             {head, split_amount(values["split"], part, head)}
           end)}
        end)

      if Enum.any?(heads, fn {_, values} ->
           Enum.any?(values, fn {_, value} -> value == :error end)
         end), do: {:error, :invalid_amount}, else: {:ok, Map.merge(attrs, heads)}
    else
      {:ok, attrs}
    end
  end

  defp values(_, _), do: {:error, :invalid_treatment}

  defp split_amount(split, part, head) when is_map(split) do
    case split[part] do
      values when is_map(values) -> amount(values[head])
      _ -> :error
    end
  end

  defp split_amount(_, _, _), do: :error
  defp amount(nil), do: 0

  defp amount(value) when is_binary(value) do
    if Regex.match?(~r/\A\d{1,13}(?:\.\d{1,2})?\z/, value) do
      [whole | fraction] = String.split(value, ".")

      String.to_integer(whole) * 100 +
        String.to_integer(String.pad_trailing(List.first(fraction) || "0", 2, "0"))
    else
      :error
    end
  end

  defp amount(_), do: :error

  defp queue_row(c, item),
    do: %{
      id: item.id,
      number: item.invoice_number || "—",
      vendor: item.vendor || "—",
      status: review_label(c, item),
      tax: Workspace.money(Map.get(item, :tax_paise, 0)),
      needs_review:
        if(item.kind == :carried,
          do: not item.resolved or item.treatment_stale?,
          else: Workspace.needs_review?(item)
        ),
      case_ids: item.treatment_case_ids
    }

  defp review_label(%{books_available: false}, %{bucket: "2b_only"}), do: "Not compared"
  defp review_label(_, item), do: label(item)

  defp label(%{kind: :carried}), do: "Carried credit"
  defp label(item), do: Workspace.label(item)

  defp carried_item(line, data) do
    portal = carried_source(line, data, "gstr2b")
    books = List.first(line.books_invoices) || carried_source(line, data, "books")

    %{
      id: "case-#{line.case_id}",
      group_key: "case-#{line.case_id}",
      member_ids: [],
      kind: :carried,
      invoice_number: line.invoice_number,
      vendor: line.vendor,
      document_type: line.document_type,
      tax_paise: Enum.sum(Map.values(line.outstanding_heads)),
      reason: "Credit carried from an earlier month.",
      resolved: line.explicit_treatment? and not line.treatment_stale?,
      treatment_stale?: line.treatment_stale?,
      treatment_case_ids: [line.case_id],
      treatment_lines: [line],
      books: books,
      books_members: line.books_invoices,
      counterparts: List.wrap(portal),
      gstr2b: portal,
      candidates: [],
      images:
        Enum.map(
          (books && books["images"]) || [],
          &"/gst/#{data.client.id}/#{books["_source_period"] || line.origin_period}/evidence/#{Path.basename(&1)}"
        )
    }
  end

  defp carried_source(line, data, kind) do
    case (line.source_refs[kind] || %{}) |> Enum.sort(:desc) |> List.first() do
      {period, ref} ->
        source =
          Nila.Repo.one(
            from s in Nila.Gst.Purchase.ItcSource,
              join: m in assoc(s, :client_month),
              where:
                s.org_id == ^data.month.org_id and m.client_id == ^data.client.id and
                  m.period == ^period and s.kind == ^kind and s.source_ref == ^ref
          )

        if source, do: Map.put(source.payload, "_source_period", period)

      _ ->
        nil
    end
  end

  defp case_row(c, line, token, editable) do
    pairing = MapSet.member?(c.pending_case_ids, line.case_id)

    valid =
      line.document_type in ~w(invoice debit_note) and line.settlement_state != "excluded" and
        ItcTreatment.valid?(line.outstanding_heads) and
        ItcTreatment.sum(line.outstanding_heads) > 0

    cess = Nila.Gst.Cess.purchase_issue(line.invoice_date, line.outstanding_heads)

    blocked =
      Enum.any?(
        c.workings.itc["blocks"] || [],
        &Nila.Gst.Purchase.ItcCases.block_applies?(&1, line)
      )

    %{
      id: line.case_id,
      basis: token,
      number: line.invoice_number || "—",
      vendor: line.vendor || "—",
      available: editable and valid and not pairing,
      unavailable_reason:
        cond do
          not editable -> "This working is read-only."
          pairing -> "Resolve the possible pairing before setting ITC treatment."
          not valid -> "This document has no editable outstanding ITC."
          true -> nil
        end,
      claimable: line.claimable? and not blocked and is_nil(cess) and not pairing,
      can_claim_split: line.claimable? and not blocked and not pairing,
      claim_block_reason:
        cond do
          cess -> cess
          blocked -> "Review the credit block before claiming ITC."
          pairing -> "Resolve the possible pairing first."
          true -> line.claim_block_reason
        end,
      cess_issue: cess,
      document_state: line.document_state,
      can_record_document:
        editable and not pairing and line.has_gstr2b? and not line.has_books? and
          line.document_state != "held" and line.document_type in ~w(invoice debit_note),
      heads:
        for(
          head <- ~w(cgst sgst igst cess),
          head != "cess" or line.outstanding_heads["cess"] != 0,
          do: %{
            id: head,
            label: String.upcase(head),
            amount: Workspace.money(line.outstanding_heads[head]),
            value: decimal(line.outstanding_heads[head])
          }
        ),
      values: %{
        choice: if(line.treatment in ~w(claim later exclude split), do: line.treatment),
        later_reason: line.later_reason || "",
        exclude_reason: line.exclude_reason || "",
        note: line.treatment_note || "",
        split:
          Map.new(~w(claim later exclude), fn part ->
            {part,
             Map.new(
               ~w(cgst sgst igst cess),
               &{&1, decimal(get_in(line.treatment_heads || %{}, [part, &1]) || 0)}
             )}
          end)
      }
    }
  end

  defp item(c, item) do
    comparisons = comparisons(item, c.workings.rows)

    %{
      id: item.id,
      number: item.invoice_number || "—",
      vendor: item.vendor || "—",
      document_type: item.document_type,
      status: review_label(c, item),
      reason:
        if(not c.books_available and Map.get(item, :bucket) == "2b_only",
          do: "Purchase register not imported. This entry has not been compared with books.",
          else: item.reason
        ),
      pairing_pending:
        Enum.any?(item.treatment_lines, &MapSet.member?(c.pending_case_ids, &1.case_id)),
      case_ids: item.treatment_case_ids,
      comparisons:
        comparisons
        |> Enum.with_index()
        |> Enum.map(fn {pair, index} ->
          %{
            id: "comparison-#{index}",
            has_books: not is_nil(pair.books),
            has_portal: not is_nil(pair.gstr2b),
            facts: facts(pair.books, pair.gstr2b),
            original_url: original(c, pair.books)
          }
        end),
      images: item.images,
      legacy_url:
        if(item.kind == :carried,
          do: Workspace.list_path(c.client.id, c.period, "carried", c.q),
          else: Workspace.review_path(c.client.id, c.period, item.id, c.filter, c.q)
        )
    }
  end

  defp comparisons(%{candidates: [_ | _]} = item, _), do: item.candidates

  defp comparisons(%{kind: :itc} = item, rows) do
    row =
      Enum.find(
        rows,
        &(&1["invoice_number"] == item.invoice_number and &1["vendor_name"] == item.vendor and
            (&1["document_type"] || "invoice") == item.document_type)
      )

    books =
      if row,
        do:
          Map.put(
            row,
            "tax_paise",
            Map.new(~w(cgst sgst igst cess), &{&1, row[&1 <> "_paise"] || 0})
          )

    [%{books: books, gstr2b: nil}]
  end

  defp comparisons(item, _),
    do: [%{books: item.books, gstr2b: item.gstr2b || List.first(item.counterparts)}]

  defp facts(books, portal) do
    for {label, key} <- [
          {"Supplier", "vendor_name"},
          {"GSTIN", "vendor_gstin"},
          {"Invoice number", "invoice_number"},
          {"Invoice date", "invoice_date"},
          {"Taxable value", "taxable_paise"},
          {"CGST", "cgst"},
          {"SGST", "sgst"},
          {"IGST", "igst"},
          {"CESS", "cess"},
          {"Reported invoice total", "total_paise"}
        ],
        key != "cess" or cess?(books) or cess?(portal) do
      left = fact(books, key)
      right = fact(portal, key)

      %{
        label: label,
        books: left,
        portal: right,
        different: not is_nil(books) and not is_nil(portal) and left != right
      }
    end
  end

  defp fact(nil, _), do: "—"

  defp fact(row, head) when head in ~w(cgst sgst igst cess),
    do: Workspace.money(get_in(row, ["tax_paise", head]) || 0)

  defp fact(row, key) when key in ~w(taxable_paise total_paise),
    do: if(is_nil(row[key]), do: "—", else: Workspace.money(row[key]))

  defp fact(row, key), do: to_string(row[key] || "—")
  defp cess?(nil), do: false
  defp cess?(row), do: (get_in(row, ["tax_paise", "cess"]) || 0) != 0

  defp decimal(value),
    do:
      "#{div(value, 100)}.#{value |> rem(100) |> abs() |> Integer.to_string() |> String.pad_leading(2, "0")}"

  defp original(c, row) do
    case Regex.run(~r/^d(\d+)_excel_\d+$/, (row && row["id"]) || "") do
      [_, id] ->
        case Nila.Gst.Intake.Dumps.fetch(c.scope.current_org.id, String.to_integer(id)) do
          {:ok, dump} when dump.client_id == c.client.id and dump.kind == "purchase" ->
            "/gst/#{c.client.id}/#{dump.period}/original/#{id}/0"

          _ ->
            nil
        end

      _ ->
        nil
    end
  end
end
