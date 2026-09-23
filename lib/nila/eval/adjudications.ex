defmodule Nila.Eval.Adjudications do
  @moduledoc """
  Committed human verdicts on the field rows a month's diff could not settle.

  Attribution is partial by construction: there is ground truth for the output
  (the filed return) and none for the input (what the bill actually printed).
  `19942.40` vs `19942` is either OCR reading a smudge or the auditor rounding,
  and no artifact in the repo distinguishes them. So a human looks once, and the
  verdict is recorded and reused.

  ## Verdicts

    * `AUDITOR` — we read it right, they filed differently. Excluded from the
      adjusted score; this is the confession sheet shown to a partner.
    * `OCR_MISREAD` — the read was wrong. Carries a `fix`, and only this verdict
      does: it is the one case where "the bill actually reads X" exists.
    * `OUR_BUG` — the read was right and the rules mangled it. No fix; writing
      one would paper over the bug the verdict exists to expose.
    * `CORRECT_BUT_UNMATCHED` — right values, wrong grouping or key. A diff
      artifact, not an engine error.

  ## The file is the only source

  The eval reads adjudications from `eval/adjudications/` and nowhere else —
  no database precedence. A run scored against un-exported DB rows would not be
  reproducible from the repo, which is the provenance the eval loop exists for.
  With file-only reads a run record's git sha pins exactly which adjudication
  state produced the score, and a stale file shows up as an un-exported diff
  rather than being silently resolved.

  Once the workbench's derived-vs-filed mode exists the flow is one-way:

      UI → sales_resolutions (attributed) → mix nila.eval adjudications --from-db
         → committed JSON → eval

  A web request must never write this directory: a web process writing the repo
  working tree is wrong on deploy, wrong on concurrency, and wrong on
  attribution — resolutions carry `decided_by_id`, a JSON file carries nobody.
  This format is interim; its end state is `sales_resolutions`.
  """

  @verdicts ~w(AUDITOR OCR_MISREAD OUR_BUG CORRECT_BUT_UNMATCHED)
  @root "eval/adjudications"

  def verdicts, do: @verdicts

  @doc "Path a month's verdicts live at."
  def path(client, period), do: Path.join(@root, "#{client}-#{period}.json")

  @doc """
  Verdicts for a month, keyed by `{scope, key, field}` — the same grain
  `Gstr1Diff` rows carry, so a lookup is a map fetch.

  Returns an empty map when the month has not been adjudicated.
  """
  def load(client, period) do
    path = path(client, period)
    if File.exists?(path), do: load_path(path), else: %{}
  end

  @doc "Loads and validates one adjudication file by path."
  def load_path(path) do
    path |> File.read!() |> Jason.decode!() |> index!(path)
  end

  defp index!(entries, path) when is_list(entries) do
    Map.new(entries, fn entry ->
      validate!(entry, path)
      {{entry["scope"], entry["key"], entry["field"]}, entry}
    end)
  end

  # A verdict keyed to a value that has since changed describes a field nobody
  # looked at, so `stale?/2` sends it back to the worklist rather than letting
  # it silently vouch for a new number.
  @doc "True when the row's filed value has moved away from what was adjudicated."
  def stale?(%{"filed" => adjudicated}, %{"filed" => current}), do: adjudicated != current

  @doc """
  The verdict for a row, or `nil` when unadjudicated or stale.
  """
  def verdict(index, row) do
    case Map.get(index, {row["scope"], row["key"], row["field"]}) do
      nil -> nil
      entry -> unless stale?(entry, row), do: entry
    end
  end

  @doc """
  Every `OCR_MISREAD` fix in the month, flattened into the resolution maps
  `Nila.Gst.Sales.Workings.materialize/4` consumes.

  A fix is one resolution or a list of them: a single portal bucket is a sum
  over N line items (`Gstr1.derive_invoice/2` groups lines by rate), so one
  mismatch can require correcting two lines.
  """
  def fixes(index) do
    index
    |> Map.values()
    |> Enum.filter(&(&1["verdict"] == "OCR_MISREAD"))
    |> Enum.flat_map(&List.wrap(&1["fix"]))
  end

  defp validate!(entry, path) do
    entry["verdict"] in @verdicts ||
      raise ArgumentError,
            "#{path}: unknown verdict #{inspect(entry["verdict"])}, expected one of #{Enum.join(@verdicts, ", ")}"

    fixes = List.wrap(entry["fix"])

    case {entry["verdict"], fixes} do
      {"OCR_MISREAD", []} ->
        raise ArgumentError,
              "#{path}: OCR_MISREAD on #{entry["key"]}/#{entry["field"]} needs a fix — " <>
                "the whole point of the verdict is what the bill actually reads"

      {"OCR_MISREAD", fixes} ->
        Enum.each(fixes, &validate_fix!(&1, entry, path))

      {verdict, [_ | _]} ->
        raise ArgumentError,
              "#{path}: #{verdict} on #{entry["key"]}/#{entry["field"]} carries a fix. " <>
                "Only OCR_MISREAD does; a fix on OUR_BUG papers over the bug."

      {_verdict, []} ->
        :ok
    end
  end

  # Fixes are `correct_field` resolutions so migrating one into the workbench is
  # an insert, not a translation — and so they flow through the product's own
  # correction path, which enforces the flagged-fields discipline.
  defp validate_fix!(fix, entry, path) do
    fix["verb"] == "correct_field" ||
      raise ArgumentError,
            "#{path}: fix on #{entry["key"]}/#{entry["field"]} must be a correct_field " <>
              "resolution, got #{inspect(fix["verb"])}"

    (is_binary(fix["target"]) && is_binary(get_in(fix, ["payload", "field"]))) ||
      raise ArgumentError,
            "#{path}: fix on #{entry["key"]}/#{entry["field"]} needs target (the source " <>
              "ID) and payload.field (the input-side path, e.g. line_items[0].taxable_value)"
  end
end
