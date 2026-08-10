defmodule Nila.Gst.Sales.Review do
  @moduledoc """
  Pure invoice rail projection for a worked sales month.

  The rail stays invoice-centric: `all` contains every active source invoice
  that has a derived filing treatment, while `needs_you` contains only invoices
  carrying open actionable work. Progress counts unique issue targets, not
  invoices, and therefore does not change when the visible scope changes.
  Month-level work is reported separately rather than represented as fake rail
  rows.
  """

  alias Nila.Gst.Issues
  alias Nila.Gst.Sales.{Gstr1, Workings}

  @doc "Builds both review scopes and scope-independent lane progress."
  def build(workings) when is_map(workings) do
    invoices = Map.fetch!(workings, :active_invoices)
    issues = workings |> Map.fetch!(:issues) |> Issues.normalize_all()

    items =
      invoices
      |> Enum.flat_map(fn invoice ->
        case treatment_snapshot(invoice, Map.fetch!(workings, :derived)) do
          nil -> []
          treatment -> [item(invoice, treatment, issues, invoices)]
        end
      end)

    actionable_issues =
      issues
      |> Enum.filter(&actionable?/1)
      |> Enum.filter(&(issue_source_ids(&1, invoices) != []))

    all_targets = MapSet.new(actionable_issues, &Workings.issue_key/1)

    open_targets =
      actionable_issues
      |> Enum.filter(&(&1["status"] == "open"))
      |> MapSet.new(&Workings.issue_key/1)

    progress = %{
      completed: MapSet.size(MapSet.difference(all_targets, open_targets)),
      open: MapSet.size(open_targets),
      total: MapSet.size(all_targets)
    }

    month_issue_count =
      issues
      |> Enum.filter(&(&1["status"] == "open" and Issues.gating?(&1)))
      |> Enum.filter(&(issue_source_ids(&1, invoices) == []))
      |> Enum.uniq_by(&Workings.issue_key/1)
      |> length()

    %{
      all: items,
      needs_you: Enum.filter(items, &(&1.open_actionable_targets != [])),
      progress: progress,
      month_issue_count: month_issue_count
    }
  end

  @doc "Returns one of the two rail scopes."
  def scope(review, scope) when scope in [:needs_you, "needs_you"], do: review.needs_you
  def scope(review, scope) when scope in [:all, "all"], do: review.all

  @doc "Canonicalizes an item and scope for the route-backed review surface."
  def route_state(review, source_id, scope_name) do
    selected =
      lookup(review.all, source_id) || List.first(review.needs_you) || List.first(review.all)

    scope_name = valid_scope(scope_name, selected)
    scoped = scope(review, scope_name)
    {scope_name, scoped} = fallback_empty_scope(review, scope_name, scoped)

    selected =
      lookup(scoped, source_id) || (selected && lookup(scoped, selected.source_id)) ||
        List.first(scoped)

    %{scope: scope_name, item: selected && selected.source_id}
  end

  @doc "Selects a requested item in the scope, or its first item when absent."
  def select(review, scope_name, source_id \\ nil) do
    items = scope(review, scope_name)
    lookup(items, source_id) || List.first(items)
  end

  @doc "Finds an invoice rail item by stable source ID."
  def lookup(items, source_id), do: Enum.find(items, &(&1.source_id == source_id))

  @doc "Returns the previous item in the current scope without wrapping."
  def previous(review, scope_name, source_id),
    do: navigate(review, scope_name, source_id, :previous)

  @doc "Returns the next item in the current scope without wrapping."
  def next(review, scope_name, source_id), do: navigate(review, scope_name, source_id, :next)

  @doc "Moves one item in the current scope without wrapping."
  def navigate(review, scope_name, source_id, direction) when direction in [:previous, :next] do
    items = scope(review, scope_name)
    index = Enum.find_index(items, &(&1.source_id == source_id))
    adjacent(items, index, direction)
  end

  @doc """
  Freezes the effective portal treatment for one source invoice.

  The second argument is the current derived GSTR-1. The snapshot deliberately
  records both the total tax and its heads: a later correction or engine change
  must not rewrite what the reviewer challenged.
  """
  def treatment_snapshot(invoice, derived) when is_map(invoice) and is_map(derived) do
    case derived_invoice(derived, invoice) do
      nil ->
        nil

      treatment ->
        amounts =
          treatment
          |> treatment_amounts()
          |> scale_amounts(Gstr1.document_effect(invoice))

        %{
          "source_id" => invoice["id"],
          "invoice_number" => Gstr1.document_number(invoice),
          "buyer_gstin" => invoice["buyer_gstin"],
          "table" => if(Gstr1.document_type(invoice) == "credit_note", do: "cdnr", else: "b2b"),
          "category" => treatment["ntty"] || treatment["inv_typ"],
          "place_of_supply" => treatment["pos"],
          "tax_head" => tax_head(amounts),
          "taxable_amount" => amounts["taxable"],
          "tax_amount" => amounts["igst"] + amounts["cgst"] + amounts["sgst"] + amounts["cess"],
          "tax_amounts" => Map.take(amounts, ~w(igst cgst sgst cess))
        }
    end
  end

  defp item(invoice, treatment, issues, invoices) do
    invoice_issues =
      Enum.filter(issues, &(invoice["id"] in issue_source_ids(&1, invoices)))

    actionable_issues = Enum.filter(invoice_issues, &actionable?/1)
    actionable_targets = actionable_issues |> Enum.map(&Workings.issue_key/1) |> Enum.uniq()

    open_actionable_targets =
      actionable_issues
      |> Enum.filter(&(&1["status"] == "open"))
      |> Enum.map(&Workings.issue_key/1)
      |> Enum.uniq()

    %{
      key: invoice["id"],
      source_id: invoice["id"],
      invoice: invoice,
      treatment: treatment,
      issues: invoice_issues,
      actionable_issues: actionable_issues,
      actionable_targets: actionable_targets,
      open_actionable_targets: open_actionable_targets,
      state: item_state(actionable_targets, open_actionable_targets)
    }
  end

  defp actionable?(issue),
    do: Issues.resolution_kind(issue) in [:decision, :correction, :confirmation]

  defp valid_scope(scope, _selected) when scope in [:needs_you, "needs_you"], do: :needs_you
  defp valid_scope(scope, _selected) when scope in [:all, "all"], do: :all
  defp valid_scope(_scope, %{open_actionable_targets: [_ | _]}), do: :needs_you
  defp valid_scope(_scope, _selected), do: :all

  defp fallback_empty_scope(review, :needs_you, []), do: {:all, review.all}
  defp fallback_empty_scope(_review, scope_name, scoped), do: {scope_name, scoped}

  defp item_state([], []), do: :unreviewed
  defp item_state(_targets, [_ | _]), do: :needs_you
  defp item_state(_targets, []), do: :settled

  defp issue_source_ids(%{"source_ids" => source_ids}, invoices) when is_list(source_ids) do
    active_ids = MapSet.new(invoices, & &1["id"])
    Enum.filter(source_ids, &MapSet.member?(active_ids, &1))
  end

  defp issue_source_ids(%{"source_id" => source_id}, invoices) when is_binary(source_id) do
    if Enum.any?(invoices, &(&1["id"] == source_id)), do: [source_id], else: []
  end

  defp issue_source_ids(%{"invoice" => invoice_number}, invoices)
       when is_binary(invoice_number) do
    invoices
    |> Enum.filter(&(&1["invoice_number"] == invoice_number))
    |> Enum.map(& &1["id"])
  end

  defp issue_source_ids(_issue, _invoices), do: []

  defp derived_invoice(derived, invoice) do
    case Gstr1.document_type(invoice) do
      "credit_note" ->
        derived
        |> Map.get("cdnr", [])
        |> Enum.filter(&(&1["ctin"] == invoice["buyer_gstin"]))
        |> Enum.flat_map(&List.wrap(&1["nt"]))
        |> Enum.find(&(&1["nt_num"] == Gstr1.document_number(invoice)))

      _invoice ->
        derived
        |> Map.get("b2b", [])
        |> Enum.filter(&(&1["ctin"] == invoice["buyer_gstin"]))
        |> Enum.flat_map(&List.wrap(&1["inv"]))
        |> Enum.find(&(&1["inum"] == Gstr1.document_number(invoice)))
    end
  end

  defp treatment_amounts(treatment) do
    treatment
    |> Map.get("itms", [])
    |> Enum.map(&Map.get(&1, "itm_det", %{}))
    |> Enum.reduce(
      %{"taxable" => 0, "igst" => 0, "cgst" => 0, "sgst" => 0, "cess" => 0},
      fn detail, totals ->
        totals
        |> Map.update!("taxable", &(&1 + number(detail["txval"])))
        |> Map.update!("igst", &(&1 + number(detail["iamt"])))
        |> Map.update!("cgst", &(&1 + number(detail["camt"])))
        |> Map.update!("sgst", &(&1 + number(detail["samt"])))
        |> Map.update!("cess", &(&1 + number(detail["csamt"])))
      end
    )
  end

  defp scale_amounts(amounts, effect) do
    Map.new(amounts, fn {key, value} -> {key, value * effect} end)
  end

  defp tax_head(%{"igst" => igst}) when igst != 0, do: "igst"

  defp tax_head(%{"cgst" => cgst, "sgst" => sgst}) when cgst != 0 or sgst != 0,
    do: "cgst_sgst"

  defp tax_head(_amounts), do: "none"

  defp adjacent(_items, nil, _direction), do: nil
  defp adjacent(_items, 0, :previous), do: nil
  defp adjacent(items, index, :previous), do: Enum.at(items, index - 1)
  defp adjacent(items, index, :next), do: Enum.at(items, index + 1)

  defp number(value) when is_number(value), do: value
  defp number(_value), do: 0
end
