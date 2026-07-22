defmodule NilaWeb.Components.Gst.Exceptions.Modal do
  use NilaWeb, :html

  @moduledoc "Missing-bill modal for the GST exception workbench."

  attr :draft, :any, default: nil

  def missing_bill_modal(assigns) do
    ~H"""
    <.modal
      :if={@draft}
      id="gst-missing-bill-modal"
      title="Ask for the missing bill"
      on_close="close-ask"
      class="max-w-2xl"
    >
      <div class="space-y-4">
        <pre
          id="gst-missing-bill-draft"
          class="bg-base-200/40 border-base-300 rounded-box text-base-content text-small overflow-x-auto border p-4 font-sans whitespace-pre-wrap"
        >{@draft.body}</pre>
        <div class="flex items-center justify-end gap-2">
          <.button
            id="gst-missing-bill-copy"
            variant="soft"
            size="sm"
            phx-hook=".CopyMissingBillDraft"
            type="button"
          >
            <.icon name="hero-clipboard-document" class="size-4" /> Copy
          </.button>
          <.button
            id="gst-missing-bill-mark-sent"
            variant="primary"
            size="sm"
            phx-click="mark-ask-sent"
          >Mark as sent</.button>
        </div>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyMissingBillDraft">
          export default {
            mounted() {
              this.el.addEventListener("click", () => {
                const body = document.getElementById("gst-missing-bill-draft")
                if (body) navigator.clipboard.writeText(body.textContent)
              })
            }
          }
        </script>
      </div>
    </.modal>
    """
  end
end
