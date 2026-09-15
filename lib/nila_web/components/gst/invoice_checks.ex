defmodule NilaWeb.Components.Gst.InvoiceChecks do
  use NilaWeb, :html

  alias Nila.Gst.Sales.Invoice.Validation

  attr :invoice, :map, required: true
  attr :open, :boolean, default: false
  attr :passed_open, :boolean, default: false
  attr :batch, :list, default: nil
  attr :issues, :list, default: nil
  slot :issue_actions

  def summary(assigns) do
    outcomes = Nila.Gst.Sales.Invoice.Readiness.outcomes(assigns.invoice, assigns.batch)
    arithmetic = results(assigns.invoice)

    passed =
      Enum.filter(arithmetic, &(&1.status == :passed)) ++
        (outcomes |> Enum.filter(&(&1.status == :passed)) |> Enum.map(&display_outcome/1))

    unavailable =
      Enum.filter(arithmetic, &(&1.status == :unavailable)) ++
        (outcomes |> Enum.filter(&(&1.status == :not_checked)) |> Enum.map(&display_outcome/1))

    issues = assigns.issues || Nila.Gst.Sales.Invoice.Readiness.issues([assigns.invoice])

    assigns =
      assigns
      |> assign(:passed_rows, passed)
      |> assign(:unavailable_rows, unavailable)
      |> assign(:failed_comparisons, Enum.filter(arithmetic, &(&1.status == :failed)))
      |> assign(:issues, issues)
      |> assign(:issue_count, length(issues))
      |> assign(:passed, length(passed))

    ~H"""
    <.fold id="invoice-checks" open={@open} on_toggle="toggle-invoice-checks" class="min-w-0 flex-1">
      <:summary>
        <div
          id="invoice-workbench-gst-status"
          data-open-issues={@issue_count}
          class="flex items-start gap-3"
        >
          <.icon
            name={
              if @issue_count > 0,
                do: "hero-exclamation-circle-solid",
                else:
                  if(@passed > 0,
                    do: "hero-check-circle-solid",
                    else: "hero-information-circle-solid"
                  )
            }
            class={[
              "mt-0.5 size-5 shrink-0",
              cond do
                @issue_count > 0 -> "text-warning"
                @passed > 0 -> "text-success"
                true -> "text-ink-muted"
              end
            ]}
          />
          <span class="text-ink text-ui font-semibold">
            Invoice checks ·
            <span :if={@issue_count > 0} class="text-warning">{@issue_count} {if @issue_count == 1,
              do: "issue",
              else: "issues"} ·</span>
            {@passed} passed
          </span>
        </div>
      </:summary>
      <div class="mt-3 max-h-64 space-y-3 overflow-y-auto pr-3">
        <div :if={@issues != []} id="invoice-check-issues">
          <%= if @issue_actions != [] do %>
            {render_slot(@issue_actions)}
          <% else %>
            <p :for={issue <- @issues} class="text-ui text-warning">{issue["message"]}</p>
          <% end %>
        </div>
        <.check_rows
          :if={@failed_comparisons != []}
          rows={@failed_comparisons}
          prefix="invoice-check-failed"
        />
        <.fold
          :if={@issue_count > 0}
          id="invoice-passed-checks"
          open={@passed_open}
          on_toggle="toggle-passed-checks"
        >
          <:summary>
            <span class="text-ink text-ui font-semibold">{@passed} checks passed</span>
          </:summary>
          <.check_rows rows={@passed_rows} prefix="invoice-check" />
        </.fold>
        <.check_rows :if={@issue_count == 0} rows={@passed_rows} prefix="invoice-check" />
        <div :if={@unavailable_rows != []} id="invoice-checks-unavailable" class="space-y-1">
          <p class="text-ink-muted text-ui">
            {length(@unavailable_rows)} not checked — missing inputs or verification evidence
          </p>
          <p :for={row <- @unavailable_rows} class="text-ink-muted text-ui">{row.label}</p>
        </div>
        <p class="text-ink-muted text-ui">
          Checks use captured values. They do not replace verification against the original bill.
        </p>
        <p class="text-ink-muted text-label">
          Amount comparisons allow ₹0.50. A passed GSTIN checksum does not verify live registration.
        </p>
      </div>
    </.fold>
    """
  end

  attr :rows, :list, required: true
  attr :prefix, :string, required: true

  defp check_rows(assigns) do
    ~H"""
    <ul class="divide-rule divide-y">
      <li
        :for={{row, index} <- Enum.with_index(@rows)}
        id={"#{@prefix}-#{index}"}
        data-result={row.status}
        class="flex items-start gap-3 py-2"
      >
        <.icon
          name={result_icon(row.status)}
          class={["mt-0.5 size-5 shrink-0", result_tone(row.status)]}
        />
        <div class="min-w-0 space-y-1">
          <p class="text-ink text-ui font-semibold">{row.title}</p>
          <p class="text-ink-muted text-ui tabular-nums">{row.detail}</p>
          <p :if={row.secondary} class="text-ink-muted text-ui tabular-nums">{row.secondary}</p>
          <p :if={row.difference} class="text-ink-muted text-ui tabular-nums">{row.difference}</p>
        </div>
      </li>
    </ul>
    """
  end

  defp display_outcome(outcome) do
    %{
      label:
        if(outcome.status == :not_checked, do: unchecked_label(outcome.id), else: outcome.label),
      title: outcome.label,
      detail: outcome.detail,
      status: if(outcome.status == :not_checked, do: :unavailable, else: outcome.status),
      secondary: nil,
      difference: nil
    }
  end

  defp unchecked_label("seller_identity"), do: "Seller identity — matching evidence unavailable"

  defp unchecked_label("source_evidence"),
    do: "Source verification — explicit successful result unavailable"

  defp unchecked_label("hsn_directory"), do: "HSN/SAC directory — validation result unavailable"
  defp unchecked_label("duplicate_number"), do: "Duplicate number — invoice batch unavailable"

  defp unchecked_label("tax_place"),
    do: "Tax heads and place of supply — comparison inputs incomplete or conflicting"

  defp unchecked_label("buyer_gstin"), do: "Buyer GSTIN — not captured"
  defp unchecked_label("tax_amounts"), do: "Line tax amounts — comparison inputs incomplete"
  defp unchecked_label("taxable_values"), do: "Line taxable values — no lines available"

  defp unchecked_label("line_structure"),
    do: "Heading and subtotal detection — no line descriptions available"

  defp result_icon(:passed), do: "hero-check-circle-solid"
  defp result_icon(:failed), do: "hero-exclamation-circle-solid"
  defp result_icon(:unavailable), do: "hero-minus-circle"
  defp result_tone(:passed), do: "text-success"
  defp result_tone(:failed), do: "text-warning"
  defp result_tone(:unavailable), do: "text-ink-muted"

  @totals [
    {"printed_taxable_mismatch", "Taxable total"},
    {"printed_tax_mismatch", "GST total"},
    {"grand_total_mismatch", "Invoice total"}
  ]

  def results(invoice) do
    checks =
      Validation.checks(invoice)
      |> Enum.reject(fn check ->
        check["code"] == "cgst_sgst_unequal" &&
          check["operands"]["cgst"] == 0 && check["operands"]["sgst"] == 0
      end)

    totals =
      Enum.map(@totals, fn {code, label} ->
        case Enum.find(checks, &(&1["code"] == code)) do
          nil ->
            %{
              label: label,
              title: "#{label} — not compared",
              secondary: nil,
              difference: nil,
              detail: "Printed or calculated amount is missing.",
              status: :unavailable
            }

          check ->
            row(
              check,
              label,
              "#{calculated_label(code)} #{money(check["operands"]["derived"])} · #{printed_label(code)} #{money(check["operands"]["printed"])}",
              check["operands"]["derived"],
              check["operands"]["printed"]
            )
        end
      end)

    lines =
      Enum.flat_map(checks, fn check ->
        ops = check["operands"]

        case check["code"] do
          "line_arithmetic" ->
            [
              row(
                check,
                "Line #{check["line"]} tax",
                "#{money(ops["taxable"])} × #{ops["rate"]}% = #{money(ops["expected"])}",
                ops["expected"],
                ops["actual"],
                "Captured tax #{money(ops["actual"])}"
              )
            ]

          "cgst_sgst_unequal" ->
            [
              row(
                check,
                "Line #{check["line"]}: CGST and SGST",
                "CGST #{money(ops["cgst"])} · SGST #{money(ops["sgst"])}",
                ops["cgst"],
                ops["sgst"]
              )
            ]

          _ ->
            []
        end
      end)

    totals ++ lines
  end

  defp calculated_label("printed_taxable_mismatch"), do: "Sum of lines"
  defp calculated_label("printed_tax_mismatch"), do: "Sum of line taxes"
  defp calculated_label("grand_total_mismatch"), do: "Calculated payable"
  defp printed_label("printed_tax_mismatch"), do: "Printed GST"
  defp printed_label(_), do: "Printed total"

  defp row(check, label, detail, left, right, secondary \\ nil) do
    delta =
      Decimal.sub(Decimal.new(to_string(left)), Decimal.new(to_string(right))) |> Decimal.abs()

    equal? = Decimal.equal?(delta, 0)
    plural? = check["code"] == "cgst_sgst_unequal"

    outcome =
      cond do
        not check["passed"] -> if plural?, do: "do not match", else: "does not match"
        not equal? -> "within tolerance"
        plural? -> "match"
        true -> "matches"
      end

    difference =
      if not equal? do
        amount =
          if Decimal.compare(delta, Decimal.new("0.01")) == :lt,
            do: "Less than ₹0.01",
            else: money(Decimal.to_float(delta))

        "#{amount} difference · Allowed ₹0.50"
      end

    %{
      label: label,
      title: "#{label} #{outcome}",
      detail: detail,
      secondary: secondary,
      difference: difference,
      status: if(check["passed"], do: :passed, else: :failed)
    }
  end

  defp money(value), do: Nila.Formatters.format_money_with_paise(Nila.Gst.Money.paise(value))
end
