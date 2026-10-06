defmodule Nila.Eval.Requests do
  @moduledoc "Saves one evaluation HTTP attempt; does not change the request or retry it."

  alias Nila.Gst.Extraction.Providers.{OpenAICompatibleChat, OpenAICompatibleChatFinch}

  def start_http! do
    Mix.Task.run("app.config")
    for app <- [:req, :jsv], do: Application.ensure_all_started(app)
    {:ok, _} = Supervisor.start_link([OpenAICompatibleChatFinch], strategy: :one_for_one)
    # Preserve the existing runners' unmeasured warmup: Finch connects H2 asynchronously.
    Process.sleep(2000)
  end

  @doc "Sends a prepared request once using the configured gateway. Never saves credentials."
  def post(payload) do
    config = Application.get_env(:nila, OpenAICompatibleChat, [])

    Req.post(
      [
        url: OpenAICompatibleChat.base_url() <> "/chat/completions",
        auth: {:bearer, Keyword.fetch!(config, :api_key)},
        json: payload,
        decode_body: false,
        retry: false,
        receive_timeout: 240_000
      ] ++ OpenAICompatibleChatFinch.req_options()
    )
  end

  @doc """
  Records a Req.post or Req adapter callback without changing its return value.
  Returns {callback_result, measurements, decoded_invoice_or_error}. The caller
  owns experiment metadata and the final result file. Call artifacts live under
  attempts/<prefix>/; use attempt_dir/2 for additional per-call files.
  Existing attempts are refused before calling the provider.
  """
  def capture(dir, prefix, payload, schema, call) when is_function(call, 0) do
    artifact_dir = attempt_dir(dir, prefix)
    File.mkdir_p!(dir)

    if Enum.any?(File.ls!(dir), &String.starts_with?(&1, prefix <> "-")),
      do: raise("Refusing to overwrite existing attempt: #{prefix}")

    File.mkdir_p!(Path.dirname(artifact_dir))

    # Reserve the whole attempt atomically, including interrupted or failed calls.
    case File.mkdir(artifact_dir) do
      :ok ->
        :ok

      {:error, :eexist} ->
        raise("Refusing to overwrite existing attempt: #{prefix}")

      {:error, reason} ->
        raise File.Error, reason: reason, action: "create directory", path: artifact_dir
    end

    request_path = Path.join(artifact_dir, prefix <> "-request.json")
    File.write!(request_path, Jason.encode!(payload, pretty: true), [:exclusive])
    write(artifact_dir, prefix <> "-schema.json", schema)
    started_at = DateTime.utc_now() |> DateTime.to_iso8601()
    started = System.monotonic_time(:millisecond)
    {_request_or_status, response} = result = call.()

    timing = %{
      requested_model: payload["model"],
      started_at: started_at,
      finished_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      duration_ms: System.monotonic_time(:millisecond) - started
    }

    {measurements, decoded} = record(artifact_dir, prefix, response, schema)
    {result, Map.merge(timing, measurements), decoded}
  end

  @doc "Directory for a call's raw artifacts, decoded output and measurements."
  def attempt_dir(dir, prefix) do
    if not is_binary(prefix) or not Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/, prefix),
      do:
        raise(
          ArgumentError,
          "Expected a filename prefix using letters, numbers, dots, dashes or underscores"
        )

    Path.join([dir, "attempts", prefix])
  end

  def write(dir, name, data),
    do: File.write!(Path.join(dir, name), Jason.encode!(data, pretty: true))

  defp record(dir, prefix, %Req.Response{} = response, schema) do
    body = if is_binary(response.body), do: response.body, else: Jason.encode!(response.body)
    File.write!(Path.join(dir, prefix <> "-response.json"), body)
    write(dir, prefix <> "-headers.json", Map.drop(response.headers, ["set-cookie"]))

    envelope =
      case Jason.decode(body) do
        {:ok, value} when is_map(value) -> value
        _ -> %{}
      end

    decoded =
      OpenAICompatibleChat.decode(
        %{status: response.status, body: body, response_format: :json_schema_local},
        schema
      )

    choices =
      case envelope["choices"] do
        values when is_list(values) -> Enum.filter(values, &is_map/1)
        _ -> []
      end

    first = List.first(choices) || %{}

    measurements = %{
      http_status: response.status,
      local_schema_valid: match?({:ok, _, _}, decoded),
      finish_reason: first["finish_reason"],
      usage: envelope["usage"] || %{},
      returned_model: envelope["model"],
      response_provider: envelope["provider"],
      reasoning_content_present:
        Enum.any?(choices, fn choice ->
          message = if is_map(choice["message"]), do: choice["message"], else: %{}

          Enum.any?(
            [message["reasoning"], message["reasoning_content"]],
            &(&1 not in [nil, "", []])
          )
        end)
    }

    {measurements, decoded}
  end

  defp record(_dir, _prefix, error, _schema),
    do: {%{outcome: "transport_error", error: Exception.message(error)}, {:error, error}}
end
