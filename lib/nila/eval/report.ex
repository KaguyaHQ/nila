defmodule Nila.Eval.Report do
  @moduledoc """
  Renders a scored month as `fields.jsonl` and `report.md`.

  Deliberately cheap. The instrument a human works through is the workbench's
  derived-vs-filed mode; this is a default renderer over the same field rows and
  the bail-out artifact if that screen slips. Nobody should polish it.

  The report is ordered for the way a mismatch is actually settled — by invoice,
  disagreements first, each one showing derived against filed with the scanned
  page named — because the question is never "what is the score" but "is this
  line right, and how would I know."
  """

  alias Nila.Eval.Adjudications

  @doc "Writes `fields.jsonl` and `report.md` into `dir`, returns the report path."
  def write!(dir, month) do
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "fields.jsonl"),
      month.rows |> Enum.map(&(Jason.encode!(&1) <> "\n")) |> Enum.join()
    )

    path = Path.join(dir, "report.md")
    File.write!(path, render(month))
    path
  end

  @doc "The markdown body for a scored month."
  def render(month) do
    [
      header(month),
      scores(month),
      confession(month),
      worklist(month),
      footer(month)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp header(month) do
    """
    # #{month.client} · #{month.period}

    #{month.provenance["extractor"]} · #{month.provenance["model"]} · prompt `#{short(month.provenance["prompt_fingerprint"])}`
    scored #{month.provenance["scored_at"]} · #{month.provenance["run_id"]}
    """
  end

  defp scores(month) do
    """

    ## Score

    | leg | score | matched | compared |
    |---|---|---|---|
    #{score_row("raw", month.raw)}
    #{leg_row("adjusted", month.adjusted, "unadjudicated")}
    #{leg_row("reviewed", month.reviewed, "not applicable")}

    #{note(month)}
    """
  end

  defp score_row(label, result) do
    "| #{label} | #{result["score"]}% | #{result["matches"]} | #{result["total"]} |"
  end

  defp leg_row(label, nil, reason), do: "| #{label} | _#{reason}_ | | |"
  defp leg_row(label, result, _reason), do: score_row(label, result)

  defp note(%{adjudicated_count: 0}),
    do: "_No adjudications yet — every mismatch below is unsettled._"

  defp note(month) do
    "_#{month.adjudicated_count} of #{length(month.mismatches)} mismatches adjudicated._"
  end

  # The rows where we are right and the filed return is not. Written in advance
  # so the conversation is prepared rather than improvised.
  defp confession(%{auditor_rows: []}), do: ""

  defp confession(month) do
    """

    ## Where we differ from the filed return (and we are right)

    #{Enum.map_join(month.auditor_rows, "\n", &confession_row/1)}
    """
  end

  defp confession_row({row, entry}) do
    "- **#{row["key"]}** `#{row["field"]}` — ours #{fmt(row["derived"])}, filed #{fmt(row["filed"])}. #{entry["note"]}"
  end

  defp worklist(%{mismatches: []}) do
    """

    ## Mismatches

    None — every compared field agrees.
    """
  end

  defp worklist(month) do
    """

    ## Mismatches by invoice

    #{Enum.map_join(month.by_invoice, "\n", &invoice_block/1)}
    """
  end

  defp invoice_block({key, rows}) do
    """
    ### #{key}#{page_ref(rows)}#{orphan_note(rows)}

    | field | extracted | derived | filed | verdict |
    |---|---|---|---|---|
    #{Enum.map_join(rows, "\n", &field_row/1)}
    """
  end

  # A block where one whole side is missing is not N wrong fields — it is one
  # invoice that did not match, and reading it as a field-by-field disagreement
  # sends you looking for the wrong thing.
  defp orphan_note(rows) do
    cond do
      Enum.all?(rows, &is_nil(&1["filed"])) -> " — **not in the filed return**"
      Enum.all?(rows, &is_nil(&1["derived"])) -> " — **filed, but we produced nothing**"
      true -> ""
    end
  end

  # The invoice's own answer to "which page was this read from" — guessing a
  # basename from the row would fabricate a path to a file nobody stored.
  defp page_ref(rows) do
    case Enum.find_value(rows, & &1["image"]) do
      nil -> ""
      image -> " · `#{image}`"
    end
  end

  defp field_row(row) do
    "| `#{row["field"]}` | #{fmt(row["extracted"])} | #{fmt(row["derived"])} | #{fmt(row["filed"])} | #{verdict_cell(row)} |"
  end

  defp verdict_cell(%{"verdict" => nil, "bucket" => nil}), do: "—"
  defp verdict_cell(%{"verdict" => nil, "bucket" => bucket}), do: "_#{bucket}_"
  defp verdict_cell(%{"verdict" => verdict}), do: "**#{verdict}**"

  defp footer(month) do
    """

    ---

    Diff policy: tolerance #{month.policy["tolerance"]}, `val` tolerance #{month.policy["val_tolerance"]},
    ignored #{Enum.map_join(month.policy["ignored_invoice_fields"], ", ", &"`#{&1}`")}.
    Extraction attempt: `#{month.provenance["attempt"] || "archived artifacts"}`.
    """
  end

  defp fmt(nil), do: "—"
  defp fmt(value) when is_binary(value), do: "`#{value}`"

  # Money, not scientific notation: `9.5e3` is the kind of thing that makes a
  # reviewer distrust the whole page.
  defp fmt(value) when is_float(value) do
    if value == Float.round(value),
      do: "#{trunc(value)}",
      else: :erlang.float_to_binary(value, decimals: 2)
  end

  defp fmt(value), do: "#{value}"

  defp short(nil), do: "n/a"
  defp short(fingerprint), do: String.slice(fingerprint, 0, 12)

  @doc """
  Groups mismatching rows by invoice key, worst first.

  Invoice order rather than field order because a bill is what a human picks up:
  five wrong fields on one invoice is one act of checking, not five.
  """
  def by_invoice(mismatches) do
    mismatches
    |> Enum.group_by(& &1["key"])
    |> Enum.sort_by(fn {key, rows} -> {-length(rows), key} end)
  end

  @doc "Adjudicated `AUDITOR` rows paired with their entry, for the confession sheet."
  def auditor_rows(rows, index) do
    rows
    |> Enum.map(&{&1, Adjudications.verdict(index, &1)})
    |> Enum.filter(fn {_row, entry} -> entry && entry["verdict"] == "AUDITOR" end)
  end
end
