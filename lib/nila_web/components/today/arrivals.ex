defmodule NilaWeb.Components.Today.Arrivals do
  use NilaWeb, :html

  @moduledoc "New-arrival and arrival-sorting presentation for Today."

  attr :groups, :list, required: true
  attr :now, :any, required: true

  def new_arrivals(assigns) do
    ~H"""
    <section :if={@groups != []} id="pending-arrivals" class="space-y-related">
      <h2 class="text-base-content text-ui font-semibold">New arrivals</h2>
      <.card class="divide-base-300 divide-y p-0">
        <button
          :for={group <- @groups}
          type="button"
          id={"arrival-group-#{group.id}"}
          phx-click="open-arrivals"
          phx-value-arrival-id={group.id}
          class="hover:bg-base-200/50 flex w-full items-center gap-3 px-4 py-3 text-left transition"
        >
          <.icon name="hero-inbox-arrow-down" class="text-moon size-5 shrink-0" />
          <span class="text-base-content text-ui flex-1 font-medium">
            {arrival_label(group)}
          </span>
          <.context_text>
            {arrival_age(group.received_at, @now)}
          </.context_text>
          <.icon name="hero-chevron-right" class="text-ink-faint size-4" />
        </button>
      </.card>
    </section>
    """
  end

  attr :group, :any, default: nil
  attr :form, :any, default: nil
  attr :client_options, :list, required: true
  attr :error, :any, default: nil

  def arrival_sort_modal(assigns) do
    ~H"""
    <.modal
      :if={@group}
      id="arrival-sort-modal"
      title={"Sort #{file_phrase(@group.count)}"}
      on_close="close-arrivals"
    >
      <.form
        for={@form}
        id="arrival-sort-form"
        phx-change="validate-arrival"
        phx-submit="route-arrivals"
      >
        <div class="space-y-block">
          <div class="bg-base-200/40 rounded-box px-3 py-2">
            <.context_text tag="p">
              From {display_sender(@group)} over {source_label(@group.source)}
            </.context_text>
            <p :for={arrival <- @group.arrivals} class="text-base-content text-ui mt-1">
              {arrival.filename}
            </p>
          </div>

          <.input
            field={@form[:client_id]}
            type="select"
            label="Client"
            prompt="Select a client"
            options={@client_options}
          />
          <.input
            field={@form[:period]}
            label="Period"
            placeholder="YYYY-MM"
            pattern="[0-9]{4}-[0-9]{2}"
            required
          />
          <.input
            field={@form[:kind]}
            type="select"
            label="Document kind"
            prompt="Select what arrived"
            options={arrival_kind_options()}
          />

          <p :if={@error} id="arrival-sort-error" class="text-error text-ui">
            {@error}
          </p>

          <div class="flex items-center justify-between gap-3">
            <.button
              type="button"
              id="arrival-dismiss"
              variant="ghost"
              size="sm"
              phx-click="dismiss-arrivals"
            >
              Dismiss as junk
            </.button>
            <.button type="submit" id="arrival-route" size="sm">Bring into month</.button>
          </div>
        </div>
      </.form>
    </.modal>
    """
  end

  defp arrival_label(%{client_name: nil} = group) do
    "Unknown number #{display_sender(group)} sent #{file_phrase(group.count)}"
  end

  defp arrival_label(group) do
    "#{group.client_name} sent #{file_phrase(group.count)} over #{source_label(group.source)}"
  end

  defp source_label("whatsapp"), do: "WhatsApp"
  defp source_label("email"), do: "Email"

  defp display_sender(%{source: "whatsapp", sender: sender}), do: "+#{sender}"
  defp display_sender(%{sender: sender}), do: sender

  defp file_phrase(1), do: "a file"
  defp file_phrase(count), do: "#{count} files"

  defp arrival_age(received_at, now) do
    seconds = max(DateTime.diff(now, received_at, :second), 0)

    cond do
      seconds < 3_600 -> "#{max(div(seconds, 60), 1)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  defp arrival_kind_options,
    do: [{"Sales bills", "sales"}, {"Purchase bills", "purchase"}, {"GSTR-2B", "gstr2b"}]
end
