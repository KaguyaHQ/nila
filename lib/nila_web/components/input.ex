defmodule NilaWeb.Components.Input do
  @moduledoc """
  Form input component with label and error messages, plus error translation
  helpers.
  """
  use Phoenix.Component

  import NilaWeb.Components.Icon

  @doc "Wraps a custom form control in the shared field label and spacing recipe."
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :hide_label, :boolean, default: false
  slot :inner_block, required: true

  def field_shell(assigns) do
    ~H"""
    <div class="nila-field">
      <span id={"#{@id}-label"} class={["nila-field-label", @hide_label && "sr-only"]}>
        {@label}
      </span>
       {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://hexdocs.pm/phoenix_html/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :shortcut, :string, default: nil
  attr :hint, :string, default: nil, doc: "helper text shown under the field"
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :checkbox_value, :any, default: "true", doc: "submitted value for checkbox inputs"
  attr :hidden_input, :boolean, default: true, doc: "include the checkbox's hidden false input"

  attr :checkbox_hit_area, :string,
    default: "default",
    values: ~w(default large),
    doc: "larger click target for standalone checkboxes without increasing their layout size"

  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="nila-field">
      <label
        for={@id}
        class={@checkbox_hit_area == "large" && is_nil(@label) && "nila-checkbox-target"}
      >
        <input
          :if={@hidden_input}
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="nila-checkbox-label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value={@checkbox_value}
            checked={@checked}
            class="nila-checkbox"
            {@rest}
          />{@label}
        </span>
      </label>

      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="nila-field">
      <label for={@id}>
        <span :if={@label} class="nila-field-label">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={["nila-select", @errors != [] && "nila-input-error"]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
           {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>

      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="nila-field">
      <label for={@id}>
        <span :if={@label} class="nila-field-label">{@label}</span> <textarea
          id={@id}
          name={@name}
          class={["nila-textarea", @errors != [] && "nila-input-error"]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>

      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="nila-field">
      <label for={@id}>
        <span :if={@label} class="nila-field-label">{@label}</span>
        <span class={[@shortcut && "group/input-shortcut relative block"]}>
          <input
            type={@type}
            name={@name}
            id={@id}
            value={normalize_value(@type, @value)}
            class={["nila-input", @errors != [] && "nila-input-error", @shortcut && "pr-12"]}
            {@rest}
          />
          <kbd
            :if={@shortcut}
            aria-hidden="true"
            class="bg-quiet border-rule rounded-field text-ink-muted text-label pointer-events-none absolute top-1/2 right-2 inline-flex h-6 min-w-6 -translate-y-1/2 items-center justify-center border px-1.5 font-sans font-medium group-focus-within/input-shortcut:invisible"
          >{@shortcut}</kbd>
        </span>
      </label>

      <p :if={@hint && @errors == []} class="text-ink-subtle text-ui mt-1">{@hint}</p>

      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  defp normalize_value("number", %Decimal{} = value),
    do: Decimal.to_string(value, :normal)

  defp normalize_value("number", value) when is_float(value),
    do: value |> Decimal.from_float() |> Decimal.to_string(:normal)

  defp normalize_value(type, value), do: Phoenix.HTML.Form.normalize_value(type, value)

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="nila-field-error-copy text-ui mt-1.5 flex items-center gap-2">
      <.icon name="hero-exclamation-circle" class="size-5" /> {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Interpolates the `%{key}` placeholders in a changeset error message with the
  values Ecto supplies (e.g. `count`, `max`).
  """
  def translate_error({msg, opts}) do
    Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
      opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end
end
