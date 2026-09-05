defmodule Nila.EvalCorpus do
  @moduledoc """
  Local mirror of the private `nila-eval-corpus` R2 bucket.

  Real client packets (scanned purchase/sales PDFs) used by OCR probes and the
  extraction benchmark live in R2, not in git. `eval/corpus.json` is the
  committed registry: object key, sha256, page count, and the in-repo ground
  truth each packet is evaluated against. This module pulls objects into a
  local cache (`~/.cache/nila/eval-corpus`) and verifies checksums, so any
  probe run is against exactly the bytes the manifest names.

  Credentials come from `R2_EVAL_ACCESS_KEY_ID` / `R2_EVAL_SECRET_ACCESS_KEY`
  (scoped to the eval bucket only — the prod token cannot touch it, nor vice
  versa) plus the shared `R2_ENDPOINT`. See `mix nila.eval_corpus`.
  """

  @manifest_path "eval/corpus.json"
  @cache_root "~/.cache/nila/eval-corpus"

  def manifest do
    @manifest_path |> File.read!() |> Jason.decode!()
  end

  def documents, do: manifest()["documents"]

  def clients, do: manifest()["clients"] || %{}

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
        cache =
          if File.exists?(local_path(doc)),
            do: "cached",
            else: "MISSING (mix nila.eval_corpus pull)"

        eval =
          case doc["ground_truth"] do
            nil ->
              "not evaluable — needs #{needed_truth(doc["kind"])}"

            path ->
              if File.exists?(path), do: "evaluable", else: "GROUND TRUTH FILE MISSING: #{path}"
          end

        IO.puts(
          "  #{doc["period"] || "-"}  #{String.pad_trailing(doc["kind"] || "?", 8)} #{String.pad_leading(to_string(doc["pages"]), 3)}p  #{cache}  #{eval}"
        )

        if doc["label"], do: IO.puts("    #{doc["label"]} (#{doc["name"]})")
      end)
    end)

    evaluable = Enum.count(docs, & &1["ground_truth"])
    IO.puts("\n#{length(docs)} documents, #{evaluable} evaluable (have ground truth)")

    if evaluable < length(docs) do
      IO.puts("""

      truth downloads (GST portal → Returns Dashboard → month):
        sales    → GSTR-1  → Download JSON  (returns_*_R1_*.json)
        purchase → GSTR-2B → Download JSON  (returns_R2B_*.json)
      then: mix nila.eval_corpus attach <name> <downloaded.json>
      """)
    end
  end

  defp needed_truth("sales"), do: "GSTR-1 JSON"
  defp needed_truth("purchase"), do: "GSTR-2B JSON"
  defp needed_truth(_), do: "ground truth"

  @doc """
  Onboard a month in one step: infer client/period/kind from the portal truth
  JSON, upload the PDF, place the truth file under test/fixtures/, and update
  eval/corpus.json. Review the git diff and commit.
  """
  def add!(pdf_path, truth_path) do
    {kind, gstin, period} = parse_truth!(truth_path)

    client =
      clients()[gstin] ||
        raise ArgumentError,
              "unknown GSTIN #{gstin} — add it to the \"clients\" map in #{@manifest_path}"

    do_add!(pdf_path, client, period, kind, truth_path)
  end

  @doc "Onboard a packet before its return is available: client/period/kind given explicitly."
  def add!(pdf_path, client, period, kind) when kind in ["sales", "purchase"] do
    Map.values(clients()) |> Enum.member?(client) ||
      raise ArgumentError,
            "unknown client #{inspect(client)} — see the \"clients\" map in #{@manifest_path}"

    Regex.match?(~r/^\d{4}-\d{2}$/, period) ||
      raise ArgumentError, "period must be YYYY-MM, got #{inspect(period)}"

    do_add!(pdf_path, client, period, kind, nil)
  end

  defp do_add!(pdf_path, client, period, kind, truth_path) do
    key = "#{client}/#{period}/#{kind}.pdf"
    name = "#{client}-#{period}-#{kind}"
    bytes = File.read!(pdf_path)
    sha = sha256(bytes)

    case Enum.find(documents(), &(&1["sha256"] == sha or &1["name"] == name)) do
      %{"sha256" => ^sha} = doc ->
        IO.puts("PDF already in corpus as #{doc["name"]} — attaching truth only")
        attach!(doc["name"], truth_path)

      %{"name" => ^name} ->
        raise ArgumentError,
              "#{name} exists with different bytes — delete the old entry first if replacing"

      nil ->
        request!(ExAws.S3.put_object(bucket(), key, bytes, content_type: "application/pdf"))

        truth_dest = truth_path && place_truth!(kind, client, period, truth_path)

        entry = %{
          "name" => name,
          "key" => key,
          "sha256" => sha,
          "byte_size" => byte_size(bytes),
          "pages" => page_count(pdf_path),
          "client" => client,
          "period" => period,
          "kind" => kind,
          "ground_truth" => truth_dest
        }

        write_manifest!(update_in(manifest(), ["documents"], &(&1 ++ [entry])))

        cache = local_path(entry)
        File.mkdir_p!(Path.dirname(cache))
        File.write!(cache, bytes)

        IO.puts("""
        uploaded  #{key} (#{entry["pages"]}p, #{byte_size(bytes)} bytes)
        truth     #{truth_dest || "none yet — attach when the return is downloaded"}
        manifest  #{@manifest_path} updated
        → review the git diff and commit
        """)
    end
  end

  @doc "Open a corpus document in the OS viewer (pulls if missing)."
  def open!(name) do
    path = fetch!(name)
    IO.puts(path)
    {_, 0} = System.cmd("open", [path])
    :ok
  end

  @doc "Attach a portal truth JSON to an existing corpus document."
  def attach!(name, truth_path) do
    doc = document!(name)
    {kind, gstin, period} = parse_truth!(truth_path)

    clients()[gstin] == doc["client"] ||
      raise ArgumentError, "truth GSTIN #{gstin} does not belong to client #{doc["client"]}"

    kind == doc["kind"] ||
      raise ArgumentError, "truth is #{kind}-side but #{name} is a #{doc["kind"]} document"

    period == doc["period"] ||
      raise ArgumentError, "truth period #{period} does not match #{name}"

    truth_dest = place_truth!(kind, doc["client"], period, truth_path)

    write_manifest!(
      update_in(manifest(), ["documents"], fn docs ->
        Enum.map(docs, fn
          %{"name" => ^name} = d -> Map.put(d, "ground_truth", truth_dest)
          d -> d
        end)
      end)
    )

    IO.puts("""
    truth     #{truth_dest}
    manifest  #{name} → evaluable
    → review the git diff and commit both files
    """)
  end

  # R1 JSON has top-level "fp" (MMYYYY); 2B JSON has data.rtnprd (MMYYYY).
  defp parse_truth!(path) do
    json = path |> File.read!() |> Jason.decode!()

    cond do
      is_binary(json["fp"]) and is_binary(json["gstin"]) ->
        {"sales", json["gstin"], mmyyyy_to_period(json["fp"])}

      is_binary(get_in(json, ["data", "rtnprd"])) ->
        {"purchase", get_in(json, ["data", "gstin"]),
         mmyyyy_to_period(get_in(json, ["data", "rtnprd"]))}

      true ->
        raise ArgumentError,
              "#{path} is neither a filed GSTR-1 JSON (top-level fp/gstin) nor a GSTR-2B JSON (data.rtnprd)"
    end
  end

  defp mmyyyy_to_period(<<mm::binary-size(2), yyyy::binary-size(4)>>), do: "#{yyyy}-#{mm}"

  defp place_truth!(kind, client, period, truth_path) do
    dir = if kind == "sales", do: "gstr1", else: "purchase"
    dest = Path.join(["test/fixtures", dir, client, period, Path.basename(truth_path)])
    File.mkdir_p!(Path.dirname(dest))
    File.cp!(truth_path, dest)
    dest
  end

  defp write_manifest!(manifest) do
    docs = Enum.sort_by(manifest["documents"], &{&1["client"], &1["period"], &1["kind"]})

    File.write!(
      @manifest_path,
      Jason.encode!(%{manifest | "documents" => docs}, pretty: true) <> "\n"
    )
  end

  @doc "Manifest entry for a corpus document, by name."
  def document!(name) do
    Enum.find(documents(), &(&1["name"] == name)) ||
      raise ArgumentError,
            "unknown corpus document #{inspect(name)} — see eval/corpus.json (mix nila.eval_corpus status)"
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
      http_client: Nila.Storage.ExAwsClient
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
