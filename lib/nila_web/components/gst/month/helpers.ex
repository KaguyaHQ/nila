defmodule NilaWeb.Components.Gst.Month.Helpers do
  @moduledoc false

  def invoice_issues(issues_by_invoice, invoice),
    do: issues_by_invoice[invoice["invoice_number"]] || []

  def severity_variant("error"), do: "error"
  def severity_variant(_), do: "warning"
end
