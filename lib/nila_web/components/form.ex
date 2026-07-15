defmodule NilaWeb.Components.Form do
  @moduledoc """
  Settings form actions row, the standard save button, and the moonlight file
  dropzone.
  """
  use Phoenix.Component

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
    <button
      type="submit"
      id={@id}
      disabled={@disabled}
      phx-disable-with={@loading}
      class="btn btn-primary btn-sm btn-soft transition-all"
      {@rest}
    >
      <.icon name={@icon} class="size-4" />
      <span>{@label}</span>
    </button>
    """
  end

  @doc """
  Moonlight file dropzone for a LiveView `allow_upload` config.

  Renders a styled drag-and-drop target that hides the native file widget: an
  empty state invites a drop or click, and once a file is picked it collapses to
  a chip showing the name, size, and a remove button. Upload errors (too large,
  wrong type, too many) surface inline. Pass `on_cancel` as the `phx-click`
  event name the LiveView handles to drop a selected entry.

  ## Examples

      <.file_drop
        id="gst-upload-bills"
        upload={@uploads.bills}
        label="Purchase bills (PDF)"
        hint="One PDF, up to 50 MB"
        on_cancel="cancel-upload"
      />
  """
  attr :id, :string, required: true
  attr :upload, Phoenix.LiveView.UploadConfig, required: true
  attr :label, :string, required: true
  attr :hint, :string, default: nil
  attr :on_cancel, :string, required: true

  def file_drop(assigns) do
    ~H"""
    <div class="fieldset mb-2" id={@id}>
      <span class="label mb-1">{@label}</span>

      <.live_file_input upload={@upload} class="sr-only" />

      <label
        :if={@upload.entries == []}
        for={@upload.ref}
        phx-drop-target={@upload.ref}
        class={[
          "border-base-300 hover:bg-base-200/60 hover:border-primary/50",
          "[&.phx-drop-target-active]:bg-primary/5 [&.phx-drop-target-active]:border-primary",
          "rounded-box flex cursor-pointer flex-col items-center justify-center gap-2",
          "border border-dashed px-4 py-8 text-center transition-colors"
        ]}
      >
        <.icon name="hero-arrow-up-tray" class="text-base-content/40 size-6" />
        <span class="text-base-content/80 text-small">
          <span class="text-primary font-semibold">Choose a file</span> or drag it here
        </span>
        <span :if={@hint} class="text-base-content/50 text-fine">{@hint}</span>
      </label>

      <div
        :for={entry <- @upload.entries}
        class="bg-base-200/50 border-base-300 rounded-box flex items-center gap-3 border px-3 py-2.5"
      >
        <.icon name="hero-document" class="text-primary size-5 shrink-0" />
        <div class="min-w-0 flex-1">
          <p class="text-base-content text-small truncate font-medium">{entry.client_name}</p>
          <p class="text-base-content/55 text-fine">{humanize_bytes(entry.client_size)}</p>
        </div>
        <button
          type="button"
          phx-click={@on_cancel}
          phx-value-ref={entry.ref}
          aria-label={"Remove #{entry.client_name}"}
          class="hover:bg-error/10 hover:text-error rounded-field text-base-content/50 p-1 transition-colors"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </div>

      <p
        :for={err <- upload_errors(@upload)}
        class="text-error text-small mt-1.5 flex items-center gap-2"
      >
        <.icon name="hero-exclamation-circle" class="size-5" />
        {upload_error_message(err)}
      </p>
    </div>
    """
  end

  defp upload_error_message(:too_large), do: "That file is too large."
  defp upload_error_message(:too_many_files), do: "Only one file here."
  defp upload_error_message(:not_accepted), do: "That file type isn't accepted."
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
