defmodule Nila.Integrations.Resend do
  @moduledoc """
  Resend inbound API client.

  Resend's webhook carries metadata only — no body, no attachment bytes — so
  that a large scan does not have to fit in a request body. The bytes are
  fetched here, from a `download_url` that expires about an hour after the
  webhook fires. That expiry is why ingestion runs as a job started promptly,
  not on a schedule.
  """

  @api_url "https://api.resend.com"

  @doc "Lists an inbound email's attachments, each with a short-lived `download_url`."
  def list_attachments(email_id) when is_binary(email_id) do
    with {:ok, api_key} <- api_key() do
      url = "#{@api_url}/emails/#{email_id}/attachments"

      case Req.get(url, [auth: {:bearer, api_key}] ++ req_options()) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          {:ok, body |> Map.get("data", []) |> Enum.map(&normalize_attachment/1)}

        {:ok, %{status: status, body: body}} ->
          {:error, {:resend_attachments_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Downloads attachment bytes from a `download_url` issued by `list_attachments/1`."
  def download(download_url) when is_binary(download_url) do
    case Req.get(download_url, [decode_body: false] ++ req_options()) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:resend_download_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_attachment(attachment) do
    %{
      id: attachment["id"],
      filename: attachment["filename"],
      content_type: attachment["content_type"] || "application/octet-stream",
      download_url: attachment["download_url"]
    }
  end

  defp api_key do
    case config(:api_key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, :resend_not_configured}
    end
  end

  defp req_options, do: config(:req_options) || []

  defp config(key), do: Application.get_env(:nila, __MODULE__, []) |> Keyword.get(key)
end
