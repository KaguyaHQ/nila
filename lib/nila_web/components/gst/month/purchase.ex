defmodule NilaWeb.Components.Gst.Month.Purchase do
  use NilaWeb, :html

  @moduledoc """
  What the engine settled, and the register appendix.

  Neither of these is the working surface. Open decisions are worked in the
  exceptions queue, so this module's whole job is to be *foldable*: one line
  for the settled bills, one disclosure for the full register. Looking at
  correct things is waste, and rendering 23 rows at the same weight as the
  door is what buried the door last time.
  """

  alias Nila.Gst.Purchase.Register

  attr :stats, :any, default: nil
  attr :rows, :list, required: true
  attr :open_folds, :any, default: MapSet.new()

  @doc """
  The settled line: everything the engine closed without a human, folded to a
  sentence with its rupee weight. Expandable, because trust needs a path.
  """
  def settled(assigns) do
    assigns = assign(assigns, :settled_rows, Enum.reject(assigns.rows, &Register.open_row?/1))

    ~H"""
    <.fold
      :if={@settled_rows != []}
      id="month-settled"
      open={MapSet.member?(@open_folds, "month-settled")}
    >
      <:summary>
        <.icon name="hero-check-circle-mini" class="text-success size-4 shrink-0" />
        <span id="month-settled-line" class="flex-1">{settled_line(@settled_rows, @stats)}</span>
      </:summary>

      <.data_table
        id="month-settled-rows"
        class="mt-block"
        rows={@settled_rows}
        row_id={fn row -> "month-settled-#{row["dom_id"]}" end}
        row_click={fn row -> JS.push("select-row", value: %{dom_id: row["dom_id"]}) end}
        min_width="min-w-[680px]"
      >
        <:col :let={row} label="Inv No">
          <span class="font-medium">{row["invoice_number"] || "—"}</span>
        </:col>
        <:col :let={row} label="Vendor">{row["vendor_name"]}</:col>
        <:col :let={row} label="Taxable" align="right">
          {format_money(row["taxable_paise"], prefix: "₹")}
        </:col>
        <:col :let={row} label="Tax" align="right">
          {format_money(Register.row_tax(row), prefix: "₹")}
        </:col>
        <:col :let={row} label="Outcome">
          <span class="text-ink-subtle">{settled_outcome(row)}</span>
        </:col>
      </.data_table>
    </.fold>
    """
  end

  attr :purchase_month, :any, default: nil
  attr :stats, :any, default: nil
  attr :document_flags, :list, default: []
  attr :rows, :list, required: true
  attr :client, :map, required: true
  attr :period, :string, required: true
  attr :open_folds, :any, default: MapSet.new()

  @doc """
  The register appendix: every invoice, in the deliverable's row shape, behind
  a disclosure. Reference material, not the working surface. Clicking a row
  that still needs a decision lands in the queue on that item, so the natural
  click is the correct one.
  """
  def register(assigns) do
    ~H"""
    <.fold
      :if={@purchase_month}
      id="month-register"
      open={MapSet.member?(@open_folds, "month-register")}
    >
      <:summary>
        <.icon name="hero-table-cells" class="text-ink-faint size-4 shrink-0" />
        <span class="flex-1">
          All {@stats.invoices} {if @stats.invoices == 1, do: "invoice", else: "invoices"}, the full register
        </span>
      </:summary>

      <div class="mt-block space-y-block">
        <div :if={@document_flags != []} id="gst-document-flags" class="space-y-related">
          <div
            :for={{flag, index} <- Enum.with_index(@document_flags)}
            id={"gst-document-flag-#{index}"}
            class="border-base-300 rounded-box flex flex-wrap items-center gap-3 border px-4 py-3"
          >
            <span class="text-fine text-ink-subtle font-medium">{issue_label(flag["code"])}</span>
            <span class="text-ink-muted text-small min-w-0 flex-1">{flag["reason"]}</span>
          </div>
        </div>

        <.data_table
          id="gst-register"
          rows={@rows}
          row_id={fn row -> row["dom_id"] end}
          row_click={&row_click(&1, @client, @period)}
          row_class={&row_accent/1}
          min_width="min-w-[880px]"
        >
          <:col :let={row} label="Inv No">
            <div class="flex items-center gap-2">
              <.icon
                :if={Register.open_row?(row)}
                name="hero-exclamation-triangle-mini"
                class="text-warning size-4 shrink-0"
              />
              <span class="font-medium">{row["invoice_number"] || "—"}</span>
            </div>
          </:col>
          <:col :let={row} label="Vendor">{row["vendor_name"]}</:col>
          <:col :let={row} label="Taxable" align="right">
            {format_money(row["taxable_paise"], prefix: "₹")}
          </:col>
          <:col :let={row} label="Tax total" align="right">
            {format_money(Register.row_tax(row), prefix: "₹")}
          </:col>
          <:col :let={row} label="2B status">
            <.badge variant={bucket_variant(row["bucket"])}>{row["bucket_label"]}</.badge>
          </:col>
          <%!-- The note still speaks for any flagged row: an invalid GSTIN on a
                matched bill is worth reading. What the flag no longer buys is
                the ⚠ and the accent, which belong to rows that need a decision. --%>
          <:col :let={row} label="Note" class="max-w-sm">
            <span
              :if={Register.open_row?(row) or row["flags"] not in [nil, []]}
              class="text-base-content text-small block truncate"
            >
              {row["verdict"]}
            </span>
          </:col>
          <%!-- Adjacent rows do different things on click: an open row leaves for
                the exceptions queue, a settled one opens its evidence here. The
                ⚠ and the accent mean severity, not destination, so the row that
                leaves says so. --%>
          <:col :let={row} label="" align="right">
            <.icon
              :if={Register.open_row?(row)}
              name="hero-arrow-right-mini"
              class="text-ink-faint size-4"
            />
          </:col>
          <:empty>The register is empty for this month.</:empty>
        </.data_table>
      </div>
    </.fold>
    """
  end

  # The click follows the work. A row that still needs a decision opens the
  # queue at that item; a settled row opens its evidence, which is all there is
  # left to want from it.
  defp row_click(row, client, period) do
    if Register.open_row?(row) and is_binary(row["id"]) do
      JS.navigate(~p"/gst/#{client.id}/#{period}/exceptions?exception=#{row["id"]}")
    else
      JS.push("select-row", value: %{dom_id: row["dom_id"]})
    end
  end

  defp settled_line(rows, stats) do
    matched = Enum.count(rows, &(&1["bucket"] == "matched"))
    accepted = length(rows) - matched
    tax = stats && stats.matched_tax_paise

    [
      matched > 0 &&
        "#{matched} #{if matched == 1, do: "bill", else: "bills"} matched to 2B, values agree" <>
          if(tax && tax > 0, do: ". #{format_money(tax, prefix: "₹")} ITC", else: ""),
      accepted > 0 && "#{accepted} accepted without a 2B match"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(". ")
    |> Kernel.<>(".")
  end

  defp settled_outcome(%{"accepted_reason" => "await_2b"}), do: "Kept, awaiting the vendor's 2B"
  defp settled_outcome(%{"accepted_reason" => "not_claimable"}), do: "Not claimed this month"
  defp settled_outcome(row), do: row["verdict"] || row["bucket_label"]

  defp bucket_variant("matched"), do: "success"
  defp bucket_variant("needs_human"), do: "warning"
  defp bucket_variant("value_mismatch"), do: "error"
  defp bucket_variant(_), do: "info"

  # Alarm is spent only on rows that need a decision. When any flag painted a
  # row, 10 of 12 were orange and the ₹48,802 GSTIN problem screamed exactly as
  # loud as a ₹107 scooter bill.
  defp row_accent(row) do
    if Register.open_row?(row) do
      "border-l-2 border-l-warning bg-warning/[0.04]"
    else
      "text-ink-muted"
    end
  end
end
