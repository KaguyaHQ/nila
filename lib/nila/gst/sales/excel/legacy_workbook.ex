defmodule Nila.Gst.Sales.Excel.LegacyWorkbook do
  @moduledoc "Bounded cell decoding for binary .xls reports using the existing Python runtime."
  @timeout 30_000
  @max_output 8_000_000

  def read(bytes) do
    configured = Application.get_env(:nila, Nila.Gst.Extraction.NativeTables, [])[:python] || "python"
    executable = if Path.type(configured) == :absolute, do: configured, else: System.find_executable(configured)
    if executable, do: decode(executable, bytes), else: {:error, :xls_reader_unavailable}
  end

  defp decode(executable, bytes) do
    # Transient decoder input only; the original is retained through Storage.
    path = Path.join(System.tmp_dir!(), "nila-xls-#{Ecto.UUID.generate()}.xls")
    try do
      File.write!(path, bytes)
      script = Application.app_dir(:nila, "priv/python/read_xls.py")
      port = Port.open({:spawn_executable, String.to_charlist(executable)}, [:binary, :exit_status,
        :use_stdio, :stderr_to_stdout, :hide, args: Enum.map([script, path], &String.to_charlist/1)])
      with {:ok, json} <- collect(port, System.monotonic_time(:millisecond) + @timeout, [], 0),
           {:ok, result} <- Jason.decode(json) do
        result(result)
      else
        error -> error
      end
    after
      File.rm(path)
    end
  rescue
    _ -> {:error, :xls_reader_unavailable}
  end

  defp result(%{"sheets" => sheets, "date1904" => date1904}) do
    {:ok, %{date1904?: date1904, sheets: Enum.map(sheets, fn sheet ->
      %{name: sheet["name"], hidden?: sheet["hidden"], rows: Enum.map(sheet["rows"], &%{row: &1["row"], cells: &1["cells"]})}
    end)}}
  end
  defp result(%{"error" => "reader_unavailable"}), do: {:error, :xls_reader_unavailable}
  defp result(%{"error" => "too_large"}), do: {:error, :too_large}
  defp result(%{"error" => "formula_cells"}), do: {:error, "This .xls workbook contains formulas. Supply a values-only export; cached formula results are not trusted."}
  defp result(_), do: {:error, :invalid_file}

  defp collect(port, deadline, chunks, size) do
    receive do
      {^port, {:data, data}} when size + byte_size(data) <= @max_output -> collect(port, deadline, [data | chunks], size + byte_size(data))
      {^port, {:data, _}} -> Port.close(port); {:error, :too_large}
      {^port, {:exit_status, 0}} -> {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
      {^port, {:exit_status, _}} -> {:error, :invalid_file}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> Port.close(port); {:error, :invalid_file}
    end
  end
end
