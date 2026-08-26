defmodule Nila.Gst.Sales.OutputIssues do
  @moduledoc "Shared structured issues for capabilities absent from more than one sales output."

  alias Nila.Gst.Cess
  alias Nila.Gst.Issues

  def cess(invoices) when is_list(invoices) do
    Enum.flat_map(invoices, fn invoice ->
      case Cess.hits(invoice) do
        [] -> []
        hits -> [cess_issue(invoice, hits)]
      end
    end)
  end

  defp cess_issue(invoice, hits) do
    evidence =
      Enum.map_join(hits, " ", fn hit ->
        description = if hit.description, do: " #{inspect(hit.description)}", else: ""
        "Line #{hit.line}#{description} is HSN #{hit.hsn}."
      end)

    %{
      "invoice" => invoice["invoice_number"],
      "source_id" => invoice["id"],
      "code" => "cess_unsupported",
      "level" => Issues.level_for("cess_unsupported"),
      "message" =>
        "#{evidence} Nila's current sales outputs do not carry compensation cess and would emit csamt 0.",
      "fields" => Enum.map(hits, &"line_items[#{&1.line - 1}].hsn_sac"),
      "lines" => Enum.map(hits, & &1.line),
      "hsn_codes" => hits |> Enum.map(& &1.hsn) |> Enum.uniq()
    }
  end
end
