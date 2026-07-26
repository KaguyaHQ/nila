defmodule NilaWeb.Components.Gst.Month.Status do
  use NilaWeb, :html

  @moduledoc "Status, deadline, and progress-spine presentation for a GST month."

  attr :blocking_state, :atom, required: true
  attr :deadline, :any, default: nil
  attr :sales_month, :any, default: nil
  attr :purchase_month, :any, default: nil
  attr :stats, :any, default: nil
  attr :open_issue_count, :integer, required: true
  attr :r1_signoff, :any, default: nil
  attr :gstr3b_signoff, :any, default: nil
  attr :client, :map, required: true
  attr :period, :string, required: true
  attr :dumps, :list, required: true
  attr :can_sign_off, :boolean, required: true

  def status_strip(assigns) do
    ~H"""
    <div
      :if={@blocking_state == :done}
      id="month-strip"
      class="border-success/40 rounded-box sticky -top-6 z-20 flex flex-wrap items-center gap-3 border bg-[color-mix(in_oklab,var(--color-success)_6%,var(--color-base-200))] px-4 py-3"
    >
      <.icon name="hero-check-circle" class="text-success size-5" />
      <p class="text-base-content text-small flex-1 font-semibold">
        Month closed — GSTR-1 and GSTR-3B filed.
      </p>
      <.button navigate={~p"/today"} id="month-back-today" variant="success" size="sm">
        Back to Today
      </.button>
      <.link
        navigate={~p"/register"}
        id="month-view-register"
        class="text-small text-success font-semibold"
      >
        View GST months →
      </.link>
      <.spine steps={spine_steps(assigns)} />
    </div>

    <div
      :if={@blocking_state != :done}
      id="month-strip"
      class="bg-base-200 border-base-300 rounded-box sticky -top-6 z-20 flex flex-wrap items-center gap-3 border px-4 py-3"
    >
      <.badge variant={strip_variant(@blocking_state)}>{strip_label(@blocking_state)}</.badge>
      <span class="flex-1"></span>
      <span :if={@deadline} id="month-deadline">
        <.badge variant={deadline_variant(@deadline.days_left)}>
          {@deadline.return} · {deadline_label(@deadline)}
        </.badge>
      </span>
      <.button
        :if={@blocking_state == :needs_you and @sales_month == nil}
        navigate={~p"/gst/upload?client_id=#{@client.id}&period=#{@period}"}
        id="month-bring-sales"
        variant="outline"
        size="xs"
      >
        Bring in the sales bills →
      </.button>
      <.button
        :if={
          (@blocking_state == :needs_you and @sales_month != nil and @stats) &&
            @stats.need_decision > 0
        }
        navigate={~p"/gst/#{@client.id}/#{@period}/exceptions"}
        id="month-decide-purchases"
        variant="outline"
        size="xs"
      >
        Decide {@stats.need_decision} purchases →
      </.button>
      <.link
        :if={
          (@blocking_state == :needs_you and @sales_month == nil and @stats) &&
            @stats.need_decision > 0
        }
        navigate={~p"/gst/#{@client.id}/#{@period}/exceptions"}
        id="month-decide-purchases"
        class="text-moon text-small font-semibold"
      >
        Decide {@stats.need_decision} purchases →
      </.link>
      <a
        :if={
          @blocking_state == :needs_you and (!@stats || @stats.need_decision == 0) and
            @open_issue_count > 0
        }
        id="month-open-sales-issues"
        href="#month-sales"
        class="text-moon text-small font-semibold"
      >
        {@open_issue_count} sales issues →
      </a>
      <a
        :if={
          @blocking_state == :needs_you and (!@stats || @stats.need_decision == 0) and
            @open_issue_count == 0
        }
        id="month-review-sales"
        href="#month-sales"
        class="text-moon text-small font-semibold"
      >
        Review sales →
      </a>
      <.button
        :if={@blocking_state == :waiting_on_client}
        navigate={~p"/gst/upload?client_id=#{@client.id}&period=#{@period}"}
        id="month-bring-documents"
        variant="outline"
        size="xs"
      >
        Bring in documents
      </.button>
      <a
        :if={@blocking_state == :waiting_on_senior and @can_sign_off}
        id="month-ready-signoff"
        href={signoff_anchor(assigns)}
        class="text-moon text-small font-semibold"
      >
        Ready for your sign-off →
      </a>
      <span
        :if={@blocking_state == :waiting_on_senior and !@can_sign_off}
        class="text-base-content/70 text-small"
      >
        Worked and clean — a senior will see it on their Today.
      </span>
      <a
        :if={(@blocking_state == :to_file and @r1_signoff) && is_nil(@sales_month.filed_at)}
        id="month-file-gstr1"
        href="#gstr1-signoff-banner"
        class="text-moon text-small font-semibold"
      >
        File on the portal →
      </a>
      <a
        :if={(@blocking_state == :to_file and @gstr3b_signoff) && is_nil(@purchase_month.filed_at)}
        id="month-file-gstr3b"
        href="#gst-signoff-banner"
        class="text-moon text-small font-semibold"
      >
        File on the portal →
      </a>
      <.spine steps={spine_steps(assigns)} />
    </div>
    """
  end

  defp strip_label(:to_file), do: "Signed — file on the portal"
  defp strip_label(:needs_you), do: "Blocked — needs you"
  defp strip_label(:waiting_on_client), do: "Waiting on the client"
  defp strip_label(:waiting_on_senior), do: "Waiting on a senior"
  defp strip_label(:done), do: "Done — both returns filed"

  defp strip_variant(:to_file), do: "error"
  defp strip_variant(:needs_you), do: "warning"
  defp strip_variant(_), do: "neutral"

  defp signoff_anchor(%{sales_month: sales, r1_signoff: nil}) when not is_nil(sales),
    do: "#month-sales"

  defp signoff_anchor(_assigns), do: "#month-3b"

  defp spine_steps(assigns) do
    sales = assigns.sales_month
    purchase = assigns.purchase_month
    need_decision = (assigns.stats && assigns.stats.need_decision) || 0

    inputs =
      cond do
        sales && purchase -> {"in", :done}
        sales || purchase -> {"partial", :attention}
        true -> {"missing", :idle}
      end

    gstr1 =
      cond do
        sales == nil -> {"missing", :idle}
        sales.filed_at -> {"filed", :done}
        assigns.r1_signoff -> {"signed", :done}
        sales.state == "reviewed" -> {"ready", :ready}
        assigns.open_issue_count > 0 -> {"#{assigns.open_issue_count} issues", :attention}
        true -> {"needs review", :attention}
      end

    purchases =
      cond do
        purchase == nil -> {"missing", :idle}
        need_decision > 0 -> {"#{need_decision} to decide", :attention}
        true -> {"clear", :done}
      end

    gstr3b =
      cond do
        purchase == nil -> {"missing", :idle}
        purchase.filed_at -> {"filed", :done}
        assigns.gstr3b_signoff -> {"signed", :done}
        need_decision > 0 -> {"waiting", :idle}
        sales == nil -> {"needs the GSTR-1", :idle}
        true -> {"ready", :ready}
      end

    [
      %{id: "inputs", label: "Inputs", state: inputs, href: inputs_anchor(assigns)},
      %{
        id: "gstr1",
        label: "GSTR-1",
        state: gstr1,
        href: if(sales, do: "#month-sales", else: "#month-sales-missing")
      },
      %{
        id: "purchases",
        label: "Purchases · 2B",
        state: purchases,
        href: if(purchase, do: "#month-purchases", else: "#month-purchases-missing")
      },
      %{
        id: "gstr3b",
        label: "GSTR-3B",
        state: gstr3b,
        href: if(purchase, do: "#month-3b", else: "#month-purchases-missing")
      }
    ]
  end

  defp inputs_anchor(%{dumps: dumps}) when dumps != [], do: "#month-arrived"
  defp inputs_anchor(%{sales_month: nil}), do: "#month-sales-missing"
  defp inputs_anchor(%{purchase_month: nil}), do: "#month-purchases-missing"
  defp inputs_anchor(_assigns), do: "#month-page"

  attr :steps, :list, required: true

  defp spine(assigns) do
    ~H"""
    <nav id="month-spine" aria-label="Month progress" class="flex w-full flex-wrap items-center gap-1">
      <%= for {step, index} <- Enum.with_index(@steps) do %>
        <span :if={index > 0} class="text-base-content/25 text-small">→</span>
        <a
          href={step.href}
          id={"spine-#{step.id}"}
          class="hover:bg-base-100/60 rounded-field flex items-center gap-1.5 px-1.5 py-0.5"
        >
          <span class={["size-1.5 rounded-full", spine_dot(elem(step.state, 1))]}></span>
          <span class="text-base-content/80 text-small font-medium">{step.label}</span>
          <span class="text-base-content/50 text-fine">{elem(step.state, 0)}</span>
        </a>
      <% end %>
    </nav>
    """
  end

  defp spine_dot(:done), do: "bg-success"
  defp spine_dot(:attention), do: "bg-warning"
  defp spine_dot(:ready), do: "bg-moon"
  defp spine_dot(:idle), do: "bg-base-content/25"

  defp deadline_label(%{days_left: days, due: due}) when days < -30,
    do: "overdue since #{format_display_date(due)}"

  defp deadline_label(%{days_left: days}) when days < 0, do: "#{-days}d overdue"
  defp deadline_label(%{days_left: 0}), do: "due today"
  defp deadline_label(%{days_left: days}), do: "#{days}d left"
  defp deadline_variant(days) when days < 0, do: "error"
  defp deadline_variant(days) when days <= 5, do: "warning"
  defp deadline_variant(_), do: "neutral"
end
