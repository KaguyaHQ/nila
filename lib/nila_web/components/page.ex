defmodule NilaWeb.Components.Page do
  @moduledoc """
  Page and section headers, plus the settings panel surface.
  """
  use Phoenix.Component

  import NilaWeb.Components.Card

  @doc """
  Renders a page header: optional parent context, an operational sans-serif title, optional
  intro copy, and an optional actions cluster aligned to the right on wide
  screens. One page-identity recipe for product lists, forms and workspaces.

  ## Examples

      <.page_header eyebrow="Work Orders" title="Work Orders">
        Every project and LAMC visit, from quote to payment.
        <:actions>
          <.button navigate={~p"/work-orders/new"}>New Work Order</.button>
        </:actions>
      </.page_header>
  """
  attr :eyebrow, :string, default: nil

  attr :eyebrow_path, :string,
    default: nil,
    doc: "makes the eyebrow the page's one link back to its parent"

  attr :title, :string, required: true
  slot :title_control, doc: "interactive page title, such as a period selector"
  slot :inner_block, doc: "intro / supporting copy under the title"
  slot :actions, doc: "page actions aligned to the right"
  slot :title_actions, doc: "navigation directly beside the title, such as filing period arrows"

  def page_header(assigns) do
    ~H"""
    <header class="gap-block flex flex-wrap items-center justify-between">
      <div class="space-y-related">
        <p :if={@eyebrow && @eyebrow != @title} class="text-ink-muted text-ui">
          <.link
            :if={@eyebrow_path}
            navigate={@eyebrow_path}
            class="hover:text-base-content transition"
          >
            {@eyebrow}
          </.link>
          <span :if={is_nil(@eyebrow_path)}>{@eyebrow}</span>
        </p>
        <div class="flex flex-wrap items-center gap-4">
          <h1 class="text-base-content text-page font-medium">
            <%= if @title_control == [] do %>
              {@title}
            <% else %>
              {render_slot(@title_control)}
            <% end %>
          </h1>
          <div :if={@title_actions != []}>{render_slot(@title_actions)}</div>
        </div>
        <p
          :if={@inner_block != []}
          class="text-body text-ink-muted max-w-2xl"
        >
          {render_slot(@inner_block)}
        </p>
      </div>
      <div :if={@actions != []}>{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "gap-section flex items-center justify-between", "pb-block"]}>
      <div>
        <h1 class="text-page font-medium">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-ink-muted text-ui">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders the standard settings page header.
  """
  attr :title, :string, required: true
  slot :inner_block, doc: "intro / supporting copy under the title"
  slot :actions, doc: "buttons aligned to the right on wide screens"

  def settings_header(assigns) do
    ~H"""
    <.page_header eyebrow="Settings" title={@title}>
      {render_slot(@inner_block)}
      <:actions :if={@actions != []}>{render_slot(@actions)}</:actions>
    </.page_header>
    """
  end

  @doc """
  Renders a settings panel using the moonlight card surface, with optional
  title, supporting copy, and actions.
  """
  attr :title, :string, default: nil
  attr :description, :string, default: nil
  attr :class, :any, default: nil
  attr :body_class, :any, default: nil
  attr :rest, :global
  slot :actions
  slot :inner_block, required: true

  def settings_panel(assigns) do
    ~H"""
    <.card class={@class} {@rest}>
      <div
        :if={@title || @description || @actions != []}
        class="mb-block flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between"
      >
        <div>
          <h3 :if={@title} class="text-base-content text-ui font-semibold">{@title}</h3>
          <p :if={@description} class="text-ink-muted text-ui mt-1">
            {@description}
          </p>
        </div>
        <div :if={@actions != []} class="shrink-0">{render_slot(@actions)}</div>
      </div>
      <div class={@body_class}>{render_slot(@inner_block)}</div>
    </.card>
    """
  end
end
