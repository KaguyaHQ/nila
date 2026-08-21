defmodule Nila.Gst.Sales.TallyPacket do
  @moduledoc """
  The sales-bills handoff: effective sales invoices that can become Tally vouchers,
  the exact invoices held out, and the control totals for the generated XML.
  """

  alias Nila.Gst.Filing.TallyPrime
  alias Nila.Gst.Intake.{Dump, Dumps}
  alias Nila.Gst.Sales.Gstr1

  def fetch(org_id, client_id, batch_ref) do
    with {:ok, dump_ids} <- decode_ref(batch_ref),
         {:ok, dumps} <- Dumps.fetch_batch(org_id, client_id, dump_ids) do
      {:ok, dumps}
    end
  end

  def ref(dumps) when is_list(dumps), do: Enum.map_join(dumps, "-", & &1.id)

  def prepare(dumps) when is_list(dumps) do
    active = Enum.filter(dumps, &(&1.status == "extracted"))

    source_invoices =
      active
      |> Enum.flat_map(& &1.invoices)
      |> Enum.map(&Dumps.rehydrate/1)

    {invoices, excluded} =
      Enum.split_with(source_invoices, &exportable?/1)

    totals =
      Enum.reduce(invoices, %{taxable_paise: 0, tax_paise: 0}, fn invoice, totals ->
        amounts = Gstr1.extracted_totals(invoice)

        %{
          taxable_paise: totals.taxable_paise + paise(amounts.taxable),
          tax_paise: totals.tax_paise + paise(amounts.tax)
        }
      end)

    Map.merge(totals, %{
      invoices: invoices,
      excluded: excluded,
      failed_files: Enum.reject(dumps, &(&1.status == "extracted")),
      unread_pages: unread_pages(active)
    })
  end

  def build_xml(dumps) when is_list(dumps) do
    packet = prepare(dumps)
    TallyPrime.build(%{active_invoices: packet.invoices})
  end

  def original_name(%Dump{meta: meta, id: id}) do
    Map.get(meta || %{}, "original_name") || "File ##{id}"
  end

  defp unread_pages(dumps) do
    for dump <- dumps,
        page <- Map.get(dump.meta || %{}, "unaccounted_pages", []) do
      %{file: original_name(dump), page: page}
    end
  end

  defp exportable?(invoice) do
    match?(
      {:ok, _xml},
      TallyPrime.build(%{active_invoices: [invoice]})
    )
  end

  defp decode_ref(batch_ref) when is_binary(batch_ref) do
    ids =
      batch_ref
      |> String.split("-", trim: true)
      |> Enum.map(&Integer.parse/1)

    if ids != [] and Enum.all?(ids, &match?({_, ""}, &1)) do
      {:ok, Enum.map(ids, &elem(&1, 0))}
    else
      {:error, :not_found}
    end
  end

  defp decode_ref(_batch_ref), do: {:error, :not_found}

  defp paise(value) when is_number(value), do: round(value * 100)
  defp paise(_value), do: 0
end
