defmodule NilaWeb.Components.Feedback do
  @moduledoc """
  Progress/stage step strips and the muted empty-cell placeholder.
  """
  use Phoenix.Component

  import NilaWeb.Components.Icon

  @doc """
  Renders ordered progress steps.
  """
  attr :steps, :list, required: true, doc: "list of {label, :done | :active | :pending}"

  def progress_steps(assigns) do
    ~H"""
    <ol class="space-y-3">
      <li :for={{label, state} <- @steps} class="text-small flex items-center gap-3">
        <span class={[
          "grid size-6 shrink-0 place-items-center rounded-full border",
          state == :done && "bg-success border-success text-success-content",
          state == :active && "border-base-300 text-base-content",
          state == :pending && "border-base-300 text-ink-faint"
        ]}>
          <.icon :if={state == :done} name="hero-check" class="size-4" />
          <.icon :if={state == :active} name="hero-arrow-path" class="size-4 animate-spin" />
          <span :if={state == :pending} class="size-2 rounded-full bg-current/40" />
        </span>
        <span class={[
          "font-medium",
          state == :pending && "text-ink-subtle",
          state != :pending && "text-base-content"
        ]}>
          {label}
        </span>
      </li>
    </ol>
    """
  end

  @doc """
  Renders a horizontal progress strip for a short, linear lifecycle.

  Each step is a map with `:label` and `:state` where state is one of `:done`,
  `:current`, or `:upcoming`. Connectors fill the space between markers; the line
  leaving a completed step is tinted to show how far along the flow is.

  ## Examples

      <.stage_steps steps={[
        %{label: "Ready to send", state: :done},
        %{label: "Sent", state: :current},
        %{label: "Paid", state: :upcoming}
      ]} />
  """
  attr :steps, :list, required: true
  attr :id, :string, default: nil
  attr :class, :any, default: nil

  def stage_steps(assigns) do
    ~H"""
    <ol id={@id} class={["flex items-center", @class]} aria-label="Progress">
      <li
        :for={{step, index} <- Enum.with_index(@steps)}
        class="flex flex-1 items-center gap-3 last:flex-none"
      >
        <div class="flex items-center gap-2 whitespace-nowrap">
          <span class={[
            "text-fine flex size-7 items-center justify-center rounded-full border font-semibold",
            stage_marker_class(step.state)
          ]}>
            <.icon :if={step.state == :done} name="hero-check" class="size-4" />
            <span :if={step.state != :done}>{index + 1}</span>
          </span>
          <span class={["text-small", stage_label_class(step.state)]}>{step.label}</span>
        </div>
        <span
          :if={index < length(@steps) - 1}
          class={["h-px flex-1", if(step.state == :done, do: "bg-primary/40", else: "bg-base-300")]}
        />
      </li>
    </ol>
    """
  end

  defp stage_marker_class(:done), do: "border-primary bg-primary text-primary-content"

  defp stage_marker_class(:current),
    do: "border-primary bg-primary/10 text-primary ring-2 ring-primary/20"

  defp stage_marker_class(_upcoming), do: "border-base-300 bg-base-100 text-ink-subtle"

  defp stage_label_class(:done), do: "text-ink-muted"
  defp stage_label_class(:current), do: "font-semibold text-base-content"
  defp stage_label_class(_upcoming), do: "text-ink-subtle"

  @doc """
  Renders a muted placeholder for a value that is genuinely absent (a quiet
  hyphen, not an alarm). Use in table cells where a field can legitimately be
  blank, instead of leaving an empty cell.

  ## Examples

      <:col :let={row} label="PO number">{row.po_number || empty_cell()}</:col>
  """
  def empty_cell(assigns \\ %{}) do
    ~H"""
    <span class="text-ink-faint opacity-75">-</span>
    """
  end
end
