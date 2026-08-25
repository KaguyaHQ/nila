defmodule Nila.Gst.Sales.InvoiceCorrections do
  @moduledoc "Append-only accountant corrections over pristine sales-bill extraction."

  import Ecto.Query

  alias Nila.Gst.Intake.Dumps
  alias Nila.Gst.Sales.{Gstr1, InvoiceCorrection, TallyPacket}
  alias Nila.Gst.StateCodes
  alias Nila.Gstin
  alias Nila.Repo
  alias Nila.TallyMappings

  @top_fields ~w(invoice_number invoice_date buyer_name buyer_gstin place_of_supply narration)
  @line_fields ~w(
    item_name description hsn_sac quantity uom printed_unit_price printed_line_amount
    printed_line_total printed_taxable_value taxable_value cgst_rate cgst_amount
    sgst_rate sgst_amount igst_rate igst_amount
  )
  @numeric_line_fields ~w(
    quantity printed_unit_price printed_line_amount printed_line_total printed_taxable_value
    taxable_value cgst_rate cgst_amount sgst_rate sgst_amount igst_rate igst_amount
  )
  @max_corrections 100

  @doc "Correction events for one invoice, oldest first."
  def list(org_id, client_id, batch_ref, source_id)
      when is_integer(org_id) and is_integer(client_id) and is_binary(batch_ref) and
             is_binary(source_id) do
    Repo.all(
      from correction in InvoiceCorrection,
        where:
          correction.org_id == ^org_id and correction.client_id == ^client_id and
            correction.batch_ref == ^batch_ref and correction.source_id == ^source_id,
        order_by: [asc: correction.inserted_at, asc: correction.id]
    )
  end

  def list(_org_id, _client_id, _batch_ref, _source_id), do: []

  @doc "Layers the latest saved value per field over pristine invoices."
  def apply(org_id, client_id, batch_ref, invoices)
      when is_integer(org_id) and is_integer(client_id) and is_binary(batch_ref) and
             is_list(invoices) do
    corrections =
      Repo.all(
        from correction in InvoiceCorrection,
          where:
            correction.org_id == ^org_id and correction.client_id == ^client_id and
              correction.batch_ref == ^batch_ref,
          order_by: [asc: correction.inserted_at, asc: correction.id]
      )
      |> Enum.group_by(& &1.source_id)

    Enum.map(invoices, fn invoice ->
      source_id = Gstr1.source_id(invoice)

      invoice
      |> Map.put_new("id", source_id)
      |> apply_events(Map.get(corrections, source_id, []))
      |> Dumps.rehydrate()
    end)
  end

  def apply(_org_id, _client_id, _batch_ref, invoices) when is_list(invoices), do: invoices

  @doc "Validates and atomically records one invoice's changed fields."
  def save(org_id, client_id, batch_ref, source_id, changes, corrected_by_id \\ nil)

  def save(org_id, client_id, batch_ref, source_id, changes, corrected_by_id)
      when is_integer(org_id) and is_integer(client_id) and is_binary(batch_ref) and
             is_binary(source_id) and is_map(changes) and
             (is_nil(corrected_by_id) or is_integer(corrected_by_id)) do
    Repo.transact(fn ->
      save_in_transaction(org_id, client_id, batch_ref, source_id, changes, corrected_by_id)
    end)
  end

  def save(_org_id, _client_id, _batch_ref, _source_id, _changes, _corrected_by_id),
    do: {:error, :invalid_corrections}

  @doc "Atomically saves one reviewed invoice and all Tally posting selections."
  def save_workbench(
        org_id,
        client_id,
        batch_ref,
        source_id,
        company_id,
        attrs,
        corrected_by_id \\ nil
      )

  def save_workbench(
        org_id,
        client_id,
        batch_ref,
        source_id,
        company_id,
        attrs,
        corrected_by_id
      )
      when is_integer(org_id) and is_integer(client_id) and is_binary(batch_ref) and
             is_binary(source_id) and is_integer(company_id) and is_map(attrs) and
             (is_nil(corrected_by_id) or is_integer(corrected_by_id)) do
    Repo.transact(fn ->
      with {:ok, submission} <- normalize_workbench_attrs(attrs),
           {:ok, correction_result} <-
             save_in_transaction(
               org_id,
               client_id,
               batch_ref,
               source_id,
               submission.invoice,
               corrected_by_id
             ),
           {:ok, posting_result} <-
             TallyMappings.save_sales_posting_in_transaction(
               org_id,
               company_id,
               party_identity(correction_result.invoice, source_id),
               submission.party_ledger_identity,
               submission.posting_profile
             ),
           {:ok, line_mappings} <-
             TallyMappings.save_sales_ledger_choices_in_transaction(
               org_id,
               company_id,
               correction_result.invoice,
               submission.line_sales_ledger_identities
             ) do
        {:ok,
         correction_result
         |> Map.merge(posting_result)
         |> Map.put(:line_mappings, line_mappings)}
      end
    end)
  end

  def save_workbench(
        _org_id,
        _client_id,
        _batch_ref,
        _source_id,
        _company_id,
        _attrs,
        _corrected_by_id
      ),
      do: {:error, :invalid_workbench_submission}

  @doc false
  def save_in_transaction(org_id, client_id, batch_ref, source_id, changes, corrected_by_id) do
    with :ok <- validate_corrector(org_id, corrected_by_id),
         {:ok, dumps} <- fetch_sales_batch(org_id, client_id, batch_ref),
         canonical_ref <- TallyPacket.ref(dumps),
         {:ok, pristine} <- source_invoice(dumps, source_id),
         current <- apply(org_id, client_id, canonical_ref, [pristine]) |> hd(),
         {:ok, corrections} <- normalize_changes(current, changes) do
      events =
        Enum.flat_map(corrections, fn {field_path, value} ->
          previous = field_value(current, field_path)

          if equivalent?(previous, value) do
            []
          else
            [
              %InvoiceCorrection{
                org_id: org_id,
                client_id: client_id,
                corrected_by_id: corrected_by_id
              }
              |> InvoiceCorrection.changeset(%{
                batch_ref: canonical_ref,
                source_id: source_id,
                field_path: field_path,
                payload: %{"from" => json_value(previous), "to" => json_value(value)}
              })
              |> Repo.insert!()
            ]
          end
        end)

      effective = apply_events(current, events) |> Dumps.rehydrate()
      {:ok, %{invoice: effective, corrections: events}}
    end
  end

  defp fetch_sales_batch(org_id, client_id, batch_ref) do
    with {:ok, ids} <- decode_ref(batch_ref),
         {:ok, dumps} <- Dumps.fetch_batch(org_id, client_id, ids),
         true <- Enum.all?(dumps, &(&1.kind == "sales")) do
      {:ok, dumps}
    else
      _invalid -> {:error, :not_found}
    end
  end

  defp validate_corrector(_org_id, nil), do: :ok

  defp validate_corrector(org_id, user_id) do
    if Repo.exists?(
         from membership in Nila.Orgs.Membership,
           where: membership.org_id == ^org_id and membership.user_id == ^user_id
       ) do
      :ok
    else
      {:error, :corrector_not_in_org}
    end
  end

  defp source_invoice(dumps, source_id) do
    matches =
      dumps
      |> Enum.filter(&(&1.status == "extracted"))
      |> Enum.flat_map(& &1.invoices)
      |> Enum.map(&Dumps.rehydrate/1)
      |> Enum.filter(&(Gstr1.source_id(&1) == source_id))

    case matches do
      [invoice] -> {:ok, invoice}
      [] -> {:error, :source_not_found}
      _duplicates -> {:error, :ambiguous_source}
    end
  end

  defp normalize_changes(invoice, changes) do
    flattened = flatten_changes(changes)

    cond do
      flattened == [] ->
        {:error, :empty_corrections}

      length(flattened) > @max_corrections ->
        {:error, :too_many_corrections}

      true ->
        Enum.reduce_while(flattened, {:ok, []}, fn {field_path, raw}, {:ok, normalized} ->
          field_path = canonical_field_path(to_string(field_path))

          with :ok <- validate_field(invoice, field_path),
               {:ok, value} <- coerce(field_path, raw) do
            {:cont, {:ok, [{field_path, value} | normalized]}}
          else
            {:error, reason} -> {:halt, {:error, {:invalid_correction, field_path, reason}}}
          end
        end)
        |> case do
          {:ok, normalized} -> {:ok, normalized |> Enum.reverse() |> Enum.uniq_by(&elem(&1, 0))}
          error -> error
        end
    end
  end

  defp flatten_changes(changes) do
    Enum.flat_map(changes, fn
      {key, lines} when key in ["line_items", :line_items] -> flatten_lines(lines)
      {field, value} -> [{field, value}]
    end)
  end

  defp flatten_lines(lines) when is_list(lines) do
    lines
    |> Enum.with_index()
    |> Enum.flat_map(fn {fields, index} -> flatten_line(index, fields) end)
  end

  defp flatten_lines(lines) when is_map(lines) do
    Enum.flat_map(lines, fn {index, fields} ->
      case Integer.parse(to_string(index)) do
        {index, ""} -> flatten_line(index, fields)
        _invalid -> [{"line_items[invalid]", fields}]
      end
    end)
  end

  defp flatten_lines(_invalid), do: [{"line_items", nil}]

  defp flatten_line(index, fields) when is_integer(index) and is_map(fields) do
    Enum.map(fields, fn {field, value} -> {"line_items[#{index}].#{field}", value} end)
  end

  defp flatten_line(index, value), do: [{"line_items[#{index}]", value}]

  defp canonical_field_path("voucher_number"), do: "invoice_number"
  defp canonical_field_path("voucher_date"), do: "invoice_date"
  defp canonical_field_path("pos"), do: "place_of_supply"

  defp canonical_field_path(path) do
    path
    |> String.replace(~r/\.unit$/, ".uom")
    |> String.replace(~r/\.rate$/, ".printed_unit_price")
    |> String.replace(~r/\.taxable_amount$/, ".taxable_value")
  end

  defp validate_field(_invoice, field) when field in @top_fields, do: :ok

  defp validate_field(invoice, field) do
    case Regex.run(~r/^line_items\[(\d+)\]\.([a-z_]+)$/, field) do
      [_, index, line_field] when line_field in @line_fields ->
        if Enum.at(invoice["line_items"] || [], String.to_integer(index)),
          do: :ok,
          else: {:error, :line_not_found}

      _unsupported ->
        {:error, :unsupported_field}
    end
  end

  defp coerce("invoice_date", nil), do: {:ok, nil}
  defp coerce("invoice_date", ""), do: {:ok, nil}
  defp coerce("invoice_date", %Date{} = date), do: {:ok, date}

  defp coerce("invoice_date", value) when is_binary(value) do
    case Nila.Gst.Purchase.Books.parse_date(value) do
      %Date{} = date -> {:ok, date}
      nil -> {:error, :invalid_date}
    end
  end

  defp coerce("buyer_gstin", value) do
    value = normalize_optional_string(value)

    cond do
      is_nil(value) -> {:ok, nil}
      Gstin.valid?(String.upcase(value)) -> {:ok, String.upcase(value)}
      true -> {:error, :invalid_gstin}
    end
  end

  defp coerce("place_of_supply", value) when is_binary(value) do
    value = String.trim(value)
    code = StateCodes.code_for(value) || StateCodes.normalize_code(value)

    if code && StateCodes.name_for(code),
      do: {:ok, code},
      else: {:error, :invalid_place_of_supply}
  end

  defp coerce("place_of_supply", _value), do: {:error, :invalid_place_of_supply}

  defp coerce(field, value) when field in @top_fields,
    do: {:ok, normalize_optional_string(value)}

  defp coerce(field, value) do
    case Regex.run(~r/^line_items\[\d+\]\.([a-z_]+)$/, field) do
      [_, line_field] when line_field in @numeric_line_fields -> coerce_number(value)
      [_, _line_field] -> {:ok, normalize_optional_string(value)}
      _invalid -> {:error, :unsupported_field}
    end
  end

  defp coerce_number(nil), do: {:ok, nil}
  defp coerce_number(value) when is_integer(value) and value >= 0, do: {:ok, value * 1.0}
  defp coerce_number(value) when is_float(value) and value >= 0, do: {:ok, value}

  defp coerce_number(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, nil}

      value ->
        case Float.parse(value) do
          {number, ""} when number >= 0 -> {:ok, number}
          _invalid -> {:error, :invalid_number}
        end
    end
  end

  defp coerce_number(_value), do: {:error, :invalid_number}

  defp apply_events(invoice, events) do
    Enum.reduce(events, invoice, fn event, effective ->
      put_field(effective, event.field_path, event.payload["to"])
    end)
  end

  defp put_field(invoice, field, value) when field in @top_fields,
    do: Map.put(invoice, field, value)

  defp put_field(invoice, field, value) do
    [_, index, line_field] = Regex.run(~r/^line_items\[(\d+)\]\.([a-z_]+)$/, field)
    index = String.to_integer(index)

    Map.update!(
      invoice,
      "line_items",
      &List.update_at(&1, index, fn line -> Map.put(line, line_field, value) end)
    )
  end

  defp field_value(invoice, field) when field in @top_fields, do: invoice[field]

  defp field_value(invoice, field) do
    [_, index, line_field] = Regex.run(~r/^line_items\[(\d+)\]\.([a-z_]+)$/, field)

    invoice
    |> Map.get("line_items", [])
    |> Enum.at(String.to_integer(index))
    |> Map.get(line_field)
  end

  defp equivalent?(%Date{} = left, right) do
    case date_value(right) do
      %Date{} = right -> Date.compare(left, right) == :eq
      _not_a_date -> false
    end
  end

  defp equivalent?(left, %Date{} = right), do: equivalent?(right, left)
  defp equivalent?(left, right) when is_number(left) and is_number(right), do: left == right
  defp equivalent?(left, right), do: left == right

  defp date_value(%Date{} = date), do: date
  defp date_value(value) when is_binary(value), do: Nila.Gst.Purchase.Books.parse_date(value)
  defp date_value(_value), do: nil

  defp json_value(%Date{} = date), do: Date.to_iso8601(date)
  defp json_value(value), do: value

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_optional_string(value), do: to_string(value)

  defp attr(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp normalize_workbench_attrs(attrs) do
    invoice = attr(attrs, :invoice)
    party_ledger_identity = attr(attrs, :party_ledger_identity)
    posting_profile = attr(attrs, :posting_profile)
    line_sales_ledger_identities = attr(attrs, :line_sales_ledger_identities)

    if is_map(invoice) and is_binary(party_ledger_identity) and is_map(posting_profile) and
         is_map(line_sales_ledger_identities) do
      {:ok,
       %{
         invoice: invoice,
         party_ledger_identity: party_ledger_identity,
         posting_profile: posting_profile,
         line_sales_ledger_identities: line_sales_ledger_identities
       }}
    else
      {:error, :invalid_workbench_submission}
    end
  end

  defp party_identity(invoice, source_id) do
    %{
      gstin: invoice["buyer_gstin"],
      name: invoice["buyer_name"],
      source_key: source_id
    }
  end

  defp decode_ref(batch_ref) do
    ids =
      batch_ref
      |> String.split("-", trim: true)
      |> Enum.map(&Integer.parse/1)

    if ids != [] and Enum.all?(ids, &match?({id, ""} when id > 0, &1)),
      do: {:ok, Enum.map(ids, &elem(&1, 0))},
      else: {:error, :not_found}
  end
end
