defmodule NilaWeb.Components.Form do
  @moduledoc """
  Settings form actions row, the standard save button, and the moonlight file
  dropzone.
  """
  use Phoenix.Component

  import NilaWeb.Components.Button
  import NilaWeb.Components.Icon

  @doc """
  Renders the standard right-aligned action row for settings forms.
  """
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def form_actions(assigns) do
    ~H"""
    <div class={["flex items-center justify-end gap-2", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Submit button for settings forms. Shows a spinner and `loading` label while the
  form is in flight via `phx-disable-with`, and confirms inline rather than relying
  on a distant flash. Pass `disabled` to gate on a dirty check.
  """
  attr :id, :string, required: true
  attr :label, :string, default: "Save changes"
  attr :loading, :string, default: "Saving…"
  attr :icon, :string, default: "hero-check"
  attr :disabled, :boolean, default: false
  attr :rest, :global

  def save_button(assigns) do
    ~H"""
    <.button
      type="submit"
      id={@id}
      disabled={@disabled}
      phx-disable-with={@loading}
      variant="soft"
      size="sm"
      {@rest}
    >
      <.icon name={@icon} class="size-4" />
      <span>{@label}</span>
    </.button>
    """
  end

  @doc """
  Moonlight file dropzone for a LiveView `allow_upload` config.

  The target remains available while files are selected so multi-entry uploads
  can be built over several drops. Use the `entry` slot for workflow-specific
  controls beneath each file; upload errors remain owned by this component.
  """
  attr :id, :string, required: true
  attr :upload, Phoenix.LiveView.UploadConfig, required: true
  attr :label, :string, default: nil
  attr :hint, :string, default: nil
  attr :prompt, :string, default: "Choose files"
  attr :on_cancel, :string, required: true
  slot :entry

  def file_drop(assigns) do
    ~H"""
    <div class="nila-field" id={@id}>
      <span :if={@label} class="nila-field-label">{@label}</span>

      <.live_file_input upload={@upload} class="sr-only" />

      <label
        for={@upload.ref}
        phx-drop-target={@upload.ref}
        class={[
          "border-base-300 nila-file-drop",
          "rounded-box flex cursor-pointer flex-col items-center justify-center gap-2",
          "border border-dashed px-4 text-center transition-colors",
          if(@upload.entries == [], do: "py-region", else: "py-block")
        ]}
      >
        <.icon name="hero-arrow-up-tray" class="text-ink-faint size-6" />
        <span class="text-ink-muted text-ui">
          <span class="nila-file-accent font-semibold">{@prompt}</span> or drag them here
        </span>
        <span :if={@hint} class="text-ink-muted text-ui">{@hint}</span>
      </label>

      <div :if={@upload.entries != []} class="mt-related space-y-related">
        <div
          :for={entry <- @upload.entries}
          id={"#{@id}-entry-#{entry.ref}"}
          class="bg-base-200/50 border-base-300 py-related rounded-box border px-3"
        >
          <div class="flex items-center gap-3">
            <.icon name="hero-document" class="nila-file-accent size-5 shrink-0" />
            <div class="min-w-0 flex-1">
              <p class="text-base-content text-ui truncate font-medium">{entry.client_name}</p>
              <p class="text-ink-subtle text-ui">
                {humanize_bytes(entry.client_size)}
                <span :if={entry.valid? and entry.progress < 100}> · {entry.progress}% uploaded</span>
              </p>
            </div>
            <button
              type="button"
              phx-click={@on_cancel}
              phx-value-ref={entry.ref}
              aria-label={"Remove #{entry.client_name}"}
              class="nila-file-remove rounded-field text-ink-subtle p-1 transition-colors"
            >
              <.icon name="hero-x-mark" class="size-5" />
            </button>
          </div>

          <div :if={@entry != [] and entry.valid?} class="mt-related pl-8">
            {render_slot(@entry, entry)}
          </div>

          <p
            :for={err <- upload_errors(@upload, entry)}
            class="nila-file-error text-ui mt-1.5 flex items-center gap-2"
          >
            <.icon name="hero-exclamation-circle" class="size-5" />
            {upload_error_message(err)}
          </p>
        </div>
      </div>

      <p
        :for={err <- upload_errors(@upload)}
        class="nila-file-error text-ui mt-1.5 flex items-center gap-2"
      >
        <.icon name="hero-exclamation-circle" class="size-5" />
        {upload_error_message(err)}
      </p>
    </div>
    """
  end

  defp upload_error_message(:too_large), do: "That file is too large."
  defp upload_error_message(:json_too_large), do: "Portal JSON files must be under 20 MB."
  defp upload_error_message(:too_many_files), do: "Too many files at once."
  defp upload_error_message(:not_accepted), do: "Only PDF and JSON files are accepted."
  defp upload_error_message(_), do: "Something went wrong with that file."

  defp humanize_bytes(bytes) when is_integer(bytes) and bytes < 1_024, do: "#{bytes} B"

  defp humanize_bytes(bytes) when is_integer(bytes) do
    {value, unit} =
      cond do
        bytes < 1_048_576 -> {bytes / 1_024, "KB"}
        bytes < 1_073_741_824 -> {bytes / 1_048_576, "MB"}
        true -> {bytes / 1_073_741_824, "GB"}
      end

    "#{:erlang.float_to_binary(value, decimals: 1)} #{unit}"
  end
end
