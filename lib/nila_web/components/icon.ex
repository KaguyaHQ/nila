defmodule NilaWeb.Components.Icon do
  @moduledoc """
  Heroicon component.
  """
  use Phoenix.Component

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  # Custom glyph: sidebar/rail collapse toggle (panel-left). Not in the heroicons
  # set, so it's drawn inline here rather than masked via the tailwind plugin.
  def icon(%{name: "nila-panel-left"} = assigns) do
    ~H"""
    <svg
      class={@class}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <rect width="18" height="18" x="3" y="3" rx="2" />
      <path d="M9 3v18" />
    </svg>
    """
  end

  def icon(%{name: "nila-whatsapp"} = assigns) do
    ~H"""
    <svg
      class={@class}
      viewBox="0 0 24 24"
      fill="currentColor"
      aria-hidden="true"
      focusable="false"
    >
      <path d="M12 2c5.523 0 10 4.477 10 10s-4.477 10-10 10c-1.89 0-3.66-.525-5.168-1.437l-3.032.891A1.01 1.01 0 0 1 2.546 20.2l.892-3.032A9.96 9.96 0 0 1 2 12C2 6.477 6.477 2 12 2M9.785 7.259a.7.7 0 0 0-.683-.075A2.79 2.79 0 0 0 7.494 9.07l-.007.03c-.038.152-.07.331-.063.526c.025.682.292 2.613 2.314 4.636c2.023 2.022 3.954 2.29 4.636 2.314a2 2 0 0 0 .526-.062l.035-.01a2.78 2.78 0 0 0 1.88-1.6a.7.7 0 0 0-.09-.703c-.533-.683-1.248-1.176-1.884-1.615l-.127-.088a.71.71 0 0 0-.974.157l-.6.915a.23.23 0 0 1-.305.076c-.407-.232-1-.629-1.426-1.055s-.798-.992-1.007-1.372a.23.23 0 0 1 .068-.291l.923-.686a.713.713 0 0 0 .12-.94l-.134-.198c-.42-.62-.912-1.348-1.594-1.845" />
    </svg>
    """
  end
end
