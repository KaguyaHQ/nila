defmodule NilaWeb.Components.KeyboardShortcuts do
  use Phoenix.Component
  import NilaWeb.Components.Button
  import NilaWeb.Components.Input

  attr :id, :string, required: true

  def keyboard_shortcuts(assigns) do
    ~H"""
    <div id={@id} phx-hook="KeyboardShortcuts">
      <div
        id={"#{@id}-help"}
        popover="auto"
        role="dialog"
        aria-label="Keyboard shortcuts"
        class="bg-panel-surface border-rule rounded-box shadow-moon m-auto w-96 border p-6"
      >
        <div class="space-y-block">
          <h2 class="text-h4 font-medium">Keyboard shortcuts</h2>

          <dl class="space-y-related text-ui">
            <div class="flex justify-between">
              <dt>Previous month (GST workspace)</dt><dd>[</dd>
            </div>

            <div class="flex justify-between">
              <dt>Next month (GST workspace)</dt><dd>]</dd>
            </div>

            <div class="flex justify-between">
              <dt>Previous invoice (review)</dt><dd>←</dd>
            </div>

            <div class="flex justify-between">
              <dt>Next invoice (review)</dt><dd>→</dd>
            </div>

            <div class="flex justify-between">
              <dt>Show shortcuts</dt><dd>?</dd>
            </div>
          </dl>

          <.input
            id={"#{@id}-enabled"}
            type="checkbox"
            name="shortcuts_enabled"
            checked={true}
            label="Enable keyboard shortcuts"
          />
          <.button
            type="button"
            variant="ghost"
            size="sm"
            popovertarget={"#{@id}-help"}
            popovertargetaction="hide"
          >Close</.button>
        </div>
      </div>
    </div>
    """
  end
end
