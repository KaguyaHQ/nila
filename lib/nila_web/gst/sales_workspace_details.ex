defmodule NilaWeb.Gst.SalesWorkspaceDetails do
  @moduledoc "Formatted GSTR-1 detail tables using the existing workspace projections."

  alias NilaWeb.Components.Gst.Month.{SalesWorkspace, HsnSummary, Helpers}

  def build(workings, client, period, opts \\ []) do
    filed? = Keyword.get(opts, :filed, false)

    SalesWorkspace.detail_rows(workings, client, period)
    |> Map.new(fn
      {"documents", section} ->
        {"documents", documents(section)}

      {key, section} ->
        {key,
         if(filed?,
           do: filed_section(key, section.title, workings, client.id, period),
           else: invoices(key, section, client.id, period)
         )}
    end)
    |> Map.put(
      "hsn",
      if(filed?, do: filed_hsn(workings.derived), else: hsn(workings, client.id, period))
    )
  end

  defp filed_section(key, title, workings, client_id, period) do
    portal_key = if key == "sez", do: "b2b", else: key
    groups = workings.derived[portal_key] || []

    rows =
      if key == "b2cs" do
        Enum.map(groups, fn entry ->
          totals = Nila.Gst.Sales.Review.Values.filed_totals(%{"b2cs" => [entry]})

          %{
            cells: %{
              "number" => "B2C aggregate",
              "date" => "—",
              "gstin" => "—",
              "pos" => text(entry["pos"]),
              "rate" => Helpers.percent(entry["rt"]),
              "taxable" => Helpers.rupees(totals.taxable),
              "tax" => Helpers.rupees(totals.tax)
            },
            invoice_path: nil
          }
        end)
      else
        list_key = if key == "cdnr", do: "nt", else: "inv"

        for group <- groups,
            entry <- group[list_key] || [],
            key not in ["b2b", "sez"] or entry["inv_typ"] in ["SEWP", "SEWOP"] == (key == "sez") do
          number = entry["inum"] || entry["nt_num"]
          source = unique_number(workings.active_invoices, number)

          totals =
            Nila.Gst.Sales.Review.Values.filed_totals(%{
              portal_key => [Map.put(group, list_key, [entry])]
            })

          %{
            cells: %{
              "number" => text(number),
              "date" => text(entry["idt"] || entry["nt_dt"]),
              "gstin" => text(group["ctin"]),
              "pos" => text(entry["pos"] || group["pos"]),
              "rate" => "—",
              "taxable" => Helpers.rupees(totals.taxable),
              "tax" => Helpers.rupees(totals.tax)
            },
            invoice_path: if(source, do: invoice_path(client_id, period, source["id"]))
          }
        end
      end

    rows =
      rows
      |> Enum.with_index()
      |> Enum.map(fn {row, index} -> Map.put(row, :id, "#{key}-filed-#{index}") end)

    %{
      title: title,
      description: "The figures recorded in the filed GSTR-1 snapshot.",
      note: nil,
      groups: [
        %{
          id: key,
          label: nil,
          columns:
            columns([
              {"number", "Document", :left},
              {"date", "Date", :left},
              {"gstin", "GSTIN", :left},
              {"pos", "Place of supply", :left},
              {"rate", "Rate", :right},
              {"taxable", "Taxable", :right},
              {"tax", "Output tax", :right}
            ]),
          rows: rows
        }
      ]
    }
  end

  defp filed_hsn(derived) do
    groups =
      for {id, label, key} <- [
            {"registered", "B2B and registered notes", "hsn_b2b"},
            {"unregistered", "B2C", "hsn_b2c"}
          ] do
        rows =
          (get_in(derived || %{}, ["hsn", key]) || [])
          |> Enum.with_index()
          |> Enum.map(fn {row, index} ->
            tax = Enum.sum(Enum.map(~w(camt samt iamt csamt), &(row[&1] || 0)))

            %{
              id: "#{id}-filed-#{index}",
              cells: %{
                "hsn" => text(row["hsn_sc"]),
                "description" => text(row["desc"]),
                "uqc" => text(row["uqc"]),
                "quantity" => text(row["qty"]),
                "rate" => Helpers.percent(row["rt"]),
                "taxable" => Helpers.rupees(row["txval"]),
                "tax" => Helpers.rupees(tax)
              },
              invoice_path: nil
            }
          end)

        %{
          id: id,
          label: label,
          columns:
            columns([
              {"hsn", "HSN/SAC", :left},
              {"description", "Description", :left},
              {"uqc", "UQC", :left},
              {"quantity", "Quantity", :right},
              {"rate", "Rate", :right},
              {"taxable", "Taxable", :right},
              {"tax", "Output tax", :right}
            ]),
          rows: rows
        }
      end

    %{
      title: "HSN-wise summary of outward supplies",
      description: "HSN/SAC totals recorded in the filed GSTR-1 snapshot.",
      note: "The filed snapshot does not retain invoice-level HSN contributions.",
      groups: groups
    }
  end

  defp invoices(key, section, client_id, period) do
    columns =
      columns([
        {"number", "Invoice", :left},
        {"date", "Date", :left},
        {"buyer", "Customer", :left},
        {"treatment", "Treatment", :left},
        {"taxable", "Taxable", :right},
        {"tax", "Output tax", :right},
        {"status", "Status", :left}
      ])

    rows =
      Enum.map(section.rows, fn row ->
        %{
          id: row.id,
          cells: cells(row, ~w(number date buyer treatment taxable tax status)),
          invoice_path: invoice_path(client_id, period, row.id)
        }
      end)

    %{
      title: section.title,
      description: "The invoices contributing to this GSTR-1 table.",
      note: nil,
      groups: [%{id: key, label: nil, columns: columns, rows: rows}]
    }
  end

  defp documents(section) do
    columns =
      columns([
        {"kind", "Document kind", :left},
        {"from", "From", :left},
        {"to", "To", :left},
        {"total", "Total", :right},
        {"cancelled", "Cancelled", :right},
        {"net_issued", "Net issued", :right}
      ])

    rows =
      Enum.map(
        section.rows,
        &%{
          id: &1.id,
          cells: cells(&1, ~w(kind from to total cancelled net_issued)),
          invoice_path: nil
        }
      )

    %{
      title: section.title,
      description: "The document series derived from invoices supplied to Nila.",
      note:
        "This checks the documents Nila received; it does not prove every issued invoice was supplied.",
      groups: [%{id: "documents", label: nil, columns: columns, rows: rows}]
    }
  end

  defp hsn(workings, client_id, period) do
    projection = HsnSummary.detail_rows(workings.derived, workings.active_invoices)

    registered =
      projection.registered
      |> Enum.filter(&(&1.kind == :node))
      |> Enum.map(fn node ->
        children =
          projection.registered
          |> Enum.filter(&(&1.kind == :contrib and &1.parent == node.id))
          |> Enum.map(fn row ->
            source = unique_number(workings.active_invoices, row.inum)

            %{
              id: row.id,
              cells: %{
                "hsn" => text(row.inum),
                "description" => text(row.label),
                "rate" => "",
                "count" => "",
                "taxable" => Helpers.rupees(row.taxable),
                "tax" => Helpers.rupees(row.tax)
              },
              invoice_path: if(source, do: invoice_path(client_id, period, source["id"]))
            }
          end)

        %{
          id: node.id,
          cells: %{
            "hsn" => text(node.hsn),
            "description" => node.description || "Official description unavailable",
            "rate" => Helpers.percent(node.rate),
            "count" => text(node.count),
            "taxable" => Helpers.rupees(node.taxable),
            "tax" => Helpers.rupees(node.tax)
          },
          invoice_path: nil,
          children: children
        }
      end)

    unregistered =
      Enum.with_index(projection.unregistered)
      |> Enum.map(fn {row, index} ->
        tax = Enum.sum(Enum.map(~w(camt samt iamt csamt), &(row[&1] || 0)))

        %{
          id: "b2c-#{index}",
          cells: %{
            "hsn" => text(row["hsn_sc"]),
            "description" => text(row["desc"]),
            "uqc" => text(row["uqc"]),
            "quantity" => text(row["qty"]),
            "rate" => Helpers.percent(row["rt"]),
            "taxable" => Helpers.rupees(row["txval"]),
            "tax" => Helpers.rupees(tax)
          },
          invoice_path: nil
        }
      end)

    %{
      title: "HSN-wise summary of outward supplies",
      description: "Taxable value and tax grouped by HSN/SAC and rate.",
      note: nil,
      groups: [
        %{
          id: "registered",
          label: "B2B and registered notes",
          columns:
            columns([
              {"hsn", "HSN/SAC", :left},
              {"description", "Description", :left},
              {"rate", "Rate", :right},
              {"count", "Invoices", :right},
              {"taxable", "Taxable", :right},
              {"tax", "Output tax", :right}
            ]),
          rows: registered
        },
        %{
          id: "unregistered",
          label: "B2C",
          columns:
            columns([
              {"hsn", "HSN/SAC", :left},
              {"description", "Description", :left},
              {"uqc", "UQC", :left},
              {"quantity", "Quantity", :right},
              {"rate", "Rate", :right},
              {"taxable", "Taxable", :right},
              {"tax", "Output tax", :right}
            ]),
          rows: unregistered
        }
      ]
    }
  end

  defp unique_number(invoices, number) do
    case Enum.filter(invoices, &(&1["invoice_number"] == number)) do
      [invoice] -> invoice
      _ -> nil
    end
  end

  defp columns(columns),
    do: Enum.map(columns, fn {key, label, align} -> %{key: key, label: label, align: align} end)

  defp cells(row, keys),
    do: Map.new(keys, fn key -> {key, row |> Map.get(String.to_existing_atom(key)) |> text()} end)

  defp text(nil), do: "—"
  defp text(value), do: to_string(value)

  defp invoice_path(client_id, period, id),
    do: "/gst/#{client_id}/#{period}/sales/invoices/#{URI.encode_www_form(id)}"
end
