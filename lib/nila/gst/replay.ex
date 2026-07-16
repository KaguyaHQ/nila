defmodule Nila.Gst.Replay do
  @moduledoc """
  Append-only latest-wins replay semantics shared by the purchase
  (`gst_resolutions`) and sales (`sales_resolutions`) decision stores.

  A `reopen` event is undo: for its target it discards every prior decision,
  returning the target to the engine's default. Append-only ordering means a
  later decision recorded after a reopen simply lands on the clean slate.
  `key` names the target field in the resolution maps (`"books_id"` on the
  purchase side, `"target"` on the sales side).
  """

  @doc "Drops each target's events that precede its last reopen, then the reopens."
  def drop_reopened(resolutions, key) do
    last_reopen =
      resolutions
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {r, i}, acc ->
        if r["verb"] == "reopen", do: Map.put(acc, r[key], i), else: acc
      end)

    resolutions
    |> Enum.with_index()
    |> Enum.reject(fn {r, i} ->
      r["verb"] == "reopen" or i < Map.get(last_reopen, r[key], -1)
    end)
    |> Enum.map(fn {r, _i} -> r end)
  end

  @doc """
  The effective latest decision per target: `%{target => verb}` after undo
  cancellation. A target absent from the map is still open.
  """
  def decisions(resolutions, key) do
    resolutions
    |> drop_reopened(key)
    |> Enum.reduce(%{}, fn r, acc -> Map.put(acc, r[key], r["verb"]) end)
  end
end
