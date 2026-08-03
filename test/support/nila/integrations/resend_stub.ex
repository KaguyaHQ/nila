defmodule Nila.Integrations.ResendStub do
  @moduledoc false

  def list_attachments(email_id) do
    case Process.get({:resend_attachments, email_id}, Process.get(:resend_attachments)) do
      {:error, reason} -> {:error, reason}
      nil -> {:ok, []}
      attachments -> {:ok, attachments}
    end
  end

  def download(download_url) do
    case Process.get({:resend_download, download_url}, Process.get(:resend_download)) do
      {:error, reason} -> {:error, reason}
      nil -> {:error, {:resend_download_error, 404}}
      bytes -> {:ok, bytes}
    end
  end
end
