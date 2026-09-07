defmodule NilaWeb.Components.Button do
  @moduledoc """
  Radix-calibrated button with navigation support and Nila semantic variants.
  """
  use Phoenix.Component

  import NilaWeb.Components.Icon, only: [icon: 1]

  @doc """
  Renders a button with navigation support.

  The component owns typography and geometry. Callers select only meaning,
  prominence, and whether the control fills its container.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="soft">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global,
    include:
      ~w(href navigate patch method download name value disabled type form target rel popovertarget popovertargetaction)

  attr :variant, :string,
    default: "primary",
    values: ~w(primary soft ghost outline error success neutral)

  attr :size, :string, default: "sm", values: ~w(xs sm lg)
  attr :full_width, :boolean, default: false
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link
        class={["nila-button", @full_width && "w-full"]}
        data-variant={@variant}
        data-size={@size}
        {@rest}
      >
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button
        class={["nila-button", @full_width && "w-full"]}
        data-variant={@variant}
        data-size={@size}
        {@rest}
      >
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  attr :href, :string, required: true
  attr :id, :string, default: nil

  attr :variant, :string,
    default: "primary",
    values: ~w(primary soft ghost outline error success neutral)

  attr :size, :string, default: "sm", values: ~w(xs sm lg)
  attr :full_width, :boolean, default: false
  attr :rest, :global, include: ~w(target rel)
  slot :inner_block, required: true

  @doc "Renders a file download without navigating away from the current LiveView."
  def download_button(assigns) do
    ~H"""
    <.button
      href={@href}
      id={@id}
      variant={@variant}
      size={@size}
      full_width={@full_width}
      download
      {@rest}
    >
      {render_slot(@inner_block)}
    </.button>
    """
  end

  attr :rest, :global, include: ~w(href navigate patch method download target rel)

  attr :class, :any, default: nil
  slot :inner_block, required: true

  @doc "Renders inline accent text navigation with the shared Radix link recipe."
  def text_link(assigns) do
    ~H"""
    <.link class={["nila-link", @class]} {@rest}>
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :id, :string, default: nil
  attr :items, :list, required: true
  attr :selected, :any, required: true
  attr :on_change, :string, required: true
  attr :value_name, :string, required: true
  attr :target, :any, default: nil

  @doc "Renders a compact set of mutually exclusive operational filters."
  def segmented_control(assigns) do
    ~H"""
    <div id={@id} class="nila-segmented">
      <button
        :for={{value, label} <- @items}
        type="button"
        class="nila-segmented-item"
        aria-pressed={to_string(@selected == value)}
        phx-click={@on_change}
        phx-target={@target}
        {value_attribute(@value_name, value)}
      >
        {label}
      </button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :items, :list, required: true
  attr :selected, :any, required: true
  attr :label, :string, required: true
  attr :controls, :string, default: nil
  attr :variant, :string, default: "underline", values: ~w(underline segmented)

  @doc "Renders understated URL-backed navigation tabs with optional counts."
  def navigation_tabs(assigns) do
    ~H"""
    <nav
      id={@id}
      class={if @variant == "segmented", do: "nila-segmented", else: "nila-tabs"}
      aria-label={@label}
    >
      <.link
        :for={item <- @items}
        id={item.id}
        patch={item.patch}
        class={if @variant == "segmented", do: "nila-segmented-item", else: "nila-tab"}
        aria-current={@selected == item.value && "page"}
        aria-controls={@controls}
      >
        <span>{item.label}</span>
        <span class={if @variant == "segmented", do: "tabular-nums", else: "nila-tab-count"}>{item.count}</span>
      </.link>
    </nav>
    """
  end

  attr :id, :string, required: true
  attr :expanded, :boolean, required: true
  attr :label, :string, required: true
  attr :rest, :global
  slot :title, required: true
  slot :detail, required: true

  @doc "Renders a table-row disclosure whose identity and chevron form one target."
  def row_disclosure(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      class="nila-row-disclosure"
      aria-expanded={to_string(@expanded)}
      aria-label={@label}
      {@rest}
    >
      <.icon
        name="hero-chevron-right"
        class={["nila-row-disclosure-icon size-4", @expanded && "rotate-90"]}
      />
      <span class="min-w-0">
        <span class="nila-row-disclosure-title">{render_slot(@title)}</span>
        <span class="nila-row-disclosure-detail">{render_slot(@detail)}</span>
      </span>
    </button>
    """
  end

  defp value_attribute(name, value), do: %{"phx-value-#{name}" => value}
end
