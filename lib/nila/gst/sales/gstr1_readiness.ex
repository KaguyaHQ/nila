defmodule Nila.Gst.Sales.Gstr1Readiness do
  @moduledoc "GSTR-1 output capabilities layered over intrinsic invoice readiness."

  alias Nila.Gst.Issues
  alias Nila.Gst.Sales.{Gstr1, OutputIssues}

  def issues(invoices) when is_list(invoices) do
    invoices
    |> Gstr1.gstr1_capability_issues()
    |> Enum.concat(OutputIssues.cess(invoices))
    |> Issues.normalize_all()
  end
end
