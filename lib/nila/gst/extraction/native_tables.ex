defmodule Nila.Gst.Extraction.NativeTables do
  @moduledoc "Converts eligible digital PDF pages to tables; other pages retain images."

  @max_bytes 2_000_000
  @timeout 120_000

  def extract(bytes, page_count) do
    python = Application.get_env(:nila, __MODULE__, [])[:python]

    if is_binary(python) do
      executable =
        if Path.type(python) == :absolute, do: python, else: System.find_executable(python)

      if executable,
        do: convert(bytes, page_count, executable),
        else: {:error, :native_tables_unavailable}
    else
      {:error, :native_tables_not_configured}
    end
  end

  defp convert(bytes, page_count, python) do
    dir = Path.join(System.tmp_dir!(), "nila-tables-#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)

    try do
      source = Path.join(dir, "source.pdf")
      output = Path.join(dir, "pages.json")
      script = Application.app_dir(:nila, "priv/python/invoice_tables.py")
      File.write!(source, bytes)

      with :ok <- run(python, [script, source, output]),
           {:ok, %{size: size}} when size <= @max_bytes <- File.stat(output),
           {:ok, json} <- File.read(output),
           {:ok, %{"pages" => pages}} <- Jason.decode(json),
           true <- valid_pages?(pages, page_count) do
        {:ok, Map.new(pages, &{&1["page"], &1["text"]}),
         Map.new(pages, &{to_string(&1["page"]), &1["fallback_reason"]})}
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, :invalid_native_tables}
      end
    after
      File.rm_rf(dir)
    end
  rescue
    _error -> {:error, :native_tables_unavailable}
  end

  defp valid_pages?(pages, count) when is_list(pages) do
    Enum.map(pages, & &1["page"]) == Enum.to_list(1..count) and
      Enum.all?(
        pages,
        &(is_binary(&1["text"]) and
            (is_nil(&1["fallback_reason"]) or is_binary(&1["fallback_reason"])))
      )
  end

  defp valid_pages?(_, _), do: false

  defp run(python, args) do
    port =
      Port.open({:spawn_executable, String.to_charlist(python)}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        :hide,
        args: Enum.map(args, &String.to_charlist/1)
      ])

    deadline = System.monotonic_time(:millisecond) + @timeout
    await_exit(port, deadline)
  end

  defp await_exit(port, deadline) do
    receive do
      {^port, {:data, _diagnostic}} -> await_exit(port, deadline)
      {^port, {:exit_status, 0}} -> :ok
      {^port, {:exit_status, _status}} -> {:error, :native_tables_failed}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Port.close(port)
        {:error, :native_tables_timeout}
    end
  end
end
