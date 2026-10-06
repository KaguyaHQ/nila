Code.require_file("eval/tax_contract/candidates.exs")

alias Nila.Gst.Extraction.{InvoiceRequest, InvoiceSchema}
alias Nila.Gst.Extraction.Providers.OpenAICompatibleChat
alias Nila.Eval.Requests
Logger.configure(level: :warning)
[root] = System.argv()

if File.exists?(root <> "/attempts"),
  do: raise("Use a fresh run directory; completed/interrupted runs are immutable")

settings = File.read!(root <> "/inputs/settings.json") |> Jason.decode!()
arms = settings["arms"]
repeats = settings["repeats"]

unless is_list(arms) and arms != [] and length(Enum.uniq(arms)) == length(arms),
  do: raise("settings.arms must be a nonempty list of distinct candidates")

unless is_integer(repeats) and repeats > 0,
  do: raise("settings.repeats must be a positive integer")

sources = File.read!(root <> "/inputs/sources.json") |> Jason.decode!()
config = Application.get_env(:nila, OpenAICompatibleChat, [])

Requests.write(root <> "/inputs", "runtime.json", %{
  model: OpenAICompatibleChat.model(),
  temperature: 0,
  provider_options: config[:provider_options],
  git_head: elem(System.cmd("git", ["rev-parse", "HEAD"]), 0) |> String.trim()
})

requests =
  Map.new(sources, fn s ->
    modality = if s["modality"] == "text", do: :text, else: :vision

    pages =
      Enum.map(s["pages"], fn p ->
        bytes = File.read!(p["input_path"])
        true = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == p["input_sha256"]

        {p["page"],
         if(modality == :text, do: bytes, else: %{bytes: bytes, content_type: "image/jpeg"})}
      end)

    original = InvoiceRequest.build(:sales, pages, modality, :semantic)

    variants =
      Map.new(arms, fn arm ->
        request =
          case get_in(settings, ["references", arm]) do
            nil ->
              Nila.Eval.TaxCandidates.build(original, arm)

            reference ->
              path = reference["run"] <> "/inputs/prepared/" <> s["id"] <> "/" <> reference["arm"]
              schema = File.read!(path <> "/schema.json") |> Jason.decode!()
              prompt = File.read!(path <> "/prompt.txt")

              messages =
                Enum.map(original.messages, fn
                  %{role: "user", content: [first | rest]} = message ->
                    %{message | content: [%{first | text: prompt} | rest]}

                  message ->
                    message
                end)

              %{original | schema: schema, messages: messages}
          end

        {arm, request}
      end)

    for {arm, request} <- variants do
      JSV.build!(request.schema)
      dir = root <> "/inputs/prepared/" <> s["id"] <> "/" <> arm
      File.mkdir_p!(dir)
      Requests.write(dir, "schema.json", request.schema)
      File.write!(dir <> "/prompt.txt", hd(List.last(request.messages).content).text)
    end

    {s["id"], variants}
  end)

jobs =
  for repeat <- 1..repeats,
      {s, i} <- Enum.with_index(sources),
      arm <-
        Enum.drop(arms, rem(repeat + i, length(arms))) ++
          Enum.take(arms, rem(repeat + i, length(arms))),
      do: {s, repeat, arm}

Requests.write(
  root <> "/inputs",
  "schedule.json",
  Enum.map(jobs, fn {s, r, a} -> %{case_id: s["id"], repeat: r, arm: a} end)
)

Requests.start_http!()

results =
  Task.async_stream(
    jobs,
    fn {s, repeat, arm} ->
      request = requests[s["id"]][arm]
      prefix = "#{s["id"]}-#{arm}-#{repeat}"

      payload = %{
        "model" => OpenAICompatibleChat.model(),
        "temperature" => 0,
        "messages" => request.messages,
        "response_format" => %{
          type: "json_schema",
          json_schema: %{name: request.name, strict: true, schema: request.schema}
        },
        "providerOptions" => config[:provider_options]
      }

      {_response, measurements, decoded} =
        Requests.capture(root, prefix, payload, request.schema, fn -> Requests.post(payload) end)

      dir = Requests.attempt_dir(root, prefix)

      result =
        Map.merge(measurements, %{
          case_id: s["id"],
          arm: arm,
          repeat: repeat,
          modality: s["modality"]
        })

      result =
        case decoded do
          {:ok, data, _} ->
            Requests.write(dir, prefix <> "-data.json", data)

            Requests.write(
              dir,
              prefix <> "-decoded.json",
              InvoiceSchema.decode_line_items(data, :semantic)
            )

            Map.put(result, :tax_totals, data["printed_tax_totals"])

          error ->
            Map.put(result, :decode_error, inspect(error))
        end

      Requests.write(dir, prefix <> "-result.json", result)

      IO.puts(
        Jason.encode!(
          Map.take(result, [
            :case_id,
            :arm,
            :repeat,
            :http_status,
            :local_schema_valid,
            :tax_totals
          ])
        )
      )

      result
    end, max_concurrency: settings["concurrency"] || 3, timeout: :infinity, ordered: true)
  |> Enum.map(fn {:ok, result} -> result end)

Requests.write(root, "results.json", results)
