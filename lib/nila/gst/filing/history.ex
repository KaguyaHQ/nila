defmodule Nila.Gst.Filing.History do
  @moduledoc """
  Builds the firm's filed-history grid from persisted purchase and sales months.
  """

  alias Nila.Clients
  alias Nila.Gst.Purchase.Months, as: PurchaseMonths
  alias Nila.Gst.Sales.Months, as: SalesMonths

  @doc "Returns clients down and the latest 12 worked periods across the register."
  def grid(org_id) do
    clients = Clients.list_clients(org_id)
    purchase_months = PurchaseMonths.list_for_org(org_id)
    sales_months = SalesMonths.list_for_org(org_id)

    months =
      Map.merge(
        Map.new(purchase_months, &{{&1.client_id, &1.period}, %{purchase: &1}}),
        Map.new(sales_months, &{{&1.client_id, &1.period}, %{sales: &1}}),
        fn _key, purchase, sales -> Map.merge(purchase, sales) end
      )

    periods =
      months
      |> Map.keys()
      |> Enum.map(&elem(&1, 1))
      |> Enum.uniq()
      |> Enum.sort(:desc)
      |> Enum.take(12)

    rows =
      clients
      |> Enum.sort_by(&String.downcase(&1.name))
      |> Enum.map(fn client ->
        cells =
          for period <- periods,
              month = months[{client.id, period}],
              month != nil,
              into: %{} do
            {period, cell(month)}
          end

        %{client_id: client.id, client_name: client.name, cells: cells}
      end)

    %{periods: periods, rows: rows}
  end

  defp cell(months) do
    purchase = months[:purchase]
    sales = months[:sales]
    r1_filed = sales != nil and sales.filed_at != nil
    gstr3b_filed = purchase != nil and purchase.filed_at != nil

    %{
      state: cell_state(purchase, sales, r1_filed, gstr3b_filed),
      r1_filed: r1_filed,
      gstr3b_filed: gstr3b_filed,
      r1_arn: sales && sales.filing_arn,
      gstr3b_arn: purchase && purchase.filing_arn
    }
  end

  defp cell_state(purchase, sales, r1_filed, gstr3b_filed) do
    cond do
      purchase != nil and sales != nil and r1_filed and gstr3b_filed -> :filed
      purchase != nil and sales != nil and (r1_filed or gstr3b_filed) -> :partial
      purchase == nil and r1_filed -> :filed
      sales == nil and gstr3b_filed -> :filed
      true -> :open
    end
  end
end
