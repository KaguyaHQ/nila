defmodule NilaWeb.Components.Gst.Month.Arrivals do
  use NilaWeb, :html

  @moduledoc """
  The paper trail: what arrived, when, from whom, and anything a pile is stuck
  on.

  Folded and grey. It is the audit answer to "where did this come from",
  which nobody asks until they ask, and it used to sit in prime real estate
  with a struck-through line as the third thing on the page. When a pile is
  genuinely stuck the verdict says so and its door points here, so the
  interruption is announced once, at the top, in words.
  """

  attr :attention_dumps, :list, required: true
  attr :dumps, :list, required: true
  attr :asks, :list, required: true
  attr :superseded_2b_ids, :any, required: true
  attr :client, :map, required: true
  attr :period, :string, required: true
  attr :open_period, :string, required: true
  attr :r1_signoff, :any, default: nil
  attr :gstr3b_signoff, :any, default: nil

  def paper_trail(assigns) do
    ~H"""
    <details :if={@dumps != []} id="month-paper-trail" class="group scroll-mt-28">
      <summary class="hover:text-base-content text-base-content/55 text-small flex cursor-pointer list-none items-center gap-2">
        <.icon name="hero-inbox-arrow-down" class="text-base-content/40 size-4 shrink-0" />
        <span class="flex-1">{trail_line(assigns)}</span>
        <.icon
          name="hero-chevron-down-mini"
          class="text-base-content/40 size-4 shrink-0 transition-transform group-open:rotate-180"
        />
      </summary>

      <div class="mt-3 space-y-3">
        <div :if={@attention_dumps != []} id="month-dumps" class="space-y-2">
          <div
            :for={dump <- @attention_dumps}
            id={"month-dump-#{dump.id}"}
            class="border-base-300 rounded-box flex flex-wrap items-center gap-3 border px-4 py-2.5"
          >
            <span
              :if={dump.status in ~w(received extracting)}
              class="loading loading-spinner loading-xs text-moon"
            ></span>
            <span class="text-base-content/60 text-fine font-medium">{dump_kind_title(dump.kind)}</span>
            <span class="text-base-content/70 text-small min-w-0 flex-1">
              <%= cond do %>
                <% dump.status in ~w(received extracting) -> %>
                  Extracting. The month reworks itself when it lands.
                <% dump.status == "failed" -> %>
                  Extraction failed. Check the file and bring it in again.
                <% dump.status == "held" -> %>
                  Arrived after the return was signed. Reopen the signature to include it.
                <% dump.status == "after_filing" -> %>
                  Arrived after this month was filed. A filed return cannot change, so this belongs in a later month's return.
                <% dump.status == "needs_confirmation" -> %>
                  Read, but what it holds does not answer to this month. Nothing is built from it until the question above is answered.
                <% true -> %>
                  {dump.status}
              <% end %>
            </span>
            <.button
              :if={dump.status == "after_filing"}
              navigate={~p"/gst/upload?client_id=#{@client.id}&period=#{@open_period}"}
              id={"month-dump-open-period-#{dump.id}"}
              variant="outline"
              size="xs"
            >
              Bring it into the open month
            </.button>
            <.button
              :if={dump.status == "held" and dump_releasable?(assigns, dump)}
              id={"month-dump-release-#{dump.id}"}
              variant="outline"
              size="xs"
              phx-click="release-dump"
              phx-value-dump-id={dump.id}
            >
              Rework the month with it
            </.button>
          </div>
        </div>

        <div id="month-arrived" class="space-y-1.5">
          <button
            :if={@asks != []}
            type="button"
            id="month-chase-history-link"
            phx-click="open-chase-history"
            class="text-fine text-moon font-semibold"
          >
            Asked {length(@asks)}×, see what we sent
          </button>
          <div
            :for={dump <- @dumps}
            id={"month-arrived-#{dump.id}"}
            class="text-base-content/55 text-small flex flex-wrap items-center gap-x-2 gap-y-1"
          >
            <span class={
              (MapSet.member?(@superseded_2b_ids, dump.id) or dump.status == "discarded") &&
                "line-through opacity-70"
            }>
              {arrived_line(dump)}
            </span>
            <span :if={MapSet.member?(@superseded_2b_ids, dump.id)} class="text-fine">(replaced)</span>
            <%!-- The answer to a precondition question outlives the question. "We
                  knew, and here is why we booked it anyway" is the sentence a
                  signature stands on, so it lives in the paper trail rather than
                  disappearing with the flag it cleared. --%>
            <span
              :if={answer_line(dump)}
              id={"month-arrived-answer-#{dump.id}"}
              class="text-base-content/70 text-fine"
            >
              {answer_line(dump)}
            </span>
            <.link
              :for={{_key, index} <- Enum.with_index(dump.file_keys)}
              href={~p"/gst/#{@client.id}/#{@period}/original/#{dump.id}/#{index}"}
              id={"month-arrived-file-#{dump.id}-#{index}"}
              class="text-fine text-moon inline-flex items-center gap-1 font-semibold"
            >
              <.icon name="hero-arrow-down-tray" class="size-3.5" />
              {if length(dump.file_keys) > 1, do: "file #{index + 1}", else: "file"}
            </.link>
          </div>
        </div>
      </div>
    </details>
    """
  end

  defp trail_line(assigns) do
    count = length(assigns.dumps)
    arrivals = "#{count} #{if count == 1, do: "arrival", else: "arrivals"}"

    case length(assigns.attention_dumps) do
      0 -> "Paper trail: #{arrivals}."
      n -> "Paper trail: #{arrivals}, #{n} needing attention."
    end
  end

  defp dump_kind_title("sales"), do: "Sales bills"
  defp dump_kind_title("purchase"), do: "Purchase bills"
  defp dump_kind_title("gstr2b"), do: "GSTR-2B"
  defp dump_kind_title("filed_gstr1"), do: "Filed GSTR-1"

  defp arrived_line(dump) do
    [
      dump_kind_title(dump.kind),
      file_count_label(length(dump.file_keys)),
      format_display_datetime(dump.inserted_at),
      dump.brought_in_by && "brought in by #{dump.brought_in_by.name}",
      dump.source && "over #{source_label(dump.source)}"
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

  defp file_count_label(1), do: "1 file"
  defp file_count_label(n), do: "#{n} files"
  defp source_label("whatsapp"), do: "WhatsApp"
  defp source_label("email"), do: "email"
  defp dump_releasable?(assigns, %{kind: "sales"}), do: is_nil(assigns.r1_signoff)
  defp dump_releasable?(assigns, _dump), do: is_nil(assigns.gstr3b_signoff)
end
