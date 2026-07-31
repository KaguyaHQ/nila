defmodule NilaWeb.Components.Gst.Month.Precondition do
  use NilaWeb, :html

  @moduledoc """
  The one question a month in doubt asks, and its three answers.

  It sits where the door sits, at the verdict's weight, because a month cannot
  be worked while its inputs are in question — and because the alternative
  (another CTA in a strip) is a documented disease on this page. There is no
  table of the fourteen bills and no per-invoice anything: the whole point is
  that this is *one* decision, taken once, before any exception exists.

  The three answers carry the same weight and none is pre-selected. Keeping the
  packet where it is must not be the visually cheap option — availing an April
  credit in June is legal and the reviewer may know exactly why — and a default
  answer to a question the product is asking *because it does not know* would be
  dishonest. Choosing one reveals the single thing that answer needs: a
  destination, a reason, or a confirmation.
  """

  alias Nila.Formatters

  attr :dump, :map, required: true
  attr :finding, :map, required: true
  attr :period, :string, required: true
  attr :choice, :any, default: nil
  attr :period_options, :list, required: true

  def question(assigns) do
    ~H"""
    <section
      id="month-precondition"
      class="bg-warning/[0.04] border-warning/40 rounded-box space-y-4 border p-5"
    >
      <p class="text-ink-muted text-small">
        {arrival_line(@dump)} Nothing is built from it until you say what it is.
      </p>

      <div :if={is_nil(@choice)} id="month-precondition-answers" class="flex flex-wrap gap-3">
        <.button
          :for={{answer, label} <- answers(assigns)}
          id={"month-precondition-choose-#{answer}"}
          variant="outline"
          size="md"
          phx-click="precondition-choose"
          phx-value-answer={answer}
        >
          {label}
        </.button>
      </div>

      <.form
        :if={@choice}
        for={to_form(%{}, as: :precondition)}
        id="month-precondition-form"
        phx-submit="precondition-answer"
        class="space-y-3"
      >
        <.input type="hidden" name="answer" id="month-precondition-answer" value={@choice} />

        <div :if={@choice == "move"} class="space-y-2">
          <.input
            type="select"
            name="period"
            id="month-precondition-period"
            label="Which month does this packet belong to?"
            value={@finding["modal_period"]}
            prompt="Pick the month"
            options={@period_options}
          />
          <p class="text-ink-muted text-small">
            The packet is not read again. If that month is already signed, it waits there
            for a senior — the same as any late arrival.
          </p>
        </div>

        <div :if={@choice == "keep"} class="space-y-2">
          <.input
            type="text"
            name="reason"
            id="month-precondition-reason"
            label={"Why does this packet belong in #{Formatters.period_label(@period)}?"}
            value=""
            placeholder={reason_placeholder(@dump.kind)}
          />
          <p class="text-ink-muted text-small">
            Recorded on the arrival. It is what the signature stands on if anyone asks later.
          </p>
        </div>

        <p :if={@choice == "discard"} id="month-precondition-discard-note" class="text-small">
          The packet is kept on the paper trail and never booked into any month. Bring it in
          again if that turns out to be wrong.
        </p>

        <div class="flex flex-wrap items-center gap-3">
          <.button id="month-precondition-confirm" type="submit" variant="primary" size="lg">
            {confirm_label(assigns)}
          </.button>
          <.button
            id="month-precondition-back"
            type="button"
            variant="ghost"
            size="sm"
            phx-click="precondition-cancel"
          >
            Something else
          </.button>
        </div>
      </.form>
    </section>
    """
  end

  defp answers(assigns) do
    [
      {"move", move_label(assigns.finding)},
      {"keep", "Keep it in #{Formatters.period_label(assigns.period)}"},
      {"discard", "Discard it — uploaded twice"}
    ]
  end

  defp move_label(%{"modal_period" => period}) when is_binary(period),
    do: "Move it to #{Formatters.period_label(period)}"

  defp move_label(_finding), do: "Move it to another month"

  defp confirm_label(%{choice: "move"}), do: "Move the packet"

  defp confirm_label(%{choice: "keep", period: period}),
    do: "Keep it in #{Formatters.period_label(period)}"

  defp confirm_label(%{choice: "discard"}), do: "Discard the packet"
  defp confirm_label(_assigns), do: "Confirm"

  defp arrival_line(dump) do
    "The #{kind_label(dump.kind)} that arrived #{format_display_datetime(dump.inserted_at)}."
  end

  defp kind_label("gstr2b"), do: "GSTR-2B"
  defp kind_label("purchase"), do: "purchase packet"
  defp kind_label("sales"), do: "sales packet"

  # A sales packet has no credits to avail, and an example that describes the
  # wrong side of the ledger teaches the reviewer to write the wrong reason.
  defp reason_placeholder("sales"),
    do: "Raised late — these went out this month even though they're dated earlier"

  defp reason_placeholder(_kind),
    do: "Availing these credits this month — the bills came in late"
end
