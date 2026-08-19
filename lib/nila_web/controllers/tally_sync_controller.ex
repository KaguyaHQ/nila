defmodule NilaWeb.TallySyncController do
  use NilaWeb, :controller

  alias Nila.TallyDevices
  alias Nila.TallySync

  def create(conn, %{"company_identity" => identity}) when is_binary(identity) do
    with {:ok, device} <- authenticate(conn),
         {:ok, run} <- TallySync.start(device, identity) do
      conn
      |> put_status(:created)
      |> json(run_json(run))
    else
      {:error, :unauthorized} -> error(conn, :unauthorized, "invalid_device")
      {:error, :company_not_found} -> error(conn, :not_found, "company_not_found")
      _ -> error(conn, :unprocessable_entity, "sync_failed")
    end
  end

  def create(conn, _), do: error(conn, :unprocessable_entity, "invalid_request")

  def masters(conn, params), do: put_pipeline(conn, params, :masters)
  def vouchers(conn, params), do: put_pipeline(conn, params, :vouchers)

  def fail(conn, %{"id" => id, "pipeline" => pipeline, "error" => message})
      when pipeline in ["masters", "vouchers"] and is_binary(message) do
    with {:ok, device} <- authenticate(conn),
         {run_id, ""} <- Integer.parse(id),
         {:ok, run} <-
           TallySync.fail_pipeline(device, run_id, String.to_existing_atom(pipeline), message) do
      json(conn, run_json(run))
    else
      {:error, :unauthorized} -> error(conn, :unauthorized, "invalid_device")
      _ -> error(conn, :unprocessable_entity, "sync_failed")
    end
  end

  def fail(conn, _), do: error(conn, :unprocessable_entity, "invalid_request")

  defp put_pipeline(conn, %{"id" => id, "records" => records} = params, pipeline)
       when is_list(records) do
    with {:ok, device} <- authenticate(conn),
         {run_id, ""} <- Integer.parse(id),
         {:ok, run} <-
           TallySync.put_pipeline(device, run_id, pipeline, records, params["complete"] == true) do
      json(conn, run_json(run))
    else
      {:error, :unauthorized} -> error(conn, :unauthorized, "invalid_device")
      {:error, :not_found} -> error(conn, :not_found, "sync_not_found")
      _ -> error(conn, :unprocessable_entity, "invalid_records")
    end
  end

  defp put_pipeline(conn, _, _), do: error(conn, :unprocessable_entity, "invalid_request")

  defp authenticate(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case TallyDevices.authenticate_device(token) do
          nil -> {:error, :unauthorized}
          device -> {:ok, device}
        end

      _ ->
        {:error, :unauthorized}
    end
  end

  defp run_json(run) do
    %{
      id: run.id,
      company: if(Ecto.assoc_loaded?(run.company), do: run.company.name, else: nil),
      period_start: run.period_start,
      period_end: run.period_end,
      status: run.status,
      masters_status: run.masters_status,
      vouchers_status: run.vouchers_status,
      masters_count: run.masters_count,
      vouchers_count: run.vouchers_count
    }
  end

  defp error(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
