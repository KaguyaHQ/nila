defmodule NilaWeb.Components.Gst.Exceptions.Modal do
  use NilaWeb, :html

  @moduledoc "Missing-bill modal for the GST exception workbench."

  attr :draft, :any, default: nil
  attr :target, :any, default: nil

  def missing_bill_modal(assigns) do
    ~H"""
    <.modal
      :if={@draft}
      id="gst-missing-bill-modal"
      title="Ask for the missing bill"
      on_close="close-ask"
      target={@target}
      width="wide"
    >
      <pre
        id="gst-missing-bill-draft"
        class="bg-quiet border-rule rounded-box text-base-content text-ui overflow-x-auto border p-4 font-sans whitespace-pre-wrap"
      >{@draft.body}</pre>
      <:footer>
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
          phx-target={@target}
        >Mark as sent</.button>
      </:footer>
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
    </.modal>
    """
  end
end
