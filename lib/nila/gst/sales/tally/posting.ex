defmodule Nila.Gst.Sales.Tally.Posting do
  @moduledoc "Explicit sales posting with company-scoped ledger choices and a checked preview."
  import Ecto.Query
  alias Nila.{Repo, TallyDevices, TallyJobs, TallyMappings, TallySync}
  alias Nila.Gst.{Issues, Money}
  alias Nila.Gst.Intake.Dumps
  alias Nila.Gst.Sales.{Batch, Invoice, Months, SourcePacket}
  alias Nila.Gst.Sales.Review.Resolutions
  alias Nila.Gst.Sales.Invoice.SourceChanges
  alias Nila.Gst.Sales.Tally.Readiness
  alias Nila.Gst.Sales.Tally.History
  alias Nila.Gst.Filing.TallyPrime

  def load(org_id, client, period) do
    case TallyDevices.get_client_company(org_id, client.id) do
      {:error, :not_found} ->
        {:ok, %{enabled: false}}

      {:ok, company} ->
        dumps =
          Dumps.list(org_id, client.id, period)
          |> Enum.filter(&(&1.kind == "sales" and &1.sales_batch_id))

        workings =
          case Months.get_by_period(org_id, client.id, period) do
            {:ok, month} -> Resolutions.workings(month, source: :documents)
            _ -> %{active_invoices: [], issues: []}
          end

        sources =
          for dump <- dumps,
              invoice <- dump.invoices,
              into: %{},
              do: {Invoice.source_id(invoice), dump.sales_batch_id}

        active_ids = MapSet.new(workings.active_invoices, &Invoice.source_id/1)

        packet = SourcePacket.prepare(dumps)

        invoices =
          packet.invoices
          |> Enum.filter(&MapSet.member?(active_ids, Invoice.source_id(&1)))

        issues =
          (packet.source_issues ++ workings.issues)
          |> Enum.reduce(%{}, fn issue, acc ->
            Map.put(acc, {issue["code"], issue["source_id"], issue["source_ids"]}, issue)
          end)
          |> Map.values()

        ledgers = TallyMappings.list_ledger_choices(org_id, company.id)
        history = History.load(org_id, company.id, period, ledgers)

        profile =
          case TallyMappings.get_posting_profile(org_id, company.id) do
            {:ok, p} -> p
            _ -> nil
          end

        numbering = TallySync.voucher_numbering_issues(company.id, ["Sales"])
        sync = TallySync.coverage(org_id, company.id, period)
        snapshot_checked = sync.covered

        rows =
          Enum.map(
            invoices,
            &prepare(
              org_id,
              company,
              &1,
              sources,
              ledgers,
              profile,
              issues,
              numbering,
              snapshot_checked,
              history
            )
          )

        token =
          :crypto.hash(
            :sha256,
            :erlang.term_to_binary(
              {company.id, company.tally_guid, company.name, company.is_open, rows}
            )
          )
          |> Base.encode16(case: :lower)

        ready = Enum.filter(rows, &(&1.status == "ready"))

        writable =
          case Months.get_by_period(org_id, client.id, period) do
            {:ok, month} -> is_nil(month.filed_at)
            _ -> true
          end

        {:ok,
         %{
           enabled: true,
           company: %{id: company.id, name: company.name, is_open: company.is_open},
           proposals: Enum.map(rows, &Map.drop(&1, [:invoice, :batch_id, :amount_paise])),
           ledger_choices: Enum.map(ledgers, &choice/1),
           party_choices:
             ledgers |> Enum.filter(&TallyMappings.party_ledger?/1) |> Enum.map(&choice/1),
           sales_ledger_choices:
             ledgers |> Enum.filter(&TallyMappings.sales_ledger?/1) |> Enum.map(&choice/1),
           tax_ledger_choices:
             ledgers
             |> Enum.filter(fn l ->
               Enum.any?(~w(cgst sgst igst), &TallyMappings.tax_ledger_for_head?(l, &1))
             end)
             |> Enum.map(&choice/1),
           tax_choices_by_head:
             Map.new(~w(cgst sgst igst), fn head ->
               {head,
                ledgers
                |> Enum.filter(&TallyMappings.tax_ledger_for_head?(&1, head))
                |> Enum.map(&choice/1)}
             end),
           preview_token: token,
           ready_count: length(ready),
           ready_total: money(Enum.sum(Enum.map(ready, & &1.amount_paise))),
           can_edit: writable,
           sync: sync,
           can_refresh: writable and company.is_open and sync.status != "running",
           can_post: writable and company.is_open and ready != [],
           _rows: rows,
           _company: company
         }}
    end
  end

  def project(%{enabled: true} = data) do
    data
    |> Map.drop([:_rows, :_company])
    |> Map.update!(:proposals, fn proposals ->
      Enum.map(proposals, &Map.put(&1, :sales_summary, sales_summary(&1.sales_entries)))
    end)
  end

  def project(data), do: Map.drop(data, [:_rows, :_company])

  defp sales_summary(entries) do
    entries
    |> Enum.group_by(&(&1.ledger_identity || {:unresolved, &1.line_id}))
    |> Map.values()
    |> Enum.sort_by(fn group -> Enum.find_index(entries, &(&1.line_id == hd(group).line_id)) end)
    |> Enum.map(fn group ->
      %{
        ledger_identity: hd(group).ledger_identity,
        ledger_name: hd(group).ledger_name,
        line_ids: Enum.map(group, & &1.line_id),
        amount: group |> Enum.map(&Money.paise(&1.amount)) |> Enum.sum() |> money()
      }
    end)
  end

  def verify(org_id, client, period) do
    with {:ok, %{enabled: true} = data} <- load(org_id, client, period) do
      data._rows
      |> Enum.filter(&(&1.status == "unknown"))
      |> Enum.map(& &1.batch_id)
      |> Enum.uniq()
      |> Enum.reduce_while({:ok, 0}, fn id, {:ok, count} ->
        case TallyJobs.verify_indeterminate_by_sales_batch(org_id, id) do
          {:ok, n} -> {:cont, {:ok, count + n}}
          error -> {:halt, error}
        end
      end)
    end
  end

  def update(org_id, client, period, source_id, attrs, corrected_by_id \\ nil) do
    Repo.transact(fn ->
      with {:ok, company} <- TallyDevices.get_client_company(org_id, client.id),
           _company <-
             Repo.one!(
               from c in Nila.TallyDevices.Company,
                 where: c.id == ^company.id,
                 lock: "FOR UPDATE"
             ),
           :ok <- lock_sources(org_id, client.id, [source_id]),
           {:ok, refreshed} <- load(org_id, client, period),
           true <- refreshed.can_edit,
           true <- attrs["preview_token"] == refreshed.preview_token,
           row when not is_nil(row) <- Enum.find(refreshed._rows, &(&1.source_id == source_id)),
           true <- row.status in ["ready", "needs_input"],
           {:ok, invoice} <-
             correct_source(org_id, client.id, period, row, attrs, corrected_by_id),
           :ok <- save_party(org_id, company.id, invoice, attrs),
           :ok <- save_lines(org_id, company.id, invoice, attrs),
           :ok <- validate_taxes(org_id, company.id, invoice, attrs),
           :ok <- save_taxes(org_id, company.id, attrs) do
        {:ok, :saved}
      else
        {:error, :tax_rate_mismatch} -> {:error, :tax_rate_mismatch}
        {:error, {:invalid_correction, _, _}} = error -> error
        _ -> {:error, :invalid_mapping}
      end
    end)
  end

  defp correct_source(org_id, client_id, period, row, %{"source_changes" => changes}, user_id)
       when is_map(changes) and map_size(changes) > 0 do
    dumps =
      Dumps.list(org_id, client_id, period)
      |> Enum.filter(&(&1.sales_batch_id == row.batch_id))

    with {:ok, result} <-
           Nila.Gst.Sales.Invoice.Corrections.save_in_transaction(
             org_id,
             client_id,
             Batch.ref(dumps),
             row.source_id,
             changes,
             user_id
           ) do
      {:ok, result.invoice}
    end
  end

  defp correct_source(_, _, _, row, attrs, _) do
    if Map.has_key?(attrs, "source_changes"),
      do: {:error, :invalid_corrections},
      else: {:ok, row.invoice}
  end

  def post(org_id, client, period, attrs) do
    Repo.transact(fn ->
      with {:ok, %{enabled: true} = initial} <- load(org_id, client, period),
           _company <-
             Repo.one!(
               from c in Nila.TallyDevices.Company,
                 where: c.id == ^initial.company.id,
                 lock: "FOR UPDATE"
             ),
           {:ok, data} <- load(org_id, client, period),
           true <- data.can_post,
           true <- attrs["company_id"] == data.company.id,
           true <- attrs["preview_token"] == data.preview_token,
           ids when is_list(ids) and ids != [] <- attrs["invoice_ids"],
           true <- length(ids) == length(Enum.uniq(ids)),
           selected <- Enum.filter(data._rows, &(&1.source_id in ids)),
           true <-
             length(selected) == length(ids) and Enum.all?(selected, &(&1.status == "ready")),
           :ok <- lock_sources(org_id, client.id, ids),
           {:ok, refreshed} <- load(org_id, client, period),
           true <- refreshed.preview_token == data.preview_token,
           :ok <- TallyPrime.validate_company_gstin(data._company, client.gstin),
           {:ok, count} <- enqueue(org_id, data._company, selected) do
        {:ok, count}
      else
        _ -> {:error, :stale_or_not_ready}
      end
    end)
  end

  defp enqueue(org_id, company, rows) do
    rows
    |> Enum.group_by(& &1.batch_id)
    |> Enum.reduce_while({:ok, 0}, fn {batch_id, rows}, {:ok, count} ->
      with {:ok, _} <- Batch.pin_destination_in_transaction(org_id, batch_id, company.id),
           {:ok, items} <-
             TallyPrime.build_items_for_company(
               %{active_invoices: Enum.map(rows, & &1.invoice)},
               company.name
             ),
           items =
             Enum.zip_with(items, rows, fn item, row ->
               item
               |> Map.put(:invoice_source_id, row.source_id)
               |> Map.put(:source_id, row.source_id)
               |> Map.put(
                 :proposal,
                 row
                 |> Map.drop([:invoice, :batch_id, :amount_paise])
                 |> Jason.encode!()
                 |> Jason.decode!()
               )
             end),
           {:ok, jobs} <-
             TallyJobs.enqueue_vouchers(company, items,
               source_prefix: Batch.source_prefix(%Batch{id: batch_id}),
               sales_batch_id: batch_id
             ) do
        {:cont, {:ok, count + length(jobs)}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp prepare(
         org_id,
         company,
         invoice,
         sources,
         ledgers,
         profile,
         issues,
         numbering,
         snapshot_checked,
         history
       ) do
    source_id = Invoice.source_id(invoice)

    party =
      resolved(
        TallyMappings.resolve_party(
          org_id,
          company.id,
          %{
            gstin: invoice["buyer_gstin"],
            name: invoice["buyer_name"],
            source_key: source_id
          },
          ledgers: history.party_ledgers
        )
      )

    sales =
      invoice["line_items"]
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.map(fn {line, i} ->
        inference = History.sales(history, invoice, line)

        ledger =
          case TallyMappings.resolve_sales_ledger(org_id, company.id, line) do
            {:error, :legacy_mapping_needs_confirmation} ->
              nil

            result ->
              resolved(result) || profile_ledger(profile, :sales_ledger_identity, ledgers) ||
                inference.ledger
          end

        %{
          line_id: to_string(i),
          description: line["description"] || line["item_name"],
          ledger_identity: ledger && ledger.identity,
          ledger_name: ledger && ledger.name,
          suggested_ledger_identity:
            (is_nil(ledger) && inference.suggestion && inference.suggestion.identity) || nil,
          suggested_ledger_name:
            (is_nil(ledger) && inference.suggestion && inference.suggestion.name) || nil,
          basis:
            if(ledger && ledger != inference.ledger,
              do: "Saved ledger choice.",
              else: inference.basis
            ),
          history_count: if(ledger == inference.ledger, do: inference.history_count, else: 0),
          amount: money(Money.paise(line["taxable_value"])),
          line: line
        }
      end)

    taxes =
      for head <- ~w(cgst sgst igst),
          amount = Enum.sum(Enum.map(sales, &Money.paise(&1.line[head <> "_amount"]))),
          amount != 0 do
        key =
          %{
            "cgst" => :cgst_ledger_identity,
            "sgst" => :sgst_ledger_identity,
            "igst" => :igst_ledger_identity
          }[head]

        rates = History.rates(List.wrap(invoice["line_items"]), head)
        inference = History.tax(history, head, List.first(rates))

        ledger =
          if length(rates) == 1 do
            selected = profile_ledger(profile, key, ledgers)

            if selected && History.tax_rate_matches?(selected, head, hd(rates)),
              do: selected,
              else: inference.ledger
          end

        %{
          head: head,
          ledger_identity: ledger && ledger.identity,
          ledger_name: ledger && ledger.name,
          basis:
            if(length(rates) != 1,
              do: "Multiple tax rates need separate tax ledger allocations; posting is blocked.",
              else:
                if(ledger && ledger != inference.ledger,
                  do: "Saved ledger choice.",
                  else: inference.basis
                )
            ),
          history_count: if(ledger == inference.ledger, do: inference.history_count, else: 0),
          amount: money(amount)
        }
      end

    problems =
      issues
      |> Enum.filter(fn issue ->
        Issues.gating?(issue) and Readiness.relevant_invoice_issue?(issue) and
          issue["code"] not in ~w(sales_not_in_tally sales_document_missing tally_document_mismatch) and
          issue["status"] in [nil, "open"] and
          (issue["source_id"] == source_id or source_id in List.wrap(issue["source_ids"]))
      end)
      |> Enum.map(& &1["message"])

    problems =
      problems ++
        Enum.map(Readiness.issues([invoice]), & &1["message"]) ++
        if(party, do: [], else: ["Choose the party ledger."]) ++
        if(Enum.all?(sales, & &1.ledger_name),
          do: [],
          else: [
            if(Enum.all?(sales, &(&1.ledger_name || &1.suggested_ledger_identity)),
              do: "Confirm or change the suggested sales ledger.",
              else: "Choose a sales ledger for each invoice line."
            )
          ]
        ) ++
        if(Enum.all?(taxes, & &1.ledger_name), do: [], else: ["Choose the tax ledgers."]) ++
        if(
          Enum.any?(
            ~w(cgst sgst igst),
            &(length(History.rates(List.wrap(invoice["line_items"]), &1)) > 1)
          ),
          do: [
            "This bill has multiple tax rates. Separate tax ledger allocations are required before posting."
          ],
          else: []
        ) ++
        if(numbering == [],
          do: [],
          else: ["Tally Sales voucher numbering must preserve invoice numbers."]
        )

    posting =
      Map.new(taxes, &{&1.head <> "_ledger", &1.ledger_name})
      |> Map.merge(%{
        "party_ledger" => party && party.name,
        "sales_ledger" => Enum.find_value(sales, & &1.ledger_name),
        "line_sales_ledgers" =>
          Map.new(sales, &{to_string(String.to_integer(&1.line_id) + 1), &1.ledger_name})
      })

    prepared = Map.put(invoice, "tally_posting", posting)
    preview = TallyPrime.preview(prepared)

    problems =
      if match?({:ok, _}, preview) or problems != [],
        do: problems,
        else: problems ++ ["Check the invoice details before creating its voucher."]

    amount =
      case preview do
        {:ok, p} ->
          abs(p.party_amount)

        _ ->
          Enum.sum(Enum.map(sales, &Money.paise(&1.line["taxable_value"]))) +
            Enum.sum(Enum.map(taxes, &Money.paise(&1.amount)))
      end

    batch_id = sources[source_id]
    batch = Repo.get!(Batch, batch_id)

    problems =
      if batch.tally_company_id in [nil, company.id],
        do: problems,
        else: problems ++ ["This upload is pinned to another Tally company."]

    invoice_date =
      case invoice["invoice_date"] do
        %Date{} = date -> date
        value -> Nila.Gst.Dates.parse_date(value)
      end

    existing_count =
      if not is_nil(invoice_date) and not is_nil(invoice["invoice_number"]) do
        Repo.one(
          from voucher in Nila.TallyDevices.SyncedVoucher,
            where:
              voucher.org_id == ^org_id and voucher.company_id == ^company.id and
                voucher.voucher_type == "Sales" and voucher.date == ^invoice_date and
                voucher.voucher_number == ^invoice["invoice_number"],
            select: count(voucher.id)
        )
      else
        0
      end

    problems =
      case existing_count do
        0 ->
          problems

        1 ->
          problems ++
            [
              "An invoice with this number already exists in the latest Tally snapshot. Check it before creating another."
            ]

        count ->
          problems ++
            [
              "#{count} entries with this invoice number and date already exist in Tally. Check them before posting."
            ]
      end

    problems =
      if ledgers == [],
        do: ["Sync this company in Nila Connector to load its ledgers and voucher settings."],
        else: problems

    problems =
      if snapshot_checked,
        do: problems,
        else:
          problems ++
            [
              "Sync vouchers for this month in Nila Connector before posting, so existing invoices can be checked."
            ]

    job =
      TallyJobs.list_by_sales_batch(org_id, batch_id)
      |> Enum.find(fn job ->
        job.payload["invoice_source_id"] == source_id or
          job.payload["source_id"] == source_id or
          (is_nil(job.payload["invoice_source_id"]) and
             job.payload["source_id"] == item_source(prepared))
      end)

    status =
      case job do
        %{status: "succeeded"} -> "posted"
        %{status: status} when status in ["pending", "running"] -> "pending"
        %{status: "indeterminate"} -> "unknown"
        %{status: "failed"} -> "failed"
        _ -> if(problems == [], do: "ready", else: "needs_input")
      end

    problems =
      case job do
        %{status: "failed", error: error} ->
          problems ++ ["Posting failed: " <> posting_error(error)]

        %{status: "indeterminate", error: error} ->
          problems ++
            [
              "Tally's posting result is unknown. Check the result before posting again. " <>
                posting_error(error)
            ]

        _ ->
          problems
      end

    row = %{
      source_id: source_id,
      number: invoice["invoice_number"],
      date: invoice["invoice_date"],
      status: status,
      party_ledger: if(party, do: choice(party)),
      sales_entries: Enum.map(sales, &Map.delete(&1, :line)),
      tax_entries: taxes,
      grand_total: money(amount),
      amount_paise: amount,
      issues: Enum.uniq(problems),
      invoice: prepared,
      batch_id: batch_id
    }

    case job do
      %{payload: %{"proposal" => frozen}} when is_map(frozen) ->
        Enum.reduce(
          ~w(number date party_ledger sales_entries tax_entries grand_total),
          row,
          fn key, acc ->
            Map.put(acc, String.to_existing_atom(key), atomize_preview(key, frozen[key]))
          end
        )

      _ ->
        row
    end
  end

  defp atomize_preview(key, value) when key in ~w(sales_entries tax_entries),
    do: Enum.map(value, &atomize_map/1)

  defp atomize_preview("party_ledger", nil), do: nil
  defp atomize_preview("party_ledger", value), do: atomize_map(value)
  defp atomize_preview(_, value), do: value

  defp atomize_map(map),
    do: Map.new(map, fn {key, value} -> {String.to_existing_atom(key), value} end)

  defp posting_error(nil), do: "Open Tally and inspect this invoice."

  defp posting_error(error) when is_map(error) do
    error["message"] || error["error"] || error["reason"] ||
      Jason.encode!(error)
      |> then(fn value -> if is_binary(value), do: value, else: Jason.encode!(value) end)
  end

  defp lock_sources(org_id, client_id, ids) do
    Enum.sort(ids)
    |> Enum.reduce_while(:ok, fn source_id, :ok ->
      case SourceChanges.lock(org_id, client_id, source_id) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp item_source(invoice) do
    case TallyPrime.build_items_for_company(%{active_invoices: [invoice]}, "preview") do
      {:ok, [item]} -> item.source_id
      _ -> nil
    end
  end

  defp resolved({:ok, %{ledger: ledger}}), do: ledger
  defp resolved(_), do: nil
  defp profile_ledger(nil, _, _), do: nil

  defp profile_ledger(profile, key, ledgers),
    do: Enum.find(ledgers, &(&1.identity == Map.get(profile, key)))

  defp choice(ledger), do: %{identity: ledger.identity, name: ledger.name}
  defp money(paise), do: Money.rupees(paise) |> Decimal.round(2) |> Decimal.to_string(:normal)

  defp save_party(org_id, company_id, invoice, %{"party_ledger_identity" => identity}) do
    case TallyMappings.save_confirmed_party_choice_in_transaction(
           org_id,
           company_id,
           %{
             gstin: invoice["buyer_gstin"],
             name: invoice["buyer_name"],
             source_key: Invoice.source_id(invoice)
           },
           identity
         ) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp save_party(_, _, _, _), do: :ok

  defp save_lines(org_id, company_id, invoice, %{"line_sales_ledger_identities" => choices})
       when is_map(choices) do
    Enum.reduce_while(choices, :ok, fn {index, identity}, :ok ->
      with {index, ""} <- Integer.parse(index),
           line when not is_nil(line) <- Enum.at(invoice["line_items"], index),
           {:ok, _} <-
             TallyMappings.save_sales_ledger_choice_in_transaction(
               org_id,
               company_id,
               line,
               identity
             ) do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, :invalid_mapping}}
      end
    end)
  end

  defp save_lines(_, _, _, _), do: :ok

  defp save_taxes(org_id, company_id, %{"tax_ledger_identities" => choices})
       when is_map(choices) do
    fields = %{
      "cgst" => "cgst_ledger_identity",
      "sgst" => "sgst_ledger_identity",
      "igst" => "igst_ledger_identity"
    }

    case TallyMappings.save_posting_profile_in_transaction(
           org_id,
           company_id,
           Map.new(choices, fn {head, identity} -> {fields[head], identity} end)
         ) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp save_taxes(_, _, _), do: :ok

  defp validate_taxes(org_id, company_id, invoice, %{"tax_ledger_identities" => requested})
       when is_map(requested) do
    ledgers = TallyMappings.list_ledger_choices(org_id, company_id)

    Enum.reduce_while(requested, :ok, fn {head, identity}, _ ->
      rates = History.rates(List.wrap(invoice["line_items"]), head)
      ledger = Enum.find(ledgers, &(&1.identity == identity))

      if ledger && length(rates) == 1 && History.tax_rate_matches?(ledger, head, hd(rates)),
        do: {:cont, :ok},
        else: {:halt, {:error, :tax_rate_mismatch}}
    end)
  end

  defp validate_taxes(_, _, _, _), do: :ok
end
