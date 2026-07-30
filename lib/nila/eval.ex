defmodule Nila.Eval do
  @moduledoc """
  The GSTR-1 eval loop: score the engine against filed returns, with provenance.

  This is the engine's measurement organ, not a product surface. The human-facing
  half — derived-vs-filed per invoice, the scanned page one tap away — belongs in
  the workbench; what lives here is what no UI can do: re-score every month in
  seconds after a rule change, and say which extractor, model and prompt produced
  each number.

  `bridge/1` is the faithfulness control. It scores the pre-Mistral page
  artifacts under `tmp/eval/` and reproduces the baselines the retired eval
  script produced, so the lift into `lib/` can be shown to have changed nothing
  before the extractor changes underneath it.
  """

  alias Nila.Eval.Adjudications
  alias Nila.Eval.Extraction
  alias Nila.Eval.Gstr1Diff
  alias Nila.Eval.Report
  alias Nila.EvalCorpus
  alias Nila.Gst.Sales.Gstr1
  alias Nila.Gst.Sales.Workings

  @artifact_root "tmp/eval"
  @fixture_root "test/fixtures/gstr1"
  @run_root "tmp/eval/runs"

  @doc """
  Baselines produced by the retired script before the lift, keyed
  `{client, period}`.

  These measure LlamaExtract, which production no longer uses. They exist only
  to prove `Gstr1Diff` scores identically to the code it replaced; once that is
  shown they are deleted along with the artifacts, not migrated.
  """
  def baselines do
    %{
      {"breeze", "2026-01"} => 92.14,
      {"breeze", "2026-05"} => 87.34,
      {"caltech", "2025-10"} => 55.79,
      {"caltech", "2025-11"} => 69.52,
      {"caltech", "2025-12"} => 53.23,
      {"caltech", "2026-01"} => 57.84
    }
  end

  @doc """
  Re-scores the archived Llama artifacts and compares against `baselines/0`.

  `header: :filed` reproduces exactly what the script did. `header: :production`
  swaps in `Gstr1.production_header/2` — the second argument production actually
  passes — which also swaps `filing_typ`, `gt` and `cur_gt` to their fallbacks.
  That flip is expected to be score-neutral *because* `Gstr1Diff` never compares
  those three fields, so running it is a standing control on the scorer's scope:
  if it ever moves a number, either the diff widened or something broke.

  Returns `{:ok, results}` when every month matched, `{:error, results}`
  otherwise, where each result is
  `%{client, period, expected, actual, matched?, rows}`.
  """
  def bridge(opts \\ []) do
    header = Keyword.get(opts, :header, :filed)

    results =
      baselines()
      |> Enum.sort()
      |> Enum.map(fn {{client, period}, expected} ->
        bridge_month(client, period, expected, header)
      end)

    if Enum.all?(results, & &1.matched?), do: {:ok, results}, else: {:error, results}
  end

  defp bridge_month(client, period, expected, header) do
    with {:ok, invoices} <- archived_invoices(client, period),
         {:ok, filed} <- filed_return(client, period) do
      derived = Gstr1.derive(invoices, header(header, filed, client, period))
      rows = Gstr1Diff.rows(derived, filed)
      %{"score" => actual} = Gstr1Diff.score(rows)

      %{
        client: client,
        period: period,
        expected: expected,
        actual: actual,
        matched?: abs(actual - expected) <= 0.01,
        rows: rows
      }
    else
      {:error, reason} ->
        %{
          client: client,
          period: period,
          expected: expected,
          actual: nil,
          matched?: false,
          error: reason,
          rows: []
        }
    end
  end

  defp header(:filed, filed, _client, _period), do: filed

  defp header(:production, _filed, client, period) do
    Gstr1.production_header(gstin!(client), period)
  end

  # The eval's own registry already maps GSTIN to client; production reads the
  # same value off `clients.gstin`. Inverted here because the corpus is keyed
  # the way the portal names things.
  defp gstin!(client) do
    Enum.find_value(Nila.EvalCorpus.clients(), fn {gstin, name} ->
      if name == client, do: gstin
    end) || raise ArgumentError, "no GSTIN in the corpus clients map for #{inspect(client)}"
  end

  @doc "Normalized invoices from an archived page-artifact directory."
  def archived_invoices(client, period) do
    dir = Path.join([@artifact_root, "#{period}-#{client}", "pages"])

    case dir |> Path.join("*.json") |> Path.wildcard() do
      [] -> {:error, {:no_artifacts, dir}}
      paths -> {:ok, paths |> Enum.sort_by(&page_number/1) |> Enum.map(&normalize_page/1)}
    end
  end

  defp normalize_page(path), do: path |> read_json!() |> Gstr1.normalize_invoice()

  defp page_number(path) do
    case Regex.run(~r/(\d+)/, Path.basename(path)) do
      [_match, number] -> String.to_integer(number)
      nil -> 999_999
    end
  end

  @doc "The filed return a month is scored against."
  def filed_return(client, period) do
    case Path.wildcard(Path.join([@fixture_root, client, period, "returns_*.json"])) do
      [path] -> {:ok, read_json!(path)}
      [] -> {:error, {:no_filed_return, client, period}}
      paths -> {:error, {:ambiguous_filed_return, paths}}
    end
  end

  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()

  @doc """
  A run's identity: sortable, and naming the code that produced it.

  The git sha is what makes a score reproducible — including whether the tree
  was dirty, because a run on uncommitted code cannot be reproduced and should
  say so on its face rather than in someone's memory.
  """
  def run_id do
    stamp = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    "#{String.replace(stamp, [":"], "-")}-#{git_sha()}#{dirty_suffix()}"
  end

  defp git_sha do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _failed -> "nogit"
    end
  end

  defp dirty_suffix do
    case System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true) do
      {"", 0} -> ""
      {_changes, 0} -> "-dirty"
      _failed -> ""
    end
  end

  @doc """
  Scores a corpus document from its newest cached extraction attempt.

  Reads nothing but the cached response bytes: mapping, merging, normalizing,
  deriving and diffing all run now. A rule change is therefore re-scored with no
  API call, and no cache hit can attribute a number to code that no longer runs.
  """
  def score(name, run_id) do
    doc = EvalCorpus.document!(name)

    with {:ok, attempt} <- Extraction.latest_attempt(name),
         {:ok, assembled} <- Extraction.replay(attempt) do
      invoices = Enum.map(assembled.pages, &Gstr1.normalize_invoice/1)
      meta = attempt |> Path.join("meta.json") |> File.read!() |> Jason.decode!()

      provenance = %{
        "run_id" => run_id,
        "extractor" => meta["provider"],
        "model" => meta["model"],
        "prompt_fingerprint" => get_in(meta, ["fingerprint", "prompt"]),
        "attempt" => attempt,
        "unaccounted_pages" => assembled[:unaccounted_pages] || [],
        "scored_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      }

      {:ok, score_month(doc["client"], doc["period"], invoices, provenance)}
    end
  end

  @doc "Corpus documents that can be scored: sales-side, with a filed return."
  def evaluable do
    EvalCorpus.documents()
    |> Enum.filter(&(&1["kind"] == "sales" and &1["ground_truth"]))
    |> Enum.map(& &1["name"])
    |> Enum.sort()
  end

  @doc """
  Scores a month from its archived page artifacts.

  The pre-Mistral path, kept working so the report is usable before the sweep.
  Provenance says so plainly rather than implying a run that did not happen.
  """
  def score_archived(client, period, run_id) do
    case archived_invoices(client, period) do
      {:ok, invoices} ->
        provenance = %{
          "run_id" => run_id,
          "extractor" => "LlamaExtract (archived artifacts)",
          "model" => "unknown — pre-provenance capture",
          "prompt_fingerprint" => nil,
          "attempt" => nil,
          "scored_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        }

        {:ok, score_month(client, period, invoices, provenance)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Scores one month end to end and writes its run artifacts.

  `invoices` are normalized; `provenance` names what produced them. Returns the
  scored month map the report renders, with `:report_path` added.
  """
  def score_month(client, period, invoices, provenance, opts \\ []) do
    {:ok, filed} = filed_return(client, period)
    header = Gstr1.production_header(gstin!(client), period)

    derived = Gstr1.derive(invoices, header)
    index = Adjudications.load(client, period)

    rows =
      derived
      |> Gstr1Diff.rows(filed)
      |> Enum.map(&annotate(&1, invoices, index))

    mismatches = Enum.reject(rows, & &1["match"])

    month = %{
      client: client,
      period: period,
      rows: rows,
      mismatches: mismatches,
      by_invoice: Report.by_invoice(mismatches),
      auditor_rows: Report.auditor_rows(rows, index),
      adjudicated_count: Enum.count(mismatches, &Adjudications.verdict(index, &1)),
      raw: Gstr1Diff.score(rows),
      adjusted: adjusted(rows, index),
      reviewed: reviewed(invoices, index, header, filed),
      policy: Gstr1Diff.policy(),
      provenance: provenance
    }

    dir =
      Keyword.get(opts, :dir, Path.join([@run_root, provenance["run_id"], "#{client}-#{period}"]))

    Map.put(month, :report_path, Report.write!(dir, month))
  end

  # The extracted value behind a portal field, where one exists. Only the three
  # identity fields map 1:1 — `val`, every `itm_det` amount, all HSN and
  # doc_issue rows are sums or ranges over many invoices, and inventing a single
  # "extracted" number for them would mean a second derivation, which is the
  # thing this plan deletes. Those rows show `nil` and are settled by looking at
  # the page.
  defp annotate(row, invoices, index) do
    invoice = invoice_for(row, invoices)
    entry = Adjudications.verdict(index, row)

    row
    |> Map.put("extracted", extracted_value(row, invoice))
    |> Map.put("image", invoice && invoice["image"])
    |> Map.put("verdict", entry && entry["verdict"])
    |> Map.put("bucket", nil)
  end

  defp extracted_value(%{"scope" => "invoice", "field" => field}, invoice) when is_map(invoice) do
    case field do
      "inum" -> invoice["invoice_number"]
      "ctin" -> invoice["buyer_gstin"]
      "idt" -> invoice["invoice_date"] && to_string(invoice["invoice_date"])
      _other -> nil
    end
  end

  defp extracted_value(_row, _invoice), do: nil

  # Rows are keyed `ctin|inum|rate`; the invoice number is the only part that
  # survives a grouping change, so match on it alone.
  defp invoice_for(%{"key" => key}, invoices) do
    case String.split(key, "|") do
      [_ctin, inum | _rest] -> Enum.find(invoices, &(&1["invoice_number"] == inum))
      _other -> nil
    end
  end

  # AUDITOR means the engine is right and the return is not, so those rows stop
  # counting against it. Reported only once a month has been adjudicated —
  # before that it would be raw wearing a second name.
  defp adjusted(_rows, index) when map_size(index) == 0, do: nil

  defp adjusted(rows, index) do
    rows
    |> Enum.reject(fn row ->
      entry = Adjudications.verdict(index, row)
      entry && entry["verdict"] == "AUDITOR"
    end)
    |> Gstr1Diff.score()
  end

  # The product's own correction path, not a second one: `materialize/4` filters
  # corrections to flagged fields, applies them through `Gstr1.apply_corrections/3`
  # and re-derives. It is stricter than the retired script, which applied
  # unflagged corrections and merely reported them — silent corrections never
  # enter the month here.
  defp reviewed(invoices, index, header, filed) do
    case Adjudications.fixes(index) do
      [] ->
        nil

      fixes ->
        worked = Workings.materialize(invoices, fixes, header)
        score = Gstr1Diff.score(Gstr1Diff.rows(worked.derived, filed))
        Map.put(score, "silent_errors", length(worked.silent_errors))
    end
  end
end
