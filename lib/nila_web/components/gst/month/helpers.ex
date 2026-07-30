defmodule NilaWeb.Components.Gst.Month.Helpers do
  @moduledoc false

  def invoice_issues(issues_by_invoice, invoice),
    do: issues_by_invoice[invoice["invoice_number"]] || []

  # A blocking issue is not a louder warning — it is the one thing on the page a
  # reviewer cannot answer, so it reads as an error and stays open.
  def severity_variant("blocking"), do: "error"
  def severity_variant("error"), do: "error"
  def severity_variant(_), do: "warning"
end
