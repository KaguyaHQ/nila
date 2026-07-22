defmodule NilaWeb.Components.Gst.Month.Purchase do
  use NilaWeb, :html

  @moduledoc "Purchase-register presentation for the GST month workbench."

  attr :purchase_month, :any, default: nil
  attr :stats, :any, default: nil
  attr :rows, :list, required: true
  attr :client, :map, required: true
  attr :period, :string, required: true

  def purchase_section(assigns) do
    ~H"""
    <section :if={@purchase_month} id="month-purchases" class="scroll-mt-28 space-y-4">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 class="text-base-content font-semibold">Purchases — 2B reconciliation</h2>
          <p id="gst-stats" class="text-base-content/60 text-small">
            <span id="gst-stat-invoices">{@stats.invoices}</span>
            invoices · <span id="gst-stat-matched">{@stats.matched}</span>
            matched to 2B ·
            <span class={@stats.need_decision > 0 && "text-warning font-medium"}>
              <span id="gst-stat-need-decision">{@stats.need_decision}</span> need a decision
            </span>
          </p>
        </div>
      </div>

      <.data_table
        id="gst-register"
        sticky_header="xl:top-16"
        rows={@rows}
        row_id={fn row -> row["dom_id"] end}
        row_click={fn row -> JS.push("select-row", value: %{dom_id: row["dom_id"]}) end}
        row_class={&row_accent/1}
        min_width="min-w-[880px]"
      >
        <:col :let={row} label="Inv No">
          <div class="flex items-center gap-2">
            <.icon
              :if={attention?(row)}
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
          {format_money(
            (row["cgst_paise"] || 0) + (row["sgst_paise"] || 0) + (row["igst_paise"] || 0),
            prefix: "₹"
          )}
        </:col>
        <:col :let={row} label="2B status">
          <.badge variant={bucket_variant(row["bucket"])}>{row["bucket_label"]}</.badge>
        </:col>
        <:col :let={row} label="Note" class="max-w-sm">
          <span
            :if={row["bucket"] != "matched" or row["flags"] not in [nil, []]}
            class="text-base-content text-small block truncate"
          >
            {row["verdict"]}
          </span>
        </:col>
      </.data_table>
    </section>

    <div
      :if={!@purchase_month}
      id="month-purchases-missing"
      class="border-base-300 rounded-box text-base-content/60 text-small flex scroll-mt-28 flex-wrap items-center gap-2 border border-dashed px-4 py-2.5"
    >
      <span class="flex-1">Purchase bills not in yet — the 2B reconciliation and the 3B need them.</span>
      <.link
        navigate={~p"/gst/upload?client_id=#{@client.id}&period=#{@period}"}
        class="text-moon font-semibold"
      >
        Bring them in →
      </.link>
    </div>
    """
  end

  defp bucket_variant("matched"), do: "success"
  defp bucket_variant("needs_human"), do: "warning"
  defp bucket_variant("value_mismatch"), do: "error"
  defp bucket_variant(_), do: "info"

  defp attention?(row), do: row["bucket"] == "needs_human" or row["flags"] not in [nil, []]

  defp row_accent(row) do
    cond do
      row["bucket"] == "needs_human" ->
        "border-l-2 border-l-warning bg-warning/[0.03]"

      row["bucket"] in ["value_mismatch", "in_2b_not_books", "in_books_not_2b"] ->
        "border-l-2 border-l-error/70 bg-error/[0.03]"

      row["flags"] not in [nil, []] ->
        "border-l-2 border-l-warning/60"

      true ->
        "text-base-content/75"
    end
  end
end
