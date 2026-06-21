defmodule NilaWeb.Plugs.CacheRawBody do
  @moduledoc false

  def read_body(conn, opts) do
    read_body(conn, opts, [])
  end

  defp read_body(conn, opts, acc) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        cache_body(conn, [body | acc])

      {:more, body, conn} ->
        read_body(conn, opts, [body | acc])

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cache_body(conn, chunks) do
    raw_body = chunks ++ (conn.private[:raw_body] || [])
    conn = Plug.Conn.put_private(conn, :raw_body, raw_body)
    {:ok, IO.iodata_to_binary(Enum.reverse(chunks)), conn}
  end
end
