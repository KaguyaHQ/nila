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

  alias Nila.Clients
  alias Nila.Gst.Intake.Dumps
  alias Nila.Gst.Purchase.Months, as: ClientMonths

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

  @doc "Streams a rendered page belonging to one Sales Bills upload dump."
  def sales_bill(conn, %{
        "client_id" => client_id,
        "dump_id" => dump_id,
        "basename" => basename
      }) do
    org_id = conn.assigns.current_scope.current_org.id

    with {:ok, dump_id} <- parse_int(dump_id),
         {:ok, bytes} <- Dumps.fetch_sales_evidence(org_id, client_id, dump_id, basename) do
      conn
      |> put_resp_content_type(content_type(basename))
      |> put_resp_header("cache-control", "private, max-age=300")
      |> send_resp(200, bytes)
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> text("Not found")
    end
  end

  @doc """
  Serves a dump's original file as a download. The dump row is the authority:
  it is fetched by (current org, dump id), and the path's client/period must
  match it — a foreign or mismatched id 404s before any storage read.
  """
  def original(conn, %{
        "client_id" => client_id,
        "period" => period,
        "dump_id" => dump_id,
        "index" => index
      }) do
    org_id = conn.assigns.current_scope.current_org.id

    with {:ok, index} <- parse_int(index),
         {:ok, dump_id} <- parse_int(dump_id),
         {:ok, dump, key, bytes} <-
           Dumps.fetch_original(org_id, client_id, period, dump_id, index),
         {:ok, client} <- Clients.get_client(org_id, dump.client_id) do
      ext = key |> Path.extname() |> String.downcase()

      conn
      |> put_resp_content_type(original_content_type(ext))
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="#{original_filename(client, dump, index, ext)}")
      )
      |> send_resp(200, bytes)
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> text("Not found")
    end
  end

  defp parse_int(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, :not_found}
    end
  end

  defp original_filename(client, dump, index, ext) do
    kind = dump_kind_name(dump.kind)
    suffix = if length(dump.file_keys) > 1, do: " #{index + 1}", else: ""

    "#{client.name} #{dump.period} #{kind}#{suffix}#{ext}"
    |> String.replace(~s("), "")
  end

  defp dump_kind_name("sales"), do: "sales bills"
  defp dump_kind_name("purchase"), do: "purchase bills"
  defp dump_kind_name("gstr2b"), do: "GSTR-2B"

  defp original_content_type(".pdf"), do: "application/pdf"
  defp original_content_type(".json"), do: "application/json"

  defp original_content_type(".xlsx"),
    do: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

  defp original_content_type(_ext), do: "application/octet-stream"

  defp content_type(basename) do
    case Path.extname(basename) do
      ".png" -> "image/png"
      ext when ext in [".jpg", ".jpeg"] -> "image/jpeg"
      ".webp" -> "image/webp"
      _ -> "application/octet-stream"
    end
  end
end
