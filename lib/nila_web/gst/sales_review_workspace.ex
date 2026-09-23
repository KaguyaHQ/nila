defmodule NilaWeb.Gst.SalesReviewWorkspace do
  @moduledoc "GST-only projection and commands for the React invoice review."

  alias Nila.Accounts.Policy
  alias Nila.Gst.{Proposals, StateCodes}
  alias Nila.Gst.Sales.{Invoice, Months, Processing, Review, Workings, TaxpayerChecks}
  alias Nila.Gst.Sales.Invoice.{Corrections, Validation}
  alias Nila.Gst.Sales.Review.{Resolutions, Values}
  alias NilaWeb.Gst.{InvoiceWorkbench, InvoicePresentation, SalesIssuePresentation}

  @facts ~w(invoice_number invoice_date buyer_name buyer_gstin place_of_supply narration)
  @totals ~w(printed_total_taxable printed_total_tax printed_grand_total)
  @money_fields ~w(printed_unit_price printed_line_amount printed_line_total printed_taxable_value taxable_value cgst_amount sgst_amount igst_amount)

  def load(scope, client, period, source_id) do
    with {:ok, month} <- Months.get_by_period(scope.current_org.id, client.id, period),
         workings = Resolutions.effective_workings(Processing.review_month(month)),
         review = Review.build(workings),
         %{} = item <- Review.lookup(review.all, source_id) do
      source = InvoiceWorkbench.source_batch(scope.current_org.id, client.id, period, source_id)

      {:ok,
       %{
         month: month,
         workings: workings,
         review: review,
         item: item,
         source: source,
         client: client,
         scope: scope,
         period: period
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  def project(context) do
    invoice = context.item.invoice
    reason = lock_reason(context)
    can_edit = is_nil(reason)

    %{
      client: Map.take(context.client, [:id, :name]),
      period: context.period,
      invoice: %{
        id: Invoice.source_id(invoice),
        number: text(invoice["invoice_number"]),
        date: text(invoice["invoice_date"]),
        buyer_name: text(invoice["buyer_name"]),
        buyer_gstin: text(invoice["buyer_gstin"]),
        place_of_supply:
          InvoicePresentation.place_of_supply_label(context.item.treatment["place_of_supply"])
      },
      facts: field_values(invoice, @facts),
      lines:
        Enum.with_index(invoice["line_items"] || [])
        |> Enum.map(fn {line, index} ->
          values = field_values(line, Invoice.correctable_line_fields())

          values =
            Map.update!(
              values,
              "line_amount_tax_inclusion",
              &if(&1 == "", do: "unknown", else: &1)
            )

          display =
            Map.new(Invoice.correctable_line_fields(), fn field ->
              {field,
               if(field in @money_fields,
                 do: InvoicePresentation.rupees(line[field]),
                 else: InvoicePresentation.working_number(line[field])
               )}
            end)

          %{index: index, values: values, display: display}
        end),
      totals:
        Enum.map(InvoicePresentation.invoice_total_rows(invoice), fn row ->
          %{
            field: row.field,
            label: row.label,
            calculated:
              if(is_nil(row.calculated),
                do: "Not calculated",
                else: InvoicePresentation.rupees(row.calculated)
              ),
            printed:
              if(is_nil(row.printed),
                do: "Not captured",
                else: InvoicePresentation.rupees(row.printed)
              ),
            difference: if(row.mismatch?, do: InvoicePresentation.rupees(row.difference)),
            status:
              cond do
                row.matches? -> "matches"
                row.mismatch? -> "mismatch"
                true -> "unavailable"
              end
          }
        end),
      printed_totals: field_values(invoice, @totals),
      checks: NilaWeb.Gst.InvoiceCheckPresentation.results(invoice),
      issues:
        Enum.map(context.item.actionable_issues, fn issue ->
          %{
            target: Workings.issue_key(issue),
            code: issue["code"],
            title: SalesIssuePresentation.register_reason(issue),
            message: issue["message"],
            status: issue["status"],
            can_confirm: can_edit and confirmable?(issue),
            action_label: confirm_label(issue, context)
          }
          |> Map.merge(issue_copy(issue, invoice))
        end),
      source: evidence(context),
      queue:
        Enum.map(context.review.all, fn item ->
          %{
            id: item.source_id,
            number: text(item.invoice["invoice_number"]),
            customer: text(item.invoice["buyer_name"]),
            amount: InvoicePresentation.rupees(Validation.comparison_totals(item.invoice).total),
            status: if(item.open_actionable_targets == [], do: "ready", else: "needs_review")
          }
        end),
      can_edit: can_edit,
      lock_reason: reason,
      editable_fields: %{facts: @facts, line: Invoice.correctable_line_fields(), totals: @totals},
      states:
        Enum.map(StateCodes.all(), fn label ->
          %{label: label, value: StateCodes.code_for(label)}
        end)
    }
  end

  defp issue_copy(%{"code" => "buyer_gst_name_review"} = issue, invoice) do
    facts = get_in(invoice, ["taxpayer_checks", "buyer"])

    if is_map(facts) do
      names =
        [facts["legal_name"], facts["trade_name"]]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.uniq()
        |> Enum.join(" / ")

      outcome = Enum.find(TaxpayerChecks.outcomes(invoice), &(&1.id == issue["code"]))

      if names != "" and outcome do
        %{
          message: "The bill says “#{invoice["buyer_name"]}”. GST records say “#{names}”.",
          lookup_details: outcome.detail
        }
      else
        %{}
      end
    else
      %{}
    end
  end

  defp issue_copy(_issue, _invoice), do: %{}

  def update(context, params) do
    with :ok <- writable(context),
         {:ok, changes} <- changes(params),
         {:ok, _} <-
           Corrections.save(
             context.scope.current_org.id,
             context.client.id,
             context.source.batch_ref,
             context.item.source_id,
             changes,
             context.scope.user.id
           ) do
      :ok
    end
  end

  def confirm(context, target) when is_binary(target) do
    with :ok <- writable(context),
         %{} = issue <-
           Enum.find(context.item.actionable_issues, &(Workings.issue_key(&1) == target)),
         true <- confirmable?(issue),
         {:ok, _} <-
           Resolutions.record(
             context.month,
             %{
               "verb" => "confirm_issue",
               "target" => target,
               "payload" => confirmation_payload(issue, context)
             },
             context.scope.user.id
           ) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unsupported_confirmation}
    end
  end

  def confirm(_, _), do: {:error, :unsupported_confirmation}

  defp confirmable?(issue), do: issue["status"] == "open" and not Workings.blocking?(issue)

  defp confirmation_payload(issue, context) do
    invoice = context.item.invoice

    cond do
      TaxpayerChecks.issue?(issue) ->
        %{
          "decision" => "confirm_taxpayer",
          "taxpayer_checks" => invoice["taxpayer_checks"],
          "buyer_name" => invoice["buyer_name"],
          "seller_name" => invoice["seller_name"]
        }

      issue["code"] in ~w(seller_identity_unverified seller_identity_mismatch) ->
        %{"decision" => "confirm_client", "seller_identity" => invoice["seller_identity"]}

      true ->
        %{
          "decision" => "use_extracted_lines",
          "proposal" => Proposals.freeze(proposal(issue, context))
        }
    end
  end

  defp proposal(issue, context),
    do:
      Proposals.for_issue(
        issue,
        Values.for_invoice(context.item.invoice, context.workings),
        Validation.checks(context.item.invoice)
      )

  defp confirm_label(issue, context) do
    case proposal(issue, context) do
      %{action: action} -> action
      _ -> "Checked against the bill"
    end
  end

  defp writable(context) do
    cond do
      not Policy.can?(context.scope, :edit_records) -> {:error, :forbidden}
      context.month.filed_at != nil -> {:error, :filed}
      is_nil(context.source) -> {:error, :no_source}
      not Processing.reviewable?(context.source.dump) -> {:error, :no_source}
      true -> :ok
    end
  end

  defp lock_reason(context) do
    case writable(context) do
      :ok -> nil
      {:error, :forbidden} -> "Your role can read invoices, but cannot change them."
      {:error, :filed} -> "This month is filed. Its recorded invoices cannot be changed."
      _ -> "The original source is not available for editing."
    end
  end

  defp changes(%{"section" => section, "values" => values} = params) when is_map(values) do
    fields =
      case section do
        "facts" -> @facts
        "totals" -> @totals
        "line" -> Invoice.correctable_line_fields()
        _ -> []
      end

    valid? =
      map_size(values) > 0 and
        Enum.all?(values, fn {key, value} ->
          key in fields and (is_binary(value) or is_nil(value))
        end)

    cond do
      not valid? ->
        {:error, :invalid_changes}

      section == "line" and is_integer(params["line_index"]) and params["line_index"] >= 0 ->
        {:ok, %{"line_items" => %{to_string(params["line_index"]) => values}}}

      section == "line" ->
        {:error, :invalid_changes}

      true ->
        {:ok, values}
    end
  end

  defp changes(_), do: {:error, :invalid_changes}

  defp evidence(%{source: nil}), do: nil

  defp evidence(context) do
    dump = context.source.dump
    invoice = context.item.invoice

    pages =
      List.wrap(invoice["source_pages"] || invoice["page"])
      |> Enum.filter(&(is_integer(&1) and &1 > 0))

    url =
      case dump.file_keys do
        [key] ->
          if String.downcase(Path.extname(key)) == ".pdf",
            do: "/gst/#{dump.client_id}/#{dump.period}/original/#{dump.id}/0"

        _ ->
          nil
      end

    images =
      List.wrap(invoice["images"] || invoice["image"])
      |> Enum.filter(&is_binary/1)
      |> Enum.map(
        &"/sales-bills/#{context.client.id}/dumps/#{dump.id}/evidence/#{URI.encode(Path.basename(&1))}"
      )

    %{
      url: url,
      name: Nila.Gst.Sales.SourcePacket.original_name(dump),
      pages: pages,
      images: images
    }
  end

  defp field_values(source, fields), do: Map.new(fields, &{&1, text(source[&1])})
  defp text(nil), do: ""
  defp text(%Date{} = value), do: Date.to_iso8601(value)
  defp text(value) when is_float(value), do: :erlang.float_to_binary(value, [:short])
  defp text(value) when is_binary(value), do: value
  defp text(value) when is_integer(value), do: Integer.to_string(value)
  defp text(_), do: ""
end
