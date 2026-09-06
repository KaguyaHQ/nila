defmodule NilaWeb.Components.Form do
  @moduledoc """
  Settings form actions, the standard save button, and Nila's shared document
  importer primitives.
  """
  use Phoenix.Component

  import NilaWeb.Components.Button
  import NilaWeb.Components.Card
  import NilaWeb.Components.Feedback
  import NilaWeb.Components.Icon
  import NilaWeb.Components.Page

  @doc """
  Renders the shared domain importer operation: page hierarchy, form card,
  dropzone, error, and primary action. Callers provide only domain fields and
  any state that temporarily replaces the form.
  """
  attr :id, :string, required: true
  attr :eyebrow, :string, required: true
  attr :eyebrow_path, :string, default: nil
  attr :title, :string, required: true
  attr :form, :any, required: true
  attr :form_id, :string, required: true
  attr :show_form, :boolean, default: true
  attr :upload, Phoenix.LiveView.UploadConfig, required: true
  attr :upload_id, :string, required: true
  attr :upload_label, :string, required: true
  attr :upload_hint, :string, required: true
  attr :upload_prompt, :string, default: "Choose files"
  attr :error, :string, default: nil
  attr :error_id, :string, required: true
  attr :submit_id, :string, required: true
  attr :submit_label, :string, required: true
  attr :loading_label, :string, required: true
  attr :on_cancel, :string, default: "cancel-upload"
  slot :intro, required: true
  slot :state
  slot :fields

  def importer(assigns) do
    ~H"""
    <section id={@id} data-importer class="space-y-block mx-auto max-w-2xl">
      <.page_header eyebrow={@eyebrow} eyebrow_path={@eyebrow_path} title={@title}>
        {render_slot(@intro)}
      </.page_header>

      {render_slot(@state)}

      <.card :if={@show_form} id={"#{@form_id}-card"}>
        <.form
          for={@form}
          id={@form_id}
          phx-change="validate"
          phx-submit="submit"
          class="space-y-block"
        >
          {render_slot(@fields)}

          <.file_drop
            id={@upload_id}
            upload={@upload}
            label={@upload_label}
            hint={@upload_hint}
            prompt={@upload_prompt}
            on_cancel={@on_cancel}
          />

          <div :if={@error} id={@error_id}>
            <.callout kind="error" size="compact">{@error}</.callout>
          </div>

          <.button
            type="submit"
            id={@submit_id}
            phx-disable-with={@loading_label}
            full_width
          >
            {@submit_label}
          </.button>
        </.form>
      </.card>
    </section>
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
          "border-rule nila-file-drop",
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
          class="bg-quiet border-rule py-related rounded-box border px-3"
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
