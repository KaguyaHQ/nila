Code.require_file(Path.join(__DIR__, "gstr1_eval_lib.exs"))

defmodule Gstr1EvalScript do
  def run(args) do
    opts = Gstr1Eval.parse_args(args)
    File.mkdir_p!(opts.out_dir)

    filed = Gstr1Eval.read_json!(opts.filed_path)
    invoices = Gstr1Eval.load_invoices!(opts.pages_dir)

    if invoices == [] do
      Mix.raise(
        "no extracted page artifacts found in #{opts.pages_dir}; run scripts/extract_sales.exs first"
      )
    end

    issues = Gstr1Eval.validation_issues(invoices)
    flagged = Gstr1Eval.flagged_fields(invoices, issues)
    derived = Gstr1Eval.derive_gstr1(invoices, filed)
    derived_path = Path.join(opts.out_dir, "derived_gstr1.json")
    Gstr1Eval.write_json!(derived_path, derived)

    raw = Gstr1Eval.diff(derived, filed)

    {final_invoices, flagged_corrections, silent_errors, _flagged} =
      Gstr1Eval.apply_corrections(invoices, opts.corrections_path, flagged)

    final =
      if opts.corrections_path do
        final_derived = Gstr1Eval.derive_gstr1(final_invoices, filed)

        Gstr1Eval.write_json!(
          Path.join(opts.out_dir, "derived_gstr1.reviewed.json"),
          final_derived
        )

        Gstr1Eval.diff(final_derived, filed)
      end

    report = %{
      "fixture_dir" => opts.fixture_dir,
      "pages_dir" => opts.pages_dir,
      "filed_path" => opts.filed_path,
      "derived_path" => derived_path,
      "raw" => raw,
      "final" => final,
      "issues" => issues,
      "flagged_corrections" => Enum.reverse(flagged_corrections),
      "silent_errors" => Enum.reverse(silent_errors)
    }

    report_path = Path.join(opts.out_dir, "eval_report.json")
    Gstr1Eval.write_json!(report_path, report)
    Gstr1Eval.print_report(report)
    IO.puts("wrote #{derived_path}")
    IO.puts("wrote #{report_path}")
  end
end

Gstr1EvalScript.run(System.argv())
