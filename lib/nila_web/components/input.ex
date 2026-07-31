defmodule NilaWeb.Components.Input do
  @moduledoc """
  Form input component with label and error messages, plus error translation
  helpers.
  """
  use Phoenix.Component

  import NilaWeb.Components.Icon

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
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

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
    <div class="fieldset mb-2">
      <label for={@id}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox checkbox-sm"}
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
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[@class || "select w-full", @errors != [] && (@error_class || "select-error")]}
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
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class || "textarea w-full",
            @errors != [] && (@error_class || "textarea-error")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "password"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label :if={@label} for={@id} class="label mb-1">{@label}</label>
      <div class="relative">
        <input
          type="password"
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value("password", @value)}
          class={[
            @class || "input w-full",
            "pr-12",
            @errors != [] && (@error_class || "input-error")
          ]}
          {@rest}
        />
        <button
          type="button"
          id={"#{@id}-toggle"}
          aria-label="Show password"
          aria-controls={@id}
          aria-pressed="false"
          class="focus:ring-primary/40 hover:text-ink rounded-r-field text-ink-subtle absolute inset-y-0 right-0 z-10 inline-flex w-11 items-center justify-center transition focus:ring-2 focus:outline-none"
          phx-hook=".PasswordVisibility"
          data-password-input={@id}
        >
          <.icon name="hero-eye" class="size-5" />
        </button>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".PasswordVisibility">
          export default {
            mounted() {
              this.el.addEventListener("mousedown", event => event.preventDefault())

              this.el.addEventListener("click", () => {
                const input = document.getElementById(this.el.dataset.passwordInput)
                if (!input) return

                const showingPassword = input.type === "text"
                input.type = showingPassword ? "password" : "text"
                input.focus()
                this.el.setAttribute("aria-label", showingPassword ? "Show password" : "Hide password")
                this.el.setAttribute("aria-pressed", showingPassword ? "false" : "true")
              })
            }
          }
        </script>
      </div>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Native `type="date"` paints the browser's own calendar popup — unstylable and
  # foreign to the design system. We render a moonlight text input the operator
  # types as DD/MM/YYYY, backed by a server-rendered hidden field that keeps the
  # ISO contract (`2026-06-11`) the form and tests consume. The `.DateField` hook
  # masks keystrokes and syncs the hidden value; first paint is correct without JS.
  def input(%{type: "date"} = assigns) do
    iso =
      case assigns[:value] do
        nil -> ""
        %Date{} = d -> Date.to_iso8601(d)
        v -> to_string(v)
      end

    assigns = assign(assigns, iso: iso, display: date_display(iso))

    ~H"""
    <div class="fieldset mb-2" id={"#{@id}-field"} phx-hook=".DateField">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <input
          type="text"
          id={@id}
          value={@display}
          inputmode="numeric"
          autocomplete="off"
          placeholder="DD/MM/YYYY"
          maxlength="10"
          phx-update="ignore"
          data-date-display
          class={[
            @class || "input w-full",
            @errors != [] && (@error_class || "input-error")
          ]}
          {@rest}
        />
      </label>
      <%!-- Carrier of the submitted ISO value, driven by the hook. Tests set it via
            the explicit value arg of render_change/render_submit (the sanctioned path
            for hook-set hidden fields), since the masking hook can't run server-side. --%>
      <input type="hidden" name={@name} value={@iso} data-date-value />
      <p :if={@hint && @errors == []} class="text-fine text-ink-subtle mt-1">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".DateField">
        export default {
          mounted() {
            this.display = this.el.querySelector("[data-date-display]")
            this.hidden = this.el.querySelector("[data-date-value]")
            this.sync()
            this.display.addEventListener("input", () => this.onType())
            this.display.addEventListener("blur", () => this.sync())
            // Pre-filled with today's date; select all on focus so the first
            // keystroke overwrites it (fast keyboard entry of historical dates).
            this.display.addEventListener("focus", () => this.display.select())
          },

          // Server re-renders (draft restore, save reset) move the hidden ISO;
          // mirror it back to the visible field unless the user is mid-entry.
          updated() {
            if (document.activeElement !== this.display) this.sync()
          },

          onType() {
            const digits = this.display.value.replace(/\D/g, "").slice(0, 8)
            let out = digits.slice(0, 2)
            if (digits.length >= 3) out += "/" + digits.slice(2, 4)
            if (digits.length >= 5) out += "/" + digits.slice(4, 8)
            this.display.value = out
            this.setHidden(this.toISO(digits))
          },

          setHidden(iso) {
            if (this.hidden.value === iso) return
            this.hidden.value = iso
            // Bubble to the form so phx-change ("validate") and the draft guard fire.
            this.hidden.dispatchEvent(new Event("input", {bubbles: true}))
          },

          toISO(digits) {
            if (digits.length !== 8) return ""
            const dd = digits.slice(0, 2), mm = digits.slice(2, 4), yyyy = digits.slice(4)
            const y = +yyyy, m = +mm, d = +dd
            const dt = new Date(y, m - 1, d)
            if (dt.getFullYear() !== y || dt.getMonth() !== m - 1 || dt.getDate() !== d) return ""
            return `${yyyy}-${mm}-${dd}`
          },

          // hidden ISO -> visible DD/MM/YYYY
          sync() {
            const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(this.hidden.value)
            this.display.value = m ? `${m[3]}/${m[2]}/${m[1]}` : ""
          },
        }
      </script>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || "input w-full",
            @errors != [] && (@error_class || "input-error")
          ]}
          {@rest}
        />
      </label>
      <p :if={@hint && @errors == []} class="text-fine text-ink-subtle mt-1">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # ISO `2026-06-11` -> the operator-facing `11/06/2026`. Passes through anything
  # that isn't a well-formed ISO date so a bad value stays visible, not swallowed.
  defp date_display(iso) when is_binary(iso) do
    case Regex.run(~r/^(\d{4})-(\d{2})-(\d{2})/, iso) do
      [_, y, m, d] -> "#{d}/#{m}/#{y}"
      _ -> iso
    end
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="text-error text-small mt-1.5 flex items-center gap-2">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
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
