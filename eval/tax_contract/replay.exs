Code.require_file("eval/support/requests.exs")
alias Nila.Eval.Requests
alias Nila.Gst.Extraction.{InvoiceRepairs, InvoiceVerification}
alias Nila.Gst.Extraction.Sales.Normalizer
alias Nila.Gst.Sales.{Workings, Invoice, InvoiceTaxes}

defmodule HoldoutAdapter do
  # These are compatibility tokens, NOT claims about text printed in the PDF.
  # Keep raw model answers separately. Do not infer missing rates or amounts.
  def component(c, location) do
    label =
      case c["kind"] || c["observed_kind"] do
        "combined" -> if location == :item, do: "GST", else: "Total Tax"
        kind when kind in ["cgst", "sgst", "igst", "cess"] -> String.upcase(kind)
        _ -> "UNKNOWN"
      end

    result = %{"printed_label" => label, "printed_amount" => c["amount"]}
    if Map.has_key?(c, "rate"), do: Map.put(result, "printed_rate", c["rate"]), else: result
  end

  def adapt(data) do
    data
    |> Map.update!("printed_tax_totals", &Enum.map(&1, fn c -> component(c, :summary) end))
    |> Map.update!("line_items", fn lines ->
      Enum.map(lines, fn line ->
        Map.update!(
          line,
          "printed_tax_components",
          &Enum.map(&1, fn c -> component(c, :item) end)
        )
      end)
    end)
  end
end

Logger.configure(level: :warning)
[root | output_args] = System.argv()

output_root =
  case output_args do
    [] -> root
    [destination] -> destination
  end

truth = File.read!(root <> "/inputs/expectations.json") |> Jason.decode!()

sources =
  File.read!(root <> "/inputs/sources.json") |> Jason.decode!() |> Map.new(&{&1["id"], &1})

for path <- Path.wildcard(root <> "/attempts/*/*-decoded.json") do
  prefix = Path.basename(path, "-decoded.json")
  dir = Path.dirname(path)
  output_dir = output_root <> "/attempts/" <> prefix
  File.mkdir_p!(output_dir)
  result = File.read!(dir <> "/" <> prefix <> "-result.json") |> Jason.decode!()
  s = sources[result["case_id"]]
  t = truth[result["case_id"]]
  data = File.read!(path) |> Jason.decode!()

  adapted =
    if result["arm"] not in ["production", "footer-rate", "reference", "printed-example"],
      do: HoldoutAdapter.adapt(data),
      else: data

  {prepared, repairs} = InvoiceRepairs.prepare(adapted, :sales, t["seller"])
  verification = InvoiceVerification.structured(prepared, prepared["reverse_charge"] == true)

  evidence = %{
    "status" => to_string(verification.status),
    "flags" =>
      Enum.map(verification.flags, fn {flag, detail} ->
        %{"flag" => to_string(flag), "detail" => inspect(detail)}
      end),
    "failed_checks" =>
      verification.checks
      |> Enum.reject(& &1.ok?)
      |> Enum.map(fn check ->
        %{
          "kind" => to_string(check.kind),
          "field" => check.field,
          "detail" => inspect(check.detail)
        }
      end)
  }

  invoice =
    Normalizer.normalize(%{
      "data" => prepared,
      "page" => hd(s["pages"])["page"],
      "source_pages" => Enum.map(s["pages"], & &1["page"]),
      "verification" => evidence
    })

  [year, month, _] = String.split(t["date"], "-")

  projection =
    Workings.materialize([invoice], [], %{"gstin" => t["seller"], "fp" => month <> year}, [],
      source_namespace: prefix
    )

  active = hd(projection.active_invoices)

  output = %{
    prepared: prepared,
    repairs: repairs,
    verification: evidence,
    normalized: invoice,
    active_invoice: active,
    issues: projection.issues,
    reviewable: Workings.reviewable?(projection.issues),
    derived: projection.derived,
    totals: Invoice.extracted_totals(active),
    tax_heads: InvoiceTaxes.totals(active)
  }

  output =
    case Workings.Xlsx.build(
           projection,
           %{name: result["case_id"], gstin: t["seller"]},
           year <> "-" <> month
         ) do
      {:ok, bytes} ->
        File.write!(output_dir <> "/" <> prefix <> "-workings.xlsx", bytes)
        Map.put(output, :xlsx, "created")

      error ->
        Map.put(output, :xlsx, inspect(error))
    end

  Requests.write(output_dir, prefix <> "-pipeline.json", output)
  IO.puts("#{prefix}: #{length(projection.issues)} issues; XLSX #{output.xlsx}")
end
