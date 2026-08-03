defmodule Nila.Integrations.Gmail do
  @behaviour Nila.Integrations.GmailAdapter
  @behaviour Nila.Integrations.MailAdapter

  @moduledoc """
  Gmail adapter for outbound mail from a firm's own mailbox.

  Send-only on purpose. Replies come back by address — the chase sets a
  per-client Reply-To that Nila receives — so nothing here reads a mailbox.
  That keeps the app out of `gmail.readonly`, a restricted scope whose annual
  third-party assessment would buy only what the routing already gives us.
  """

  alias Nila.Integrations

  @accounts_url "https://accounts.google.com/o/oauth2/v2/auth"
  @token_url "https://oauth2.googleapis.com/token"
  @api_url "https://gmail.googleapis.com/gmail/v1"
  @scope "https://www.googleapis.com/auth/gmail.send"

  @impl true
  def authorize_url(opts) do
    params = [
      client_id: config!(:client_id),
      redirect_uri: config!(:redirect_uri),
      response_type: "code",
      scope: @scope,
      access_type: "offline",
      prompt: "consent",
      state: Keyword.fetch!(opts, :state)
    ]

    @accounts_url <> "?" <> URI.encode_query(params)
  end

  @impl true
  def exchange_code(code) do
    request_token(%{
      "client_id" => config!(:client_id),
      "client_secret" => config!(:client_secret),
      "code" => code,
      "grant_type" => "authorization_code",
      "redirect_uri" => config!(:redirect_uri)
    })
  end

  @impl true
  def profile_email(access_token) do
    case Req.get("#{@api_url}/users/me/profile", auth: {:bearer, access_token}) do
      {:ok, %{status: status, body: %{"emailAddress" => email}}} when status in 200..299 ->
        {:ok, email}

      {:ok, %{status: status, body: body}} ->
        {:error, {:gmail_profile_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def refresh_token(refresh_token) do
    request_token(%{
      "client_id" => config!(:client_id),
      "client_secret" => config!(:client_secret),
      "grant_type" => "refresh_token",
      "refresh_token" => refresh_token
    })
  end

  @impl true
  def ensure_token(connection) do
    credentials = connection.credentials

    if Integrations.token_fresh?(credentials) do
      {:ok, connection}
    else
      with {:ok, refreshed} <- refresh_token(Map.fetch!(credentials, "refresh_token")) do
        Integrations.update_credentials(connection, Map.merge(credentials, refreshed))
      end
    end
  end

  @impl true
  def send_message(connection, recipient, message) when is_binary(recipient),
    do: send_message(connection, Map.put(message, :to, recipient))

  def send_message(connection, message) do
    access_token = Map.fetch!(connection.credentials, "access_token")
    url = "#{@api_url}/users/me/messages/send"
    raw = encode_message(message)
    body = maybe_put_thread(%{"raw" => raw}, Map.get(message, :thread_id))
    options = [auth: {:bearer, access_token}, json: body] ++ req_options()

    case Req.post(url, options) do
      {:ok, %{status: status, body: %{"id" => message_id, "threadId" => thread_id}}}
      when status in 200..299 ->
        {:ok, %{message_id: message_id, thread_id: thread_id}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:gmail_send_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_token(form) do
    case Req.post(@token_url, [form: form] ++ req_options()) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, put_expiry(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:google_token_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The adapter is a dumb pipe: it renders whatever headers, body, and
  # attachments it is handed. Workflow-specific conventions (the SDC two-PDF
  # send, the fixed Cc) are decided by the template, never here.
  defp encode_message(message) do
    message
    |> build_mime()
    |> Base.url_encode64(padding: false)
  end

  defp build_mime(message) do
    text = Map.get(message, :body) || ""
    html = blank_to_nil(Map.get(message, :html))
    attachments = Map.get(message, :attachments) || []
    headers = address_headers(message)

    body =
      cond do
        attachments != [] -> mixed(text, html, attachments)
        html -> alternative(text, html)
        true -> singlepart("text/plain; charset=UTF-8", text)
      end

    join_headers(headers ++ body.headers) <> "\r\n\r\n" <> body.body
  end

  defp address_headers(message) do
    [
      {"To", Map.fetch!(message, :to)},
      {"Cc", blank_to_nil(Map.get(message, :cc))},
      {"From", blank_to_nil(Map.get(message, :from))},
      {"Reply-To", address_list(Map.get(message, :reply_to))},
      {"Subject", Map.fetch!(message, :subject)},
      {"MIME-Version", "1.0"}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp singlepart(content_type, content) do
    %{headers: [{"Content-Type", content_type}], body: content}
  end

  defp alternative(text, html) do
    boundary = boundary()

    body =
      part([{"Content-Type", "text/plain; charset=UTF-8"}], text, boundary) <>
        part([{"Content-Type", "text/html; charset=UTF-8"}], html, boundary) <>
        "--#{boundary}--\r\n"

    %{headers: [{"Content-Type", ~s(multipart/alternative; boundary="#{boundary}")}], body: body}
  end

  defp mixed(text, html, attachments) do
    boundary = boundary()

    inner =
      if html, do: alternative(text, html), else: singlepart("text/plain; charset=UTF-8", text)

    attachment_parts =
      Enum.map_join(attachments, "", fn attachment -> attachment_part(attachment, boundary) end)

    body =
      part(inner.headers, inner.body, boundary) <> attachment_parts <> "--#{boundary}--\r\n"

    %{headers: [{"Content-Type", ~s(multipart/mixed; boundary="#{boundary}")}], body: body}
  end

  defp attachment_part(attachment, boundary) do
    filename = Map.get(attachment, :filename) || Map.get(attachment, "filename")
    bytes = Map.get(attachment, :bytes) || Map.get(attachment, "bytes") || ""

    content_type =
      Map.get(attachment, :content_type) || Map.get(attachment, "content_type") ||
        "application/octet-stream"

    headers = [
      {"Content-Type", ~s(#{content_type}; name="#{filename}")},
      {"Content-Transfer-Encoding", "base64"},
      {"Content-Disposition", ~s(attachment; filename="#{filename}")}
    ]

    part(headers, chunk64(bytes), boundary)
  end

  defp part(headers, content, boundary) do
    "--#{boundary}\r\n" <> join_headers(headers) <> "\r\n\r\n" <> content <> "\r\n"
  end

  defp join_headers(headers) do
    Enum.map_join(headers, "\r\n", fn {key, value} -> "#{key}: #{value}" end)
  end

  defp chunk64(bytes) do
    bytes
    |> Base.encode64()
    |> String.replace(~r/.{1,76}/, "\\0\r\n")
    |> String.trim_trailing("\r\n")
  end

  defp boundary, do: "nila_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  # A header may carry several addresses; RFC 5322 comma-separates them.
  defp address_list(value) do
    value
    |> List.wrap()
    |> Enum.map(&blank_to_nil/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      addresses -> Enum.join(addresses, ", ")
    end
  end

  defp maybe_put_thread(body, nil), do: body
  defp maybe_put_thread(body, ""), do: body
  defp maybe_put_thread(body, thread_id), do: Map.put(body, "threadId", thread_id)

  defp put_expiry(%{"expires_in" => expires_in} = body) do
    expires_at =
      DateTime.utc_now()
      |> DateTime.add(expires_in, :second)
      |> DateTime.to_iso8601()

    Map.put(body, "expires_at", expires_at)
  end

  defp put_expiry(body), do: body

  defp req_options,
    do: Application.get_env(:nila, __MODULE__, []) |> Keyword.get(:req_options, [])

  defp config!(key) do
    value = Application.get_env(:nila, __MODULE__, []) |> Keyword.get(key)

    if value in [nil, ""] do
      raise "missing Gmail config #{inspect(key)}"
    end

    value
  end
end
