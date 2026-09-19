defmodule Nila.Clients.Import do
  @moduledoc "Preview and add client identities from Excel. Existing clients are never updated."
  alias Nila.{Clients, Repo}
  alias Nila.Accounts.Policy
  alias Nila.Clients.{Client, ImportXlsx}

  def preview(scope, bytes) do
    with :ok <- authorize(scope), {:ok, workbook} <- ImportXlsx.read(bytes) do
      {:ok, Map.put(workbook, :rows, review(scope.current_org.id, workbook.rows))}
    end
  end

  def save(scope, rows) when is_list(rows) and length(rows) <= 1000 do
    with :ok <- authorize(scope) do
      Repo.transact(fn ->
        # Serialize simultaneous imports for this firm, then recheck duplicates.
        Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [73_012, scope.current_org.id])

        rows =
          Enum.zip(rows, review(scope.current_org.id, rows))
          |> Enum.map(fn {approved, current} ->
            if approved.status == :ready, do: current, else: approved
          end)

        Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, results} ->
          if row.status == :ready do
            case Repo.insert(changeset(scope.current_org.id, row)) do
              {:ok, _client} ->
                {:cont, {:ok, [%{row | status: :added, message: "Added"} | results]}}

              {:error, _} ->
                {:halt, {:error, :changed}}
            end
          else
            {:cont, {:ok, [row | results]}}
          end
        end)
        |> case do
          {:ok, results} -> {:ok, Enum.reverse(results)}
          error -> error
        end
      end)
    end
  end

  def save(_, _), do: {:error, :too_many_rows}

  defp review(org_id, rows) do
    existing = Clients.list_clients(org_id)
    names = MapSet.new(existing, &name_key(&1.name))
    gstins = MapSet.new(existing, & &1.gstin)

    rows =
      Enum.map(rows, &Map.take(&1, [:row, :name, :gstin, :gst_username]))
      |> Enum.map(fn row ->
        row
        |> Map.merge(%{name: clean(row.name), gstin: clean_gstin(row.gstin)})
        |> Map.put(:gst_username, clean(row[:gst_username]))
      end)

    name_counts = Enum.frequencies_by(rows, &name_key(&1.name))
    gstin_counts = Enum.frequencies_by(rows, & &1.gstin)

    Enum.map(rows, fn row ->
      key = name_key(row.name)

      {status, message} =
        cond do
          row.name in [:formula, :invalid_cell] or row.gstin in [:formula, :invalid_cell] or
              row.gst_username in [:formula, :invalid_cell] ->
            {:invalid, "Use plain values, not formulas or cell errors."}

          is_binary(row.gst_username) and String.length(row.gst_username) > 100 ->
            {:invalid, "GST username is too long (maximum 100 characters)."}

          row.gst_username not in [nil, ""] and row.gstin == nil ->
            {:invalid, "Add a GSTIN for this GST username."}

          row.name in [nil, ""] ->
            {:invalid, "Client name is missing."}

          String.length(row.name) > 255 ->
            {:invalid, "Client name is too long (maximum 255 characters)."}

          row.gstin != nil and not Nila.Gstin.valid?(row.gstin) ->
            {:invalid, "GSTIN is invalid. Check its 15 characters and check digit."}

          row.gstin != nil and MapSet.member?(gstins, row.gstin) ->
            {:skip, "GSTIN already exists in Clients."}

          MapSet.member?(names, key) ->
            {:skip, "Client name already exists. Check the existing client."}

          name_counts[key] > 1 or (row.gstin != nil and gstin_counts[row.gstin] > 1) ->
            {:invalid, "Duplicate name or GSTIN in this file. Keep one row."}

          true ->
            {:ready, "Ready to add"}
        end

      Map.merge(row, %{status: status, message: message})
    end)
  end

  defp changeset(org_id, row),
    do:
      Client.changeset(%Client{org_id: org_id}, %{
        name: row.name,
        gstin: row.gstin,
        gst_username: row.gst_username,
        type: "company",
        chase_channel: "none"
      })

  defp clean(value) when is_binary(value), do: String.trim(value)
  defp clean(value), do: value

  defp clean_gstin(value) when is_binary(value),
    do: value |> String.trim() |> String.upcase() |> then(&if(&1 == "", do: nil, else: &1))

  defp clean_gstin(value), do: value

  defp name_key(value) when is_binary(value),
    do: value |> String.downcase() |> String.replace(~r/\s+/, " ") |> String.trim()

  defp name_key(value), do: value

  defp authorize(scope),
    do: if(Policy.can?(scope, :edit_records), do: :ok, else: {:error, :forbidden})

  def template do
    sheet =
      XlsxWriter.new_sheet("Clients")
      |> XlsxWriter.write(0, 0, "Client name", format: [:bold])
      |> XlsxWriter.write(0, 1, "GSTIN", format: [:bold])
      |> XlsxWriter.write(0, 2, "GST username", format: [:bold])
      |> XlsxWriter.set_column_width(0, 40)
      |> XlsxWriter.set_column_width(1, 24)
      |> XlsxWriter.set_column_width(2, 28)
      |> XlsxWriter.freeze_panes(1, 0)

    XlsxWriter.generate([sheet])
  end

  def error_message(:headers),
    do:
      "The first row must contain Client name, GSTIN and GST username columns. Use the template below."

  def error_message(:multiple_sheets),
    do: "Upload a workbook with one worksheet containing your client list."

  def error_message(:too_large),
    do: "This workbook is too large. Use a file under 2 MB with only the client list."

  def error_message(:too_many_rows),
    do: "Import up to 1,000 clients at a time. Split this file into smaller lists."

  def error_message(:empty_file), do: "No client rows found. Add your clients below the headings."
  def error_message(:forbidden), do: "Your role cannot add clients."

  def error_message(:changed),
    do: "The client list changed while saving. Preview the file again; no clients were added."

  def error_message(_),
    do: "This file could not be read. Save it as an Excel workbook (.xlsx) and try again."
end
