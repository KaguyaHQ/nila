defmodule NilaWeb.Components.Page do
  @moduledoc """
  Page and section headers, plus the settings panel surface.
  """
  use Phoenix.Component

  import NilaWeb.Components.Card

  @doc """
  Renders a page header: an optional eyebrow, a display-serif title, optional
  intro copy, and an optional actions cluster aligned to the right on wide
  screens. The moonlight hero pattern, in one place.

  ## Examples

      <.page_header eyebrow="Work Orders" title="Work Orders">
        Every project and LAMC visit, from quote to payment.
        <:actions>
          <.button navigate={~p"/work-orders/new"}>New Work Order</.button>
        </:actions>
      </.page_header>
  """
  attr :eyebrow, :string, default: nil
  attr :title, :string, required: true
  slot :inner_block, doc: "intro / supporting copy under the title"
  slot :actions, doc: "buttons or stats aligned to the right"

  def page_header(assigns) do
    ~H"""
    <div class="gap-block flex flex-col lg:flex-row lg:items-end lg:justify-between">
      <div class="space-y-related">
        <p :if={@eyebrow} class="text-eyebrow text-moon font-semibold uppercase">
          {@eyebrow}
        </p>
        <h1 class="font-display text-base-content text-h2 font-normal">
          {@title}
        </h1>
        <p
          :if={@inner_block != []}
          class="text-body text-ink-muted max-w-2xl font-light"
        >
          {render_slot(@inner_block)}
        </p>
      </div>
      <div :if={@actions != []}>{render_slot(@actions)}</div>
    </div>
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
        <h1 class="text-h4 font-semibold">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-ink-muted text-small">
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
    <div class="gap-block flex flex-col lg:flex-row lg:items-end lg:justify-between">
      <div class="space-y-related">
        <p class="text-eyebrow text-moon font-semibold uppercase">Settings</p>
        <h1 class="font-display text-base-content text-h2 font-normal">
          {@title}
        </h1>
        <p
          :if={@inner_block != []}
          class="text-body text-ink-muted max-w-2xl font-light"
        >
          {render_slot(@inner_block)}
        </p>
      </div>
      <div :if={@actions != []}>{render_slot(@actions)}</div>
    </div>
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
          <h3 :if={@title} class="text-base-content text-small font-semibold">{@title}</h3>
          <p :if={@description} class="text-ink-muted text-small mt-1">
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
