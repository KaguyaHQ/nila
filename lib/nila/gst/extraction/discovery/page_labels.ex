defmodule Nila.Gst.Extraction.Discovery.PageLabels do
  @moduledoc "Groups classified purchase pages into documents."

  @doc """
  Groups purchase pages in page order. A continuation joins the preceding invoice.
  An orphan continuation starts a group with a `continuation_without_start` issue.
  """
  def stitch(labels) do
    labels
    |> Enum.sort_by(& &1.page)
    |> Enum.reduce([], fn label, segments ->
      case {label.label, segments} do
        {:continuation, [%{kind: :invoice} = open | rest]} ->
          [%{open | pages: open.pages ++ [label.page]} | rest]

        {:continuation, segments} ->
          [
            new_segment(label, :invoice, [{:continuation_without_start, label.page}])
            | segments
          ]

        {:start, segments} ->
          [new_segment(label, :invoice, []) | segments]

        {kind, segments} ->
          [new_segment(label, kind, []) | segments]
      end
    end)
    |> Enum.reverse()
  end

  defp new_segment(label, kind, issues) do
    %{
      pages: [label.page],
      kind: kind,
      invoice_no: label.invoice_no,
      reason: label.reason,
      issues: issues
    }
  end
end
