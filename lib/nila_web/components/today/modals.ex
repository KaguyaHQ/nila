defmodule NilaWeb.Components.Today.Modals do
  use NilaWeb, :html

  @moduledoc "Chase-history and draft-modal presentation for Today."

  attr :chase_history, :any, default: nil
  attr :draft, :any, default: nil

  def modals(assigns) do
    ~H"""
    <.modal
      :if={@chase_history}
      id="today-chase-history-modal"
      title={"Asked #{@chase_history.client_name} · #{@chase_history.period_label}"}
      on_close="close-chase-history"
      class="max-w-2xl"
    >
      <.chase_history asks={@chase_history.asks} />
    </.modal>

    <.modal
      :if={@draft}
      id="chase-draft-modal"
      title={"Ask #{@draft.client_name} · #{@draft.period_label}"}
      on_close="close-draft"
      class="max-w-2xl"
    >
      <div class="space-y-block">
        <pre
          id="chase-draft-body"
          class="bg-base-200/40 border-base-300 rounded-box text-base-content text-small overflow-x-auto border p-4 font-sans whitespace-pre-wrap"
        >{@draft.body}</pre>

        <div class="flex items-center justify-end gap-2">
          <.button
            id="chase-copy-button"
            variant="soft"
            size="sm"
            phx-hook=".CopyDraft"
            type="button"
          >
            <.icon name="hero-clipboard-document" class="size-4" /> Copy
          </.button>
          <.button id="chase-mark-sent" variant="primary" size="sm" phx-click="mark-sent">
            Mark as sent
          </.button>
        </div>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyDraft">
          export default {
            mounted() {
              this.el.addEventListener("click", () => {
                const body = document.getElementById("chase-draft-body")
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
