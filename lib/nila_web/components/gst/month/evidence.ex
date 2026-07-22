defmodule NilaWeb.Components.Gst.Month.Evidence do
  use NilaWeb, :html

  @moduledoc "Evidence and correction modals for the GST month workbench."

  alias Nila.Gst.Sales.Gstr1
  alias Nila.Gst.Sales.Workings, as: SalesWorkings
  alias NilaWeb.Components.Gst.Month.Helpers

  attr :show_chase_history, :boolean, required: true
  attr :client, :map, required: true
  attr :period, :string, required: true
  attr :asks, :list, required: true
  attr :selected_row, :any, default: nil
  attr :selected_invoice, :any, default: nil
  attr :issues_by_invoice, :map, required: true
  attr :r1_signoff, :any, default: nil
  attr :flagged, :any, required: true
  attr :correcting, :any, default: nil

  def evidence_modals(assigns) do
    ~H"""
    <.modal
      :if={@show_chase_history}
      id="month-chase-history-modal"
      title={"Asked #{@client.name} · #{period_label(@period)}"}
      on_close="close-chase-history"
      class="max-w-2xl"
    >
      <.chase_history asks={@asks} />
    </.modal>

    <.modal
      :if={@selected_row}
      id="gst-evidence-modal"
      title={evidence_title(@selected_row)}
      on_close="close-evidence"
      class="max-w-4xl"
    >
      <div class="grid gap-5 lg:grid-cols-[1fr_20rem]">
        <div id="gst-evidence-images" class="space-y-3">
          <img
            :for={url <- @selected_row["image_urls"]}
            src={url}
            alt="Scanned bill"
            class="border-base-300 rounded-box w-full border"
          />
          <div
            :if={@selected_row["image_urls"] == []}
            class="border-base-300 rounded-box text-base-content/60 text-small flex h-40 items-center justify-center border border-dashed"
          >
            No scanned bill — this line appears in GSTR-2B only.
          </div>
        </div>

        <div id="gst-evidence-why" class="space-y-4">
          <div>
            <div class="text-base-content/60 text-label font-medium uppercase">Vendor</div>
            <div class="text-base-content text-small mt-1 font-medium">
              {@selected_row["vendor_name"]}
            </div>
            <div :if={@selected_row["vendor_gstin"]} class="text-base-content/60 text-fine mt-0.5">
              {@selected_row["vendor_gstin"]}
            </div>
          </div>
          <div :if={@selected_row["recon_note"]}>
            <div class="text-base-content/60 text-label font-medium uppercase">Recon note</div>
            <p class="text-base-content text-small mt-1">{@selected_row["recon_note"]}</p>
          </div>
          <div :if={@selected_row["next_action"]}>
            <div class="text-base-content/60 text-label font-medium uppercase">Next action</div>
            <p class="text-base-content text-small mt-1">{@selected_row["next_action"]}</p>
          </div>
          <div :if={@selected_row["flags"] not in [nil, []]} class="space-y-2">
            <div class="text-base-content/60 text-label font-medium uppercase">Flags</div>
            <div
              :for={flag <- @selected_row["flags"]}
              class="bg-base-200/40 border-base-300 rounded-box border p-3"
            >
              <.badge variant={if flag["severity"] == "error", do: "error", else: "warning"}>
                {issue_label(flag["code"])}
              </.badge>
              <p class="text-base-content/80 text-small mt-2">{flag["reason"]}</p>
            </div>
          </div>
        </div>
      </div>
    </.modal>

    <.modal
      :if={@selected_invoice}
      id="gstr1-evidence-modal"
      title={@selected_invoice["invoice_number"] || "Invoice"}
      on_close="close-evidence"
      class="max-w-4xl"
    >
      <div class="grid gap-5 lg:grid-cols-[1fr_20rem]">
        <div id="gstr1-evidence-images" class="space-y-3">
          <img
            :for={url <- @selected_invoice["image_urls"]}
            src={url}
            alt="Scanned sales bill"
            class="border-base-300 rounded-box w-full border"
          />
          <div
            :if={@selected_invoice["image_urls"] == []}
            class="border-base-300 rounded-box text-base-content/60 text-small flex h-40 items-center justify-center border border-dashed"
          >
            No page image for this invoice.
          </div>
        </div>

        <div class="space-y-4">
          <div>
            <div class="text-base-content/60 text-label font-medium uppercase">Buyer</div>
            <div class="text-base-content text-small mt-1 font-medium">
              {@selected_invoice["buyer_name"] || "—"}
            </div>
            <div class="text-base-content/60 text-fine mt-0.5 font-mono">
              {@selected_invoice["buyer_gstin"] || "—"}
            </div>
          </div>

          <div
            :if={Helpers.invoice_issues(@issues_by_invoice, @selected_invoice) != []}
            class="space-y-2"
          >
            <div class="text-base-content/60 text-label font-medium uppercase">Issues</div>
            <div
              :for={issue <- Helpers.invoice_issues(@issues_by_invoice, @selected_invoice)}
              class="bg-base-200/40 border-base-300 rounded-box border p-3"
            >
              <.badge variant={
                if issue["status"] == "resolved",
                  do: "success",
                  else: Helpers.severity_variant(issue["level"])
              }>
                {issue_label(issue["code"])}
              </.badge>
              <p class="text-base-content/80 text-small mt-2 line-clamp-2">{issue["message"]}</p>
              <div class="mt-2">
                <.button
                  :if={issue["status"] == "open" and is_nil(@r1_signoff)}
                  variant="outline"
                  size="xs"
                  phx-click="confirm_issue"
                  phx-value-target={SalesWorkings.issue_key(issue)}
                >
                  Checked against the bill — it's fine
                </.button>
                <span :if={issue["status"] == "resolved"} class="flex items-center gap-1.5">
                  <span class="text-fine text-success font-medium">Confirmed</span>
                  <.button
                    :if={is_nil(@r1_signoff)}
                    variant="ghost"
                    size="xs"
                    phx-click="undo"
                    phx-value-target={SalesWorkings.issue_key(issue)}
                  >Undo</.button>
                </span>
              </div>
            </div>
          </div>

          <div
            :if={Gstr1.correctable_fields(@flagged, @selected_invoice["pristine_inum"]) != []}
            id="gstr1-corrections"
            class="space-y-2"
          >
            <div class="text-base-content/60 text-label font-medium uppercase">Flagged fields</div>
            <%= for field <- Gstr1.correctable_fields(@flagged, @selected_invoice["pristine_inum"]) do %>
              <%= if @correcting && @correcting.field == field do %>
                <form phx-submit="save_correct" class="flex items-end gap-2">
                  <.input type="hidden" name="field" id="gstr1-correct-field" value={field} />
                  <div class="flex-1">
                    <.input
                      type="text"
                      name="value"
                      value={@correcting.value}
                      label={field}
                      id="gstr1-correct-value"
                    />
                  </div>
                  <.button type="submit" variant="primary" size="sm">Save</.button>
                  <.button type="button" variant="ghost" size="sm" phx-click="cancel_correct">Cancel</.button>
                </form>
              <% else %>
                <div class="flex items-center justify-between gap-2">
                  <span class="text-base-content/70 text-small min-w-0 truncate font-mono">
                    {field} = {to_string(Gstr1.field_value(@selected_invoice, field))}
                  </span>
                  <.button variant="ghost" size="xs" phx-click="start_correct" phx-value-field={field}>
                    Correct
                  </.button>
                </div>
              <% end %>
            <% end %>
            <p class="text-base-content/50 text-fine">
              Only fields Nila flagged are correctable — fixing anything else would be a silent error.
            </p>
          </div>
        </div>
      </div>
    </.modal>
    """
  end

  defp evidence_title(row) do
    [row["invoice_number"], row["vendor_name"]]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
    |> case do
      "" -> "Evidence"
      title -> title
    end
  end
end
