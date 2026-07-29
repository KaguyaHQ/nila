defmodule Nila.Integrations.Gmail do
  @behaviour Nila.Integrations.GmailAdapter

  @moduledoc """
  Gmail adapter for attachment sync and outbound messages.
  """

  alias Nila.Integrations

  @accounts_url "https://accounts.google.com/o/oauth2/v2/auth"
  @token_url "https://oauth2.googleapis.com/token"
  @api_url "https://gmail.googleapis.com/gmail/v1"
  @scope "https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/gmail.send"

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
  def sync(connection) do
    access_token = Map.fetch!(connection.credentials, "access_token")
    query = gmail_query(connection)

    with {:ok, message_ids} <- list_message_ids(access_token, query),
         {:ok, attachments} <- fetch_messages(access_token, message_ids) do
      normalize(%{"attachments" => attachments}, source: :gmail)
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

  def fetch_thread_replies(connection, thread_refs) when is_list(thread_refs) do
    access_token = Map.fetch!(connection.credentials, "access_token")

    thread_refs
    |> Task.async_stream(&fetch_thread(access_token, &1), timeout: :infinity)
    |> Enum.reduce_while([], fn
      {:ok, {:ok, replies}}, acc -> {:cont, replies ++ acc}
      {:ok, {:error, reason}}, _acc -> {:halt, {:error, reason}}
      {:exit, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      replies -> {:ok, Enum.reverse(replies)}
    end
  end

  def normalize(%{"attachments" => attachments}, _opts) when is_list(attachments) do
    normalized =
      Enum.map(attachments, fn attachment ->
        %{
          filename: Map.fetch!(attachment, "filename"),
          bytes: Map.fetch!(attachment, "bytes"),
          content_type: Map.get(attachment, "content_type", "application/octet-stream"),
          sender: Map.get(attachment, "sender"),
          source_ref: Map.get(attachment, "source_ref")
        }
      end)

    {:ok, normalized}
  end

  def normalize(_raw, _opts), do: {:error, :invalid_payload}

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

  defp maybe_put_thread(body, nil), do: body
  defp maybe_put_thread(body, ""), do: body
  defp maybe_put_thread(body, thread_id), do: Map.put(body, "threadId", thread_id)

  defp fetch_thread(access_token, thread_ref) do
    url = "#{@api_url}/users/me/threads/#{thread_ref}"

    case Req.get(url, auth: {:bearer, access_token}, params: [format: "full"]) do
      {:ok, %{status: status, body: %{"messages" => messages}}} when status in 200..299 ->
        {:ok, Enum.map(messages, &normalize_reply(thread_ref, &1))}

      {:ok, %{status: status, body: body}} ->
        {:error, {:gmail_thread_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_reply(thread_ref, message) do
    parts = collect_parts(message["payload"])

    %{
      thread_ref: thread_ref,
      message_id: message["id"],
      from: header(message, "From"),
      text: text_from_parts(parts),
      attachments: parts |> Enum.filter(&attachment_part?/1) |> Enum.map(& &1["filename"])
    }
  end

  defp header(message, name) do
    message
    |> get_in(["payload", "headers"])
    |> List.wrap()
    |> Enum.find_value(fn
      %{"name" => ^name, "value" => value} ->
        value

      %{"name" => header_name, "value" => value} ->
        if String.downcase(header_name) == String.downcase(name), do: value

      _header ->
        nil
    end)
  end

  defp text_from_parts(parts) do
    parts
    |> Enum.find_value(fn
      %{"mimeType" => "text/plain", "body" => %{"data" => data}} -> decode_body(data)
      _part -> nil
    end)
    |> case do
      nil -> ""
      text -> text
    end
  end

  defp decode_body(data) do
    case Base.url_decode64(data, padding: false) do
      {:ok, text} -> text
      :error -> ""
    end
  end

  defp put_expiry(%{"expires_in" => expires_in} = body) do
    expires_at =
      DateTime.utc_now()
      |> DateTime.add(expires_in, :second)
      |> DateTime.to_iso8601()

    Map.put(body, "expires_at", expires_at)
  end

  defp put_expiry(body), do: body

  defp list_message_ids(access_token, query) do
    url = "#{@api_url}/users/me/messages"

    case Req.get(url, auth: {:bearer, access_token}, params: [q: query]) do
      {:ok, %{status: status, body: %{"messages" => messages}}} when status in 200..299 ->
        {:ok, Enum.map(messages, & &1["id"])}

      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, Map.get(body, "messages", [])}

      {:ok, %{status: status, body: body}} ->
        {:error, {:gmail_list_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_messages(access_token, message_ids) do
    attachments =
      message_ids
      |> Task.async_stream(&fetch_message_attachments(access_token, &1), timeout: :infinity)
      |> Enum.reduce_while([], fn
        {:ok, {:ok, items}}, acc -> {:cont, items ++ acc}
        {:ok, {:error, reason}}, _acc -> {:halt, {:error, reason}}
        {:exit, reason}, _acc -> {:halt, {:error, reason}}
      end)

    case attachments do
      {:error, reason} -> {:error, reason}
      items -> {:ok, Enum.reverse(items)}
    end
  end

  defp fetch_message_attachments(access_token, message_id) do
    url = "#{@api_url}/users/me/messages/#{message_id}"

    with {:ok, %{status: status, body: body}} when status in 200..299 <-
           Req.get(url, auth: {:bearer, access_token}, params: [format: "full"]) do
      parts = collect_parts(body["payload"])

      sender = body |> header("From") |> sender_email()

      parts
      |> Enum.filter(&attachment_part?/1)
      |> Task.async_stream(&fetch_attachment(access_token, message_id, &1, sender),
        timeout: :infinity
      )
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, {:ok, item}}, {:ok, acc} -> {:cont, {:ok, [item | acc]}}
        {:ok, {:error, reason}}, _acc -> {:halt, {:error, reason}}
        {:exit, reason}, _acc -> {:halt, {:error, reason}}
      end)
      |> case do
        {:ok, items} -> {:ok, Enum.reverse(items)}
        error -> error
      end
    else
      {:ok, %{status: status, body: body}} -> {:error, {:gmail_message_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_attachment(access_token, message_id, part, sender) do
    attachment_id = get_in(part, ["body", "attachmentId"])
    url = "#{@api_url}/users/me/messages/#{message_id}/attachments/#{attachment_id}"

    with {:ok, %{status: status, body: %{"data" => data}}} when status in 200..299 <-
           Req.get(url, auth: {:bearer, access_token}),
         {:ok, bytes} <- Base.url_decode64(data, padding: false) do
      {:ok,
       %{
         "filename" => part["filename"],
         "bytes" => bytes,
         "content_type" => part["mimeType"],
         "sender" => sender,
         "source_ref" => "gmail:#{message_id}:#{attachment_id}"
       }}
    else
      {:ok, %{status: status, body: body}} -> {:error, {:gmail_attachment_error, status, body}}
      :error -> {:error, :invalid_attachment_data}
      {:error, reason} -> {:error, reason}
    end
  end

  defp collect_parts(nil), do: []

  defp collect_parts(%{"parts" => parts} = part),
    do: [part | Enum.flat_map(parts, &collect_parts/1)]

  defp collect_parts(part), do: [part]

  defp attachment_part?(%{"filename" => filename, "body" => %{"attachmentId" => attachment_id}}) do
    filename not in [nil, ""] and attachment_id not in [nil, ""]
  end

  defp attachment_part?(_part), do: false

  defp sender_email(nil), do: nil

  defp sender_email(value) do
    case Regex.run(~r/<([^>]+)>/, value) do
      [_, email] -> String.downcase(String.trim(email))
      _ -> value |> String.trim() |> String.downcase()
    end
  end

  defp gmail_query(connection) do
    base_query = get_in(connection.settings || %{}, ["query"]) || "has:attachment"

    case connection.last_synced_at do
      nil -> base_query
      synced_at -> "#{base_query} after:#{Date.to_iso8601(DateTime.to_date(synced_at))}"
    end
  end

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
