defmodule NilaWeb.Components.Gst.Month.Purchase do
  use NilaWeb, :html

  @moduledoc """
  Purchase reconciliation evidence. Open rows retain their route to the
  exceptions queue; settled rows retain their source-evidence modal.
  """

  alias Nila.Gst.Purchase.Register

  attr :purchase_month, :any, default: nil
  attr :stats, :any, default: nil
  attr :document_flags, :list, default: []
  attr :rows, :list, required: true
  attr :client, :map, required: true
  attr :period, :string, required: true
  slot :source

  @doc "The complete purchase register, always visible as month evidence."
  def register(assigns) do
    ~H"""
    <section :if={@purchase_month} id="month-register" class="space-y-section">
      <div class="space-y-block">
        <div class="gap-related flex flex-wrap items-end justify-between">
          <div>
            <p class="text-eyebrow text-moon font-semibold uppercase">Purchase evidence</p>
            <h2 class="text-base-content text-h4 font-semibold">Purchase reconciliation</h2>
          </div>
          <p class="text-ink-muted text-ui">
            {@stats.invoices} {if @stats.invoices == 1, do: "invoice", else: "invoices"} · complete register
          </p>
        </div>
        {render_slot(@source)}
      </div>

      <div class="space-y-block">
        <div :if={@document_flags != []} id="gst-document-flags" class="space-y-related">
          <div
            :for={{flag, index} <- Enum.with_index(@document_flags)}
            id={"gst-document-flag-#{index}"}
            class="border-base-300 rounded-box flex flex-wrap items-center gap-3 border px-4 py-3"
          >
            <span class="text-ink-subtle text-meta font-medium">{issue_label(flag["code"])}</span>
            <span class="text-body text-ink-muted min-w-0 flex-1">{flag["reason"]}</span>
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
              class="text-base-content block truncate"
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
    </section>
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
