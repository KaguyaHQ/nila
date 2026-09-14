defmodule NilaWeb.Components.KeyboardShortcuts do
  use Phoenix.Component
  import NilaWeb.Components.Button
  import NilaWeb.Components.Input
  import NilaWeb.Components.Icon

  attr :id, :string, required: true

  def keyboard_shortcuts(assigns) do
    ~H"""
    <div id={@id} phx-hook="KeyboardShortcuts">
      <div
        id={"#{@id}-help"}
        popover="auto"
        role="dialog"
        aria-labelledby={"#{@id}-title"}
        class="bg-panel-surface border-rule rounded-box shadow-moon m-auto w-full max-w-md overflow-hidden border"
      >
        <div class="flex items-center justify-between gap-4 px-6 pt-6 pb-4">
          <h2 id={"#{@id}-title"} class="text-h4 font-medium">Keyboard shortcuts</h2>
          <.button
            type="button"
            variant="ghost"
            size="sm"
            aria-label="Close keyboard shortcuts"
            popovertarget={"#{@id}-help"}
            popovertargetaction="hide"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </.button>
        </div>

        <div class="space-y-block px-6 pb-6">
          <section aria-labelledby={"#{@id}-workspace"}>
            <h3 id={"#{@id}-workspace"} class="text-ink-muted text-label mb-2 font-medium">
              Workspace
            </h3>
            <dl class="space-y-related text-ui">
              <.shortcut label="Go to…" keys={["Ctrl", "K"]} />
              <.shortcut label="Search list" keys={["/"]} />
              <.shortcut label="Bring in invoices" keys={["U"]} />
              <.shortcut label="Previous / next month" keys={["[", "]"]} paired />
            </dl>
          </section>

          <section aria-labelledby={"#{@id}-review"} class="border-rule border-t pt-4">
            <h3 id={"#{@id}-review"} class="text-ink-muted text-label mb-2 font-medium">
              Invoice review
            </h3>
            <dl class="space-y-related text-ui">
              <.shortcut label="Edit invoice details" keys={["E"]} />
              <.shortcut label="Save changes" keys={["Ctrl", "Enter"]} />
              <.shortcut label="Previous / next invoice" keys={["←", "→"]} paired />
            </dl>
          </section>
        </div>

        <div class="bg-quiet border-rule flex items-center justify-between gap-4 border-t px-6 py-4">
          <.input
            id={"#{@id}-enabled"}
            type="checkbox"
            name="shortcuts_enabled"
            checked={true}
            label="Enable shortcuts"
          />
          <span class="text-ink-muted text-label flex items-center gap-2">
            Show help
            <.keycap>?</.keycap>
          </span>
        </div>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :keys, :list, required: true
  attr :paired, :boolean, default: false

  defp shortcut(assigns) do
    ~H"""
    <div class="flex min-h-8 items-center justify-between gap-4">
      <dt>{@label}</dt>
      <dd class="flex shrink-0 items-center gap-1">
        <%= for {key, index} <- Enum.with_index(@keys) do %>
          <span :if={index > 0} class="text-ink-subtle text-label" aria-hidden="true">
            {if @paired, do: "/", else: "+"}
          </span>
          <.keycap>{key}</.keycap>
        <% end %>
      </dd>
    </div>
    """
  end

  slot :inner_block, required: true

  defp keycap(assigns) do
    ~H"""
    <kbd class="bg-quiet border-rule rounded-field text-label inline-flex h-6 min-w-6 items-center justify-center border px-1.5 font-sans font-medium">
      {render_slot(@inner_block)}
    </kbd>
    """
  end
end
