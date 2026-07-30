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

  alias Nila.Eval.Gstr1Diff
  alias Nila.Gst.Sales.Gstr1

  @artifact_root "tmp/eval"
  @fixture_root "test/fixtures/gstr1"

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
end
