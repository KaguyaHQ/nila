defmodule NilaWeb.Components.List do
  @moduledoc """
  Data list, selectable list item, and the newline-preserving text helper.
  """
  use Phoenix.Component

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a tokenized selectable row for settings side lists.
  """
  attr :active, :boolean, default: false
  attr :type, :string, default: "button"
  attr :class, :any, default: nil
  attr :rest, :global
  slot :title, required: true
  slot :subtitle

  def selectable_list_item(assigns) do
    ~H"""
    <button
      type={@type}
      class={[
        "rounded-field text-small w-full border border-l-4 px-3 py-2 text-left transition-all",
        @active &&
          "bg-primary/10 border-l-primary border-primary/30 text-primary",
        !@active &&
          "bg-base-100 border-base-300 border-l-base-300 hover:bg-base-200 hover:border-l-primary/40 hover:border-primary/30 hover:text-ink text-ink-muted",
        @class
      ]}
      {@rest}
    >
      <span class="block truncate font-medium">{render_slot(@title)}</span>
      <span :if={@subtitle != []} class="text-fine mt-0.5 block truncate opacity-70">
        {render_slot(@subtitle)}
      </span>
    </button>
    """
  end

  @doc """
  Renders user- or model-supplied text with its literal newlines preserved.

  Always use this instead of putting `whitespace-pre-wrap` on a block element
  (`<div>`, `<p>`, …) wrapped around a bare interpolation. `whitespace-pre-wrap`
  makes every space and newline significant — so when the interpolation sits on
  its own indented line, the template's indentation renders as blank lines and a
  leading indent *inside* the element. Worse, `mix format` re-indents block
  content into exactly that shape, so the bug silently returns after every
  format. Keeping the class on an **inline** span with the value tight against
  the tags (`<span>{@text}</span>`) is formatter-proof: there is no incidental
  whitespace to render, and the formatter leaves inline content alone.

  Pass `class` to add type/color utilities; the container (bubble, `<pre>`, etc.)
  stays the caller's responsibility.

  ## Examples

      <div class="rounded-box bg-primary px-3 py-1.5 text-small text-primary-content">
        <.preserve_newlines text={@message} />
      </div>
  """
  attr :text, :string, required: true
  attr :class, :any, default: nil

  def preserve_newlines(assigns) do
    ~H"""
    <span class={["whitespace-pre-wrap", @class]}>{@text}</span>
    """
  end
end
