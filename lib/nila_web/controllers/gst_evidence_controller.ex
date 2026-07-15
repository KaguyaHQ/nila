defmodule NilaWeb.GstEvidenceController do
  @moduledoc """
  Streams a client month's scanned bills through an org-membership check.

  The tenant is taken from `current_scope.current_org` (server session), never
  from a URL param, and the storage key is rebuilt from that org id — so one
  firm can never fetch another firm's evidence even by guessing a `client_id`.
  A foreign `client_id` fails the org-scoped month lookup and 404s before any
  file read.
  """
  use NilaWeb, :controller

  alias Nila.Gst.ClientMonths

  def show(conn, %{"client_id" => client_id, "period" => period, "basename" => basename}) do
    org_id = conn.assigns.current_scope.current_org.id

    case ClientMonths.fetch_evidence(org_id, client_id, period, basename) do
      {:ok, bytes} ->
        conn
        |> put_resp_content_type(content_type(basename))
        |> put_resp_header("cache-control", "private, max-age=300")
        |> send_resp(200, bytes)

      {:error, _reason} ->
        conn
        |> put_status(:not_found)
        |> text("Not found")
    end
  end

  defp content_type(basename) do
    case Path.extname(basename) do
      ".png" -> "image/png"
      ext when ext in [".jpg", ".jpeg"] -> "image/jpeg"
      ".webp" -> "image/webp"
      _ -> "application/octet-stream"
    end
  end
end
