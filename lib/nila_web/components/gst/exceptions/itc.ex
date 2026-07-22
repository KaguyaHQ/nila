defmodule NilaWeb.Components.Gst.Exceptions.Itc do
  use NilaWeb, :html

  @moduledoc "ITC presentation for the GST exception workbench."

  attr :itc, :map, required: true
  attr :signed_off, :boolean, required: true

  def itc_panel(%{itc: %{"blocks" => []}} = assigns) do
    ~H"""
    <div
      id="gst-itc-panel"
      class="border-base-300 rounded-box flex items-center justify-between border px-4 py-3"
    >
      <span class="text-base-content/60 text-small">Claimable ITC (2B ceiling, no blocked credits)</span>
      <span class="text-base-content text-body font-mono font-semibold">
        {itc_money(@itc["claimable_paise"])}
      </span>
    </div>
    """
  end

  def itc_panel(assigns) do
    ~H"""
    <div id="gst-itc-panel" class="border-base-300 rounded-box border">
      <div class="border-base-300 flex items-center justify-between border-b px-4 py-3">
        <div>
          <div class="text-base-content/60 text-label font-medium uppercase">Claimable ITC</div>
          <div class="text-base-content/50 text-fine mt-0.5">
            2B ceiling {itc_money(@itc["ceiling_paise"])} − blocked {itc_money(@itc["blocked_paise"])}
          </div>
        </div>
        <div id="gst-itc-claimable" class="text-base-content text-lead font-mono font-semibold">
          {itc_money(@itc["claimable_paise"])}
        </div>
      </div>

      <div class="divide-base-300 divide-y">
        <div
          :for={b <- @itc["blocks"]}
          id={"itc-block-#{b["block_id"]}"}
          class="flex flex-wrap items-center gap-x-3 gap-y-1.5 px-4 py-2.5"
        >
          <span class="text-base-content/40 text-fine w-40 shrink-0 uppercase">
            {issue_label(b["code"])}{if b["section"], do: " · #{b["section"]}"}
          </span>
          <span class="text-base-content text-small min-w-0 flex-1 truncate">
            {b["vendor"]} · {b["invoice_number"] || "—"}
          </span>
          <span class={[
            "text-small w-24 text-right font-mono",
            b["state"] == "blocked" && "text-error",
            b["state"] != "blocked" && "text-base-content/50"
          ]}>
            −{itc_money(b["tax_paise"])}
          </span>
          <span :if={b["state"] == "recommended" and not @signed_off} class="flex gap-1.5">
            <.button
              variant="error"
              size="xs"
              phx-click="block_itc"
              phx-value-block-id={b["block_id"]}
            >
              Block
            </.button>
            <.button
              variant="ghost"
              size="xs"
              phx-click="allow_itc"
              phx-value-block-id={b["block_id"]}
            >
              Keep credit
            </.button>
          </span>
          <span :if={b["state"] == "blocked"} class="flex items-center gap-1.5">
            <span class="text-error text-fine font-medium">Blocked</span>
            <.button
              :if={not @signed_off}
              variant="ghost"
              size="xs"
              phx-click="reopen_block"
              phx-value-block-id={b["block_id"]}
            >Undo</.button>
          </span>
          <span :if={b["state"] == "allowed"} class="flex items-center gap-1.5">
            <span class="text-base-content/50 text-fine font-medium">Credit kept</span>
            <.button
              :if={not @signed_off}
              variant="ghost"
              size="xs"
              phx-click="reopen_block"
              phx-value-block-id={b["block_id"]}
            >Undo</.button>
          </span>
        </div>
      </div>
    </div>
    """
  end

  defp itc_money(paise), do: Nila.Formatters.format_money_with_paise(paise || 0)
end
