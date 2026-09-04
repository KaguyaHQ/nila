defmodule Nila.Gst.Sales.Gstr1Packet do
  @moduledoc "Builds a portal-shaped GSTR-1 draft from one sales-bill batch."

  alias Nila.Gst.Issues
  alias Nila.Gst.Sales.{Gstr1, Gstr1Readiness, Invoice, TallyPacket}

  def build(dumps, seller_gstin) when is_list(dumps) and is_binary(seller_gstin) do
    packet = TallyPacket.prepare(dumps)
    excluded_ids = MapSet.new(packet.excluded, &Invoice.source_id/1)
    invoices = Enum.reject(packet.all_invoices, &(Invoice.source_id(&1) in excluded_ids))

    issues =
      packet.source_issues ++
        Gstr1Readiness.issues(invoices) ++ Gstr1.month_validation_issues(invoices)

    with false <- invoices == [],
         {:ok, period} <- filing_period(invoices),
         false <- Enum.any?(issues, &Issues.gating?/1) do
      {:ok,
       %{
         period: period,
         return: Gstr1.derive(invoices, Gstr1.production_header(seller_gstin, period))
       }}
    else
      true -> {:error, :invalid_sales_data}
      {:error, _reason} = error -> error
    end
  end

  defp filing_period(invoices) do
    periods = invoices |> Enum.map(&invoice_period/1) |> Enum.uniq()

    case periods do
      [period] when is_binary(period) -> {:ok, period}
      [nil] -> {:error, :invalid_sales_data}
      _mixed -> {:error, :mixed_periods}
    end
  end

  defp invoice_period(%{"invoice_date" => %Date{} = date}),
    do: Calendar.strftime(date, "%Y-%m")

  defp invoice_period(%{
         "invoice_date" => <<year::binary-size(4), "-", month::binary-size(2), _rest::binary>>
       }),
       do: year <> "-" <> month

  defp invoice_period(_invoice), do: nil
end
