defmodule Nila.Gst.Sales.SourceSpreadsheet.Cache do
  @moduledoc "Bounded cache for decoded, immutable sales source workbooks."
  use GenServer

  @max_entries 8
  @max_bytes 32_000_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def fetch(key, loader) when is_function(loader, 0) do
    ensure_started()

    case :ets.lookup(__MODULE__, key) do
      [{^key, workbook, _size, _inserted_at}] ->
        {:ok, workbook}

      [] ->
        with {:ok, workbook} <- loader.() do
          size = :erlang.external_size(workbook)

          if size <= @max_bytes do
            :ets.insert_new(__MODULE__, {key, workbook, size, System.monotonic_time()})
            GenServer.cast(__MODULE__, :trim)
          end

          {:ok, workbook}
        end
    end
  end

  defp ensure_started do
    if :ets.whereis(__MODULE__) == :undefined do
      # A running development server can reload this module before its supervisor restarts.
      case Supervisor.start_child(Nila.Supervisor, __MODULE__) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, :already_present} -> :ok
      end
    end
  end

  @impl true
  def init(:ok) do
    :ets.new(__MODULE__, [:named_table, :public, :set, read_concurrency: true])
    {:ok, :ok}
  end

  @impl true
  def handle_cast(:trim, state) do
    entries = :ets.tab2list(__MODULE__)
    total = Enum.sum(Enum.map(entries, &elem(&1, 2)))

    entries
    |> Enum.sort_by(&elem(&1, 3))
    |> Enum.reduce({length(entries), total}, fn {key, _, size, _}, {count, bytes} = acc ->
      if count > @max_entries or bytes > @max_bytes do
        :ets.delete(__MODULE__, key)
        {count - 1, bytes - size}
      else
        acc
      end
    end)

    {:noreply, state}
  end
end
