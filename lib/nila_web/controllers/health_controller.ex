defmodule NilaWeb.HealthController do
  @moduledoc """
  Liveness/readiness probe hit by the container healthcheck and (optionally)
  external uptime monitors. Returns 200 only when the DB is reachable and Oban
  is running; 503 otherwise so the orchestrator can react.
  """
  use NilaWeb, :controller

  def check(conn, _params) do
    db_ok =
      try do
        Nila.Repo.query!("SELECT 1")
        true
      rescue
        _ -> false
      end

    oban_ok =
      try do
        # nil when the queue isn't running, a map when it is
        Oban.check_queue(queue: :documents) != nil
      rescue
        _ -> false
      end

    healthy = db_ok and oban_ok
    status = if healthy, do: :ok, else: :service_unavailable

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(status)
    |> json(%{
      status: if(healthy, do: "healthy", else: "degraded"),
      db: if(db_ok, do: "ok", else: "fail"),
      oban: if(oban_ok, do: "ok", else: "fail")
    })
  end
end
