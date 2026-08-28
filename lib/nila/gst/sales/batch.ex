defmodule Nila.Gst.Sales.Batch do
  @moduledoc "Stable references and scoped lookup for one uploaded sales-bill batch."

  alias Nila.Gst.Intake.Dumps

  def fetch(org_id, client_id, batch_ref) do
    with {:ok, dump_ids} <- decode_ref(batch_ref),
         {:ok, dumps} <- Dumps.fetch_batch(org_id, client_id, dump_ids) do
      {:ok, dumps}
    end
  end

  def ref(dumps) when is_list(dumps), do: Enum.map_join(dumps, "-", & &1.id)

  defp decode_ref(batch_ref) when is_binary(batch_ref) do
    ids =
      batch_ref
      |> String.split("-", trim: true)
      |> Enum.map(&Integer.parse/1)

    if ids != [] and Enum.all?(ids, &match?({id, ""} when id > 0, &1)),
      do: {:ok, Enum.map(ids, &elem(&1, 0))},
      else: {:error, :not_found}
  end

  defp decode_ref(_batch_ref), do: {:error, :not_found}
end
