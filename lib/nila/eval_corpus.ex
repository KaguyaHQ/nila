defmodule Nila.EvalCorpus do
  @moduledoc """
  Local mirror of the private `nila-eval-corpus` R2 bucket.

  Real client packets (scanned purchase/sales PDFs) used by OCR probes and the
  extraction benchmark live in R2, not in git. `bench/corpus.json` is the
  committed registry: object key, sha256, page count, and the in-repo ground
  truth each packet is evaluated against. This module pulls objects into a
  local cache (`~/.cache/nila/eval-corpus`) and verifies checksums, so any
  probe run is against exactly the bytes the manifest names.

  Credentials come from `R2_EVAL_ACCESS_KEY_ID` / `R2_EVAL_SECRET_ACCESS_KEY`
  (scoped to the eval bucket only — the prod token cannot touch it, nor vice
  versa) plus the shared `R2_ENDPOINT`. See `mix nila.eval_corpus`.
  """

  @manifest_path "bench/corpus.json"
  @cache_root "~/.cache/nila/eval-corpus"

  def manifest do
    @manifest_path |> File.read!() |> Jason.decode!()
  end

  def documents, do: manifest()["documents"]

  @doc "Local path for a corpus document, pulling and sha-verifying if absent."
  def fetch!(name) do
    doc = document!(name)
    path = local_path(doc)

    if File.exists?(path) do
      verify!(doc, File.read!(path))
    else
      pull_document!(doc)
    end

    path
  end

  def pull do
    Enum.each(documents(), fn doc ->
      path = local_path(doc)

      if File.exists?(path) do
        verify!(doc, File.read!(path))
        IO.puts("ok       #{doc["name"]}")
      else
        pull_document!(doc)
        IO.puts("pulled   #{doc["name"]}")
      end
    end)
  end

  def status do
    docs = documents()

    docs
    |> Enum.group_by(&(&1["client"] || "misc"))
    |> Enum.sort()
    |> Enum.each(fn {client, client_docs} ->
      IO.puts("#{client}:")

      client_docs
      |> Enum.sort_by(&{&1["period"] || "", &1["kind"]})
      |> Enum.each(fn doc ->
        cache = if File.exists?(local_path(doc)), do: "cached", else: "MISSING (mix nila.eval_corpus pull)"

        eval =
          case doc["ground_truth"] do
            nil -> "no ground truth — not evaluable"
            path -> if File.exists?(path), do: "evaluable", else: "GROUND TRUTH FILE MISSING: #{path}"
          end

        IO.puts("  #{doc["period"] || "-"}  #{String.pad_trailing(doc["kind"] || "?", 8)} #{String.pad_leading(to_string(doc["pages"]), 3)}p  #{cache}  #{eval}")
      end)
    end)

    evaluable = Enum.count(docs, & &1["ground_truth"])
    IO.puts("\n#{length(docs)} documents, #{evaluable} evaluable (have ground truth)")
  end

  @doc """
  Upload a new packet and print the manifest entry to commit. Usage from
  `mix nila.eval_corpus push <key> <local-file> [ground-truth-path]`.
  """
  def push!(key, file, ground_truth \\ nil) do
    bytes = File.read!(file)
    sha = sha256(bytes)
    pages = page_count(file)

    request!(ExAws.S3.put_object(bucket(), key, bytes, content_type: "application/pdf"))

    [client, period, kindfile] =
      case String.split(key, "/") do
        [c, p, k] -> [c, p, k]
        _ -> [nil, nil, key]
      end

    entry = %{
      "name" => key |> String.replace_suffix(".pdf", "") |> String.replace("/", "-"),
      "key" => key,
      "sha256" => sha,
      "byte_size" => byte_size(bytes),
      "pages" => pages,
      "client" => client,
      "period" => period,
      "kind" =>
        kindfile && kindfile |> String.replace_suffix(".pdf", "") |> String.split("-") |> hd(),
      "ground_truth" => ground_truth
    }

    IO.puts("uploaded #{key} (#{byte_size(bytes)} bytes, #{pages || "?"} pages)")
    IO.puts("add to bench/corpus.json documents:\n")
    IO.puts(Jason.encode!(entry, pretty: true))
    entry
  end

  defp document!(name) do
    Enum.find(documents(), &(&1["name"] == name)) ||
      raise ArgumentError,
            "unknown corpus document #{inspect(name)} — see bench/corpus.json (mix nila.eval_corpus status)"
  end

  defp local_path(doc), do: Path.join(Path.expand(@cache_root), doc["key"])

  defp pull_document!(doc) do
    body = request!(ExAws.S3.get_object(bucket(), doc["key"])).body
    verify!(doc, body)
    path = local_path(doc)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
  end

  defp verify!(doc, bytes) do
    actual = sha256(bytes)

    unless actual == doc["sha256"] do
      raise "corpus checksum mismatch for #{doc["name"]}: expected #{doc["sha256"]}, got #{actual}. " <>
              "If the local cache is stale, delete #{local_path(doc)} and re-pull."
    end

    :ok
  end

  defp request!(operation) do
    case ExAws.request(operation, config()) do
      {:ok, %{status_code: 200} = response} ->
        response

      {:error, reason} ->
        raise "eval corpus R2 request failed: #{inspect(reason, limit: 6)}"
    end
  end

  defp bucket, do: manifest()["bucket"]

  defp config do
    cfg = Application.get_env(:nila, __MODULE__, [])

    [
      access_key_id: setting!(cfg, :access_key_id, "R2_EVAL_ACCESS_KEY_ID"),
      secret_access_key: setting!(cfg, :secret_access_key, "R2_EVAL_SECRET_ACCESS_KEY"),
      region: "auto",
      scheme: "https://",
      host: URI.parse(setting!(cfg, :endpoint, "R2_ENDPOINT")).host,
      port: 443,
      http_client: ExAws.Request.Req
    ]
  end

  defp setting!(cfg, key, env_name) do
    cfg[key] || System.get_env(env_name) ||
      raise "#{env_name} is not set — the eval corpus needs the eval-scoped R2 token in .env"
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp page_count(file) do
    case System.cmd("pdfinfo", [file], stderr_to_stdout: true) do
      {out, 0} ->
        case Regex.run(~r/^Pages:\s+(\d+)/m, out) do
          [_, n] -> String.to_integer(n)
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
