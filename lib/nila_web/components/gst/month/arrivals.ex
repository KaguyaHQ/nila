defmodule NilaWeb.Components.Gst.Month.Arrivals do
  use NilaWeb, :html

  @moduledoc "Arrival and intake presentation for the GST month workbench."

  attr :attention_dumps, :list, required: true
  attr :dumps, :list, required: true
  attr :asks, :list, required: true
  attr :superseded_2b_ids, :any, required: true
  attr :client, :map, required: true
  attr :period, :string, required: true
  attr :open_period, :string, required: true
  attr :r1_signoff, :any, default: nil
  attr :gstr3b_signoff, :any, default: nil

  def arrivals(assigns) do
    ~H"""
    <div :if={@attention_dumps != []} id="month-dumps" class="space-y-2">
      <div
        :for={dump <- @attention_dumps}
        id={"month-dump-#{dump.id}"}
        class="border-base-300 rounded-box flex flex-wrap items-center gap-3 border px-4 py-3"
      >
        <span
          :if={dump.status in ~w(received extracting)}
          class="loading loading-sm loading-spinner text-moon"
        ></span>
        <.badge variant={dump_variant(dump.status)}>{dump_kind_title(dump.kind)}</.badge>
        <span class="text-base-content/80 text-small min-w-0 flex-1">
          <%= cond do %>
            <% dump.status in ~w(received extracting) -> %>
              Extracting — the month reworks itself when it lands.
            <% dump.status == "failed" -> %>
              Extraction failed — check the file and bring it in again.
            <% dump.status == "held" -> %>
              Arrived after the return was signed — reopen the signature to include it.
            <% dump.status == "after_filing" -> %>
              Arrived after this month was filed — a filed return can't change. This belongs in a later month's return.
          <% end %>
        </span>
        <.button
          :if={dump.status == "after_filing"}
          navigate={~p"/gst/upload?client_id=#{@client.id}&period=#{@open_period}"}
          id={"month-dump-open-period-#{dump.id}"}
          variant="outline"
          size="xs"
        >
          Bring it into the open month →
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

    <section :if={@dumps != []} id="month-arrived" class="scroll-mt-28 space-y-1.5">
      <div class="flex flex-wrap items-center gap-3">
        <h2 class="text-base-content/60 text-small font-semibold">Arrived</h2>
        <button
          :if={@asks != []}
          type="button"
          id="month-chase-history-link"
          phx-click="open-chase-history"
          class="text-fine text-moon font-semibold"
        >
          Asked {length(@asks)}× — see what we sent
        </button>
      </div>
      <div
        :for={dump <- @dumps}
        id={"month-arrived-#{dump.id}"}
        class="text-base-content/60 text-small flex flex-wrap items-center gap-x-2 gap-y-1"
      >
        <span class={MapSet.member?(@superseded_2b_ids, dump.id) && "line-through opacity-70"}>
          {arrived_line(dump)}
        </span>
        <span :if={MapSet.member?(@superseded_2b_ids, dump.id)} class="text-fine">(replaced)</span>
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
    </section>
    """
  end

  defp dump_kind_title("sales"), do: "Sales bills"
  defp dump_kind_title("purchase"), do: "Purchase bills"
  defp dump_kind_title("gstr2b"), do: "GSTR-2B"

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

  defp file_count_label(1), do: "1 file"
  defp file_count_label(n), do: "#{n} files"
  defp source_label("whatsapp"), do: "WhatsApp"
  defp source_label("email"), do: "email"
  defp dump_variant("failed"), do: "error"
  defp dump_variant("held"), do: "warning"
  defp dump_variant("after_filing"), do: "info"
  defp dump_variant(_), do: "neutral"
  defp dump_releasable?(assigns, %{kind: "sales"}), do: is_nil(assigns.r1_signoff)
  defp dump_releasable?(assigns, _dump), do: is_nil(assigns.gstr3b_signoff)
end
