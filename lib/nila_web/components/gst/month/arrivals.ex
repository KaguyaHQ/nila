defmodule NilaWeb.Components.Gst.Month.Arrivals do
  use NilaWeb, :html

  @moduledoc "Source arrivals, processing state, originals, and chase provenance."

  attr :id, :string, required: true
  attr :dumps, :list, required: true
  attr :superseded_2b_ids, :any, required: true
  attr :client, :map, required: true
  attr :period, :string, required: true
  attr :open_period, :string, required: true
  attr :r1_signoff, :any, default: nil
  attr :gstr3b_signoff, :any, default: nil

  def source_record(assigns) do
    ~H"""
    <div :if={@dumps != []} id={@id} class="border-base-300 divide-base-300 divide-y border-y">
      <article
        :for={dump <- @dumps}
        id={"month-arrived-#{dump.id}"}
        class="gap-block grid items-center py-3 sm:grid-cols-[minmax(0,1fr)_auto]"
      >
        <div class={[
          "min-w-0 space-y-1",
          (MapSet.member?(@superseded_2b_ids, dump.id) or dump.status == "discarded") &&
            "line-through opacity-70"
        ]}>
          <div class="flex flex-wrap items-center gap-2">
            <span class="text-base-content text-ui font-semibold">{dump_kind_title(dump.kind)}</span>
            <span
              :if={dump.status in ~w(received extracting)}
              class="loading loading-spinner loading-xs text-moon"
            ></span>
            <.badge :if={MapSet.member?(@superseded_2b_ids, dump.id)} variant="neutral">
              Replaced
            </.badge>
            <.badge :if={dump.status == "discarded"} variant="neutral">Discarded</.badge>
          </div>
          <p class="text-ink-subtle text-meta">{arrived_line(dump)}</p>
          <p
            :if={answer_line(dump)}
            id={"month-arrived-answer-#{dump.id}"}
            class="text-ink-muted text-meta"
          >
            {answer_line(dump)}
          </p>
          <p :if={attention_line(dump)} id={"month-dump-#{dump.id}"} class="text-ink-muted text-ui">
            {attention_line(dump)}
          </p>
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <.button
            :for={{_key, index} <- Enum.with_index(dump.file_keys)}
            href={~p"/gst/#{@client.id}/#{@period}/original/#{dump.id}/#{index}"}
            id={"month-arrived-file-#{dump.id}-#{index}"}
            variant="outline"
            size="xs"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" />
            {original_label(length(dump.file_keys), index)}
          </.button>
          <.button
            :if={dump.status == "after_filing"}
            navigate={~p"/gst/upload?client_id=#{@client.id}&period=#{@open_period}"}
            id={"month-dump-open-period-#{dump.id}"}
            variant="outline"
            size="xs"
          >
            Bring into open month
          </.button>
          <.button
            :if={dump.status == "held" and dump_releasable?(assigns, dump)}
            id={"month-dump-release-#{dump.id}"}
            variant="outline"
            size="xs"
            phx-click="release-dump"
            phx-value-dump-id={dump.id}
          >
            Rework month with it
          </.button>
          <%!-- The only way out. A failed sales packet holds the intake
                incomplete, and both sign-offs gate on that, so without this the
                month could never be filed through the product at all. --%>
          <.button
            :if={dump.status == "failed"}
            id={"month-dump-abandon-#{dump.id}"}
            variant="outline"
            size="xs"
            phx-click="abandon-dump"
            phx-value-dump-id={dump.id}
            data-confirm="Stop waiting for this packet? The month can then be worked and filed without it."
          >
            Stop waiting for it
          </.button>
        </div>
      </article>
    </div>
    """
  end

  attr :asks, :list, required: true

  def chase_history_link(assigns) do
    ~H"""
    <button
      :if={@asks != []}
      type="button"
      id="month-chase-history-link"
      phx-click="open-chase-history"
      class="text-meta text-moon font-semibold"
    >
      Requests sent: {length(@asks)} · view history
    </button>
    """
  end

  defp dump_kind_title("sales"), do: "Sales bills"
  defp dump_kind_title("purchase"), do: "Purchase bills"
  defp dump_kind_title("gstr2b"), do: "GSTR-2B"
  defp dump_kind_title("filed_gstr1"), do: "Filed GSTR-1"

  defp arrived_line(dump) do
    [
      file_count_label(length(dump.file_keys)),
      format_display_datetime(dump.inserted_at),
      dump.brought_in_by && "brought in by #{dump.brought_in_by.name}",
      dump.source && "via #{source_label(dump.source)}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp answer_line(dump) do
    case Nila.Gst.Intake.Dumps.precondition_answer(dump) do
      %{"answer" => "keep", "reason" => reason} -> "Confirmed as this month's: #{reason}"
      %{"answer" => "move", "moved_from" => from} -> "Moved here from #{period_label(from)}"
      %{"answer" => "discard"} -> "Discarded as a double upload"
      _none -> nil
    end
  end

  defp attention_line(%{status: status}) when status in ~w(received extracting),
    do: "Extracting. The month updates when it lands."

  defp attention_line(%{status: "failed"}),
    do:
      "Extraction failed. Bring the original in again, or stop waiting for it — " <>
        "until one or the other, this month cannot be filed."

  defp attention_line(%{status: "held"}),
    do: "Added after signature. Reopen the signature to include it."

  defp attention_line(%{status: "after_filing"}),
    do: "Added after filing. Move it to an open month."

  defp attention_line(%{status: "needs_confirmation"}),
    do: "Waiting for the month question above to be answered."

  defp attention_line(_dump), do: nil

  defp original_label(1, _index), do: "Download original"
  defp original_label(_count, index), do: "Download #{index + 1}"
  defp file_count_label(1), do: "1 file"
  defp file_count_label(n), do: "#{n} files"
  defp source_label("whatsapp"), do: "WhatsApp"
  defp source_label("email"), do: "email"
  defp dump_releasable?(assigns, %{kind: "sales"}), do: is_nil(assigns.r1_signoff)
  defp dump_releasable?(assigns, _dump), do: is_nil(assigns.gstr3b_signoff)
end
