defmodule Nila.Eval do
  @moduledoc """
  The GSTR-1 eval loop: score the engine against filed returns, with provenance.

  This is the engine's measurement organ, not a product surface. The human-facing
  half — derived-vs-filed per invoice, the scanned page one tap away — belongs in
  the workbench; what lives here is what no UI can do: re-score every month in
  seconds after a rule change, and say which extractor, model and prompt produced
  each number.

  `score/2` replays a cached extraction attempt and writes a run record naming
  the extractor, model and prompt fingerprint behind every number — so no score
  is unattributable, and re-scoring after a rule change costs no API calls.

  The lift into `lib/` was proved against the retired script's own numbers
  before the extractor changed underneath it; that bridge and the Llama
  artifacts it read are both gone now that the corpus is extracted by the
  production path.
  """

  alias Nila.Eval.Adjudications
  alias Nila.Eval.Gstr1Diff
  alias Nila.Eval.Report
  alias Nila.EvalCorpus
  alias Nila.Gst.Sales.Gstr1
  alias Nila.Gst.Sales.Workings

  @fixture_root "test/fixtures/gstr1"
  @run_root "tmp/eval/runs"

  # The corpus registry already maps GSTIN to client; production reads the same
  # value off `clients.gstin`. Inverted here because the corpus is keyed the way
  # the portal names things.
  defp gstin!(client) do
    Enum.find_value(Nila.EvalCorpus.clients(), fn {gstin, name} ->
      if name == client, do: gstin
    end) || raise ArgumentError, "no GSTIN in the corpus clients map for #{inspect(client)}"
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

    with {:ok, attempt} <- Nila.Eval.Segmented.latest_attempt(name),
         {:ok, assembled} <- Nila.Eval.Segmented.replay(attempt) do
      invoices = Enum.map(assembled.pages, &Gstr1.normalize_invoice/1)
      meta = attempt |> Path.join("meta.json") |> File.read!() |> Jason.decode!()

      provenance = %{
        "run_id" => run_id,
        "pipeline" => "segmented",
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
