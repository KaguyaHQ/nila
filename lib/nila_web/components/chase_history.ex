defmodule NilaWeb.Components.ChaseHistory do
  @moduledoc """
  The chase log for a client-month, rendered inside a modal: every ask ever
  sent, newest first, verbatim. A log, not a workspace — no actions, no edit.
  Shared by the month workbench and Today so both doors open the same record.
  """
  use Phoenix.Component

  import NilaWeb.Components.Badge
  import Nila.Formatters, only: [format_display_datetime_with_time: 1]

  attr :asks, :list,
    required: true,
    doc: "Chase.Delivery structs, newest first, sent_by preloaded"

  def chase_history(assigns) do
    ~H"""
    <div id="chase-history" class="space-y-4">
      <div
        :for={ask <- @asks}
        id={"chase-ask-#{ask.id}"}
        class="border-base-300 rounded-box border px-4 py-3"
      >
        <div class="flex flex-wrap items-center gap-2">
          <.badge variant={channel_variant(ask.channel)}>{channel_label(ask.channel)}</.badge>
          <span class="text-base-content text-small font-medium">{kind_label(ask.kind)}</span>
          <span class="text-base-content/50 text-fine">
            {format_display_datetime_with_time(ask.inserted_at)} · sent by {sender_name(ask)}
          </span>
        </div>
        <pre class="bg-base-200/40 border-base-300 rounded-box text-base-content text-small mt-3 overflow-x-auto border p-4 font-sans whitespace-pre-wrap">{ask.body}</pre>
      </div>
    </div>
    """
  end

  defp channel_label("manual"), do: "Manual"
  defp channel_label("whatsapp"), do: "WhatsApp"
  defp channel_label("email"), do: "Email"

  defp channel_variant("manual"), do: "neutral"
  defp channel_variant(_automated), do: "info"

  defp kind_label("month_open"), do: "Month open"
  defp kind_label("missing_bills"), do: "Missing bills"

  defp sender_name(%{channel: "manual", sent_by: %{name: name}}) when is_binary(name), do: name
  defp sender_name(_ask), do: "Nila"
end
