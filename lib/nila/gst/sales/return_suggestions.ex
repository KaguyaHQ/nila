defmodule Nila.Gst.Sales.ReturnSuggestions do
  @moduledoc "Evidence-backed suggestions for review; never changes the supplied facts."
  alias Nila.Gst.Money

  def annotate(report) do
    Map.update!(report, "rows", fn rows ->
      Enum.map(rows, &Map.put(&1, "suggestion", suggestion(&1, rows)))
    end)
  end

  defp suggestion(%{"section" => section, "values" => v}, _rows)
       when section in ~w(hsn_b2b hsn_b2c) do
    amounts = Enum.map(~w(txval iamt camt samt), &v[&1])

    if v["rate"] in [nil, ""] and Enum.all?(amounts, &is_number/1) do
      [taxable, igst, cgst, sgst] = Enum.map(amounts, &Money.paise/1)

      consistent =
        (igst > 0 and cgst == 0 and sgst == 0) or
          (igst == 0 and cgst > 0 and cgst == sgst)

      if taxable > 0 and consistent do
        rate = Float.round((igst + cgst + sgst) / taxable * 100, 2)

        if rate > 0 and rate <= 100 and abs(round(taxable * rate / 100) - igst - cgst - sgst) <= 1 do
          %{
            "values" => %{"rate" => rate},
            "message" =>
              "Suggested #{rate}%: calculated from this row's taxable value and GST amounts. Confirm the applicable rate."
          }
        end
      end
    end
  end

  defp suggestion(%{"section" => "doc_issue", "values" => v}, rows) do
    if is_nil(v["doc_num"]) and is_binary(v["from"]) and v["from"] == v["to"] and
         v["totnum"] == 1 and v["cancel"] == 0 and v["net_issue"] == 1 do
      matches = Enum.filter(rows, &(&1["values"]["number"] == v["from"]))
      identities = Enum.uniq_by(matches, &Map.take(&1["values"], ~w(number date buyer_gstin)))

      if matches != [] and length(identities) == 1 and
           Enum.all?(matches, &(&1["section"] in ~w(b2b b2cl))) do
        %{
          "values" => %{"doc_num" => 1},
          "message" =>
            "Suggested outward invoice: #{v["from"]} is already listed in the report's sales invoices. This changes its document category only; it does not add an invoice."
        }
      end
    end
  end

  defp suggestion(_, _), do: nil
end
