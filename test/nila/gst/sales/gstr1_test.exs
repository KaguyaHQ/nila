defmodule Nila.Gst.Sales.Gstr1Test do
  @moduledoc """
  Unit + reproduction tests for the GSTR-1 derivation engine.

  The unit tests are self-contained. The reproduction tests replay the real
  filed-return eval against the captured page artifacts in `tmp/eval/<period>-<client>/pages`
  (gitignored — see `docs/.plans/2026-07-29-eval-loop.md`). When those artifacts
  are absent (a cold checkout / CI), the reproduction cases skip rather than
  fail — which is why they are not a gate, and why they are replaced by
  synthetic-fixture tests once the corpus is re-extracted under Mistral. The
  baselines below measure LlamaExtract and are retained only until that sweep.
  """
  use ExUnit.Case, async: true

  alias Nila.Eval.Gstr1Diff
  alias Nila.Gst.Sales.Gstr1

  @eval_root Path.expand("../../../../tmp/eval", __DIR__)
  @fixtures_root Path.expand("../../../../test/fixtures/gstr1", __DIR__)

  describe "valid_gstin?/1" do
    test "accepts real GSTINs and rejects checksum-broken ones" do
      assert Gstr1.valid_gstin?("33AEWPH4158J1Z3")
      assert Gstr1.valid_gstin?("33BPBPK1081A1ZO")
      refute Gstr1.valid_gstin?("33AEWPH4158J1Z4")
      refute Gstr1.valid_gstin?("garbage")
      refute Gstr1.valid_gstin?(nil)
    end
  end

  describe "normalize_invoice/1" do
    test "drops degenerate lines and lifts nested seller/buyer" do
      raw = %{
        "page" => 1,
        "data" => %{
          "invoice_number" => " 20 / 2026-27 ",
          "invoice_date" => "04.05.2026",
          "seller" => %{"name" => "S", "gstin" => "33AEWPH4158J1Z3"},
          "buyer" => %{"name" => "B", "gstin" => "33AABCP9487A1ZG"},
          "line_items" => [
            %{"taxable_value" => 1000, "cgst_amount" => 90, "sgst_amount" => 90},
            %{"taxable_value" => 0, "quantity" => 0}
          ]
        }
      }

      invoice = Gstr1.normalize_invoice(raw)
      assert invoice["invoice_number"] == "20/2026-27"
      assert invoice["seller_gstin"] == "33AEWPH4158J1Z3"
      assert length(invoice["line_items"]) == 1
    end

    # Parsed here so every kind of packet carries the same type downstream and a
    # check written once covers all of them — the gap that let a June sales
    # packet file itself into December unremarked.
    test "parses printed dates in every shape the packets arrive in" do
      for printed <- ["04.05.2026", "04/05/2026", "04-05-2026", "2026-05-04", "4/5/26"] do
        assert dated(printed)["invoice_date"] == ~D[2026-05-04], "failed on #{printed}"
      end
    end

    test "a date nothing can read keeps its printed text rather than becoming nil" do
      assert dated("Invoice Dt.")["invoice_date"] == "Invoice Dt."
      assert dated(nil)["invoice_date"] == nil
    end
  end

  describe "validation_issues/1 — the date that reaches the portal unchecked" do
    test "an unreadable date is raised as a correctable issue" do
      issues = Gstr1.validation_issues([dated("Invoice Dt.")])
      assert issue = Enum.find(issues, &(&1["code"] == "unreadable_invoice_date"))
      assert "invoice_date" in issue["fields"]
    end

    test "a date that parsed is not an issue" do
      codes = Gstr1.validation_issues([dated("04.05.2026")]) |> Enum.map(& &1["code"])
      refute "unreadable_invoice_date" in codes
    end

    # The provider schemas ask for a string; that is a request, not a guarantee.
    # A bare number files as `idt: "20260504"` and is invisible to the period
    # checks too, so it has to be caught here or nowhere.
    test "a date that is not even text is caught" do
      codes = Gstr1.validation_issues([dated(20_260_504)]) |> Enum.map(& &1["code"])
      assert "unreadable_invoice_date" in codes
    end

    test "an invoice carrying values but no date is asked for one" do
      for empty <- [nil, "", "   "] do
        issue = Gstr1.validation_issues([dated(empty)]) |> Enum.find(&date_issue?/1)
        assert issue, "stayed quiet on #{inspect(empty)}"
        assert issue["message"] =~ "no invoice date was extracted"
      end
    end

    # Same gate `invoice_number_issues/1` uses. A caption scraped off a page
    # header is not a bill, and flagging it is noise in the reviewer's queue.
    test "a furniture row with no values is not asked about its date" do
      furniture =
        Gstr1.normalize_invoice(%{
          "page" => 1,
          "data" => %{
            "invoice_number" => nil,
            "invoice_date" => "Invoice Dt.",
            "line_items" => []
          }
        })

      refute Enum.any?(Gstr1.validation_issues([furniture]), &date_issue?/1)
    end
  end

  describe "derive/2 — the portal's date format" do
    # `idt` is DD-MM-YYYY. Swapping separators on whatever the model printed only
    # produced that by luck: an ISO date came out ISO and was filed that way.
    test "renders idt as DD-MM-YYYY whatever the bill printed" do
      for printed <- ["2026-05-04", "04/05/2026", "4.5.2026"] do
        assert idt(printed) == "04-05-2026", "failed on #{printed}"
      end
    end
  end

  defp date_issue?(issue), do: issue["code"] == "unreadable_invoice_date"

  defp dated(printed) do
    Gstr1.normalize_invoice(%{
      "page" => 1,
      "data" => %{
        "invoice_number" => "20/2026-27",
        "invoice_date" => printed,
        "seller" => %{"name" => "S", "gstin" => "33AEWPH4158J1Z3"},
        "buyer" => %{"name" => "B", "gstin" => "33AABCP9487A1ZG"},
        "line_items" => [
          %{"taxable_value" => 1000, "cgst_rate" => 9, "cgst_amount" => 90, "sgst_amount" => 90}
        ],
        "printed_grand_total" => 1180.0
      }
    })
  end

  defp idt(printed) do
    %{"b2b" => [%{"inv" => [inv | _rest]} | _more]} =
      Gstr1.derive([dated(printed)], %{"gstin" => "33AEWPH4158J1Z3", "fp" => "052026"})

    inv["idt"]
  end

  describe "validation_issues/1 — the poison-total canary" do
    test "raises grand_total_mismatch when printed total disagrees with line sums" do
      invoice =
        Gstr1.normalize_invoice(%{
          "data" => %{
            "invoice_number" => "20/2026-27",
            "invoice_date" => "04.05.2026",
            "seller" => %{"gstin" => "33AEWPH4158J1Z3"},
            "buyer" => %{"gstin" => "33AABCP9487A1ZG"},
            "line_items" => [
              %{"taxable_value" => 64_552, "cgst_amount" => 5809.68, "sgst_amount" => 5809.68}
            ],
            "printed_grand_total" => 2_75_000.00
          }
        })

      codes = Gstr1.validation_issues([invoice]) |> Enum.map(& &1["code"])
      assert "grand_total_mismatch" in codes
    end

    test "flags implausible invoice numbers as correctable issues" do
      suspicious = seq_invoice("9381153296")
      ordinary = seq_invoice("INV-2025/046")

      issues = Gstr1.validation_issues([suspicious, ordinary])

      assert Enum.any?(issues, fn issue ->
               issue["invoice"] == "9381153296" and
                 issue["code"] == "implausible_invoice_number" and
                 issue["fields"] == ["invoice_number"]
             end)

      refute Enum.any?(issues, fn issue ->
               issue["invoice"] == "INV-2025/046" and
                 issue["code"] == "implausible_invoice_number"
             end)

      flagged = Gstr1.flagged_fields([suspicious, ordinary], issues)
      assert MapSet.member?(flagged, {"9381153296", "invoice_number"})
    end

    test "flags sequence gaps from the observed invoice numbers" do
      invoices =
        for n <- [20, 21, 23], do: seq_invoice("#{n}/2026-27")

      codes = Gstr1.validation_issues(invoices) |> Enum.map(& &1["code"])
      assert "sequence_gaps" in codes
    end
  end

  describe "apply_corrections/3 — silent-error discipline" do
    setup do
      invoice = seq_invoice("20/2026-27")
      flagged = Gstr1.flagged_fields([invoice], [])
      %{invoice: invoice, flagged: flagged}
    end

    test "a correction to an unflagged field is a silent error", %{
      invoice: invoice,
      flagged: flagged
    } do
      corrections = [%{"invoice" => "20/2026-27", "field" => "buyer_name", "value" => "X"}]
      {_final, ok, silent, _} = Gstr1.apply_corrections([invoice], corrections, flagged)
      assert ok == []
      assert length(silent) == 1
    end

    test "a correction to a flagged field is legitimate", %{invoice: invoice} do
      flagged =
        Gstr1.flagged_fields([invoice], [
          %{"invoice" => "20/2026-27", "code" => "x", "fields" => ["buyer_name"]}
        ])

      corrections = [%{"invoice" => "20/2026-27", "field" => "buyer_name", "value" => "X"}]
      {_final, ok, silent, _} = Gstr1.apply_corrections([invoice], corrections, flagged)
      assert length(ok) == 1
      assert silent == []
    end
  end

  describe "derive/2 — empty domain" do
    test "zero invoices returns an empty-but-valid return, not a crash" do
      result = Gstr1.derive([], %{"gstin" => "33AEWPH4158J1Z3", "fp" => "052026"})

      assert result["gstin"] == "33AEWPH4158J1Z3"
      assert result["b2b"] == []
      assert result["doc_issue"] == %{"doc_det" => []}
      assert result["hsn"] == %{"hsn_b2b" => [], "hsn_b2c" => []}
    end

    test "invoices with no parseable numbers yield an empty doc_issue" do
      invoice = %{"invoice_number" => nil, "buyer_gstin" => "33AABCP9487A1ZG", "line_items" => []}
      result = Gstr1.derive([invoice], %{"gstin" => "33AEWPH4158J1Z3", "fp" => "052026"})

      assert result["doc_issue"] == %{"doc_det" => []}
    end
  end

  describe "review correction helpers" do
    test "returns only sorted scalar fields for the pristine invoice number" do
      flagged =
        MapSet.new([
          {"INV-1", "seller_name"},
          {"INV-1", "line_items[0].taxable_value"},
          {"INV-1", "line_items"},
          {"INV-1", "doc_issue"},
          {"INV-1", "line_items[0].confidence"},
          {"INV-2", "buyer_name"}
        ])

      assert Gstr1.correctable_fields(flagged, "INV-1") == [
               "line_items[0].taxable_value",
               "seller_name"
             ]
    end

    test "reads scalar and indexed line-item field paths" do
      invoice = %{
        "invoice_number" => "1234",
        "line_items" => [%{"taxable_value" => 125.5}]
      }

      assert Gstr1.field_value(invoice, "invoice_number") == "1234"
      assert Gstr1.field_value(invoice, "line_items[0].taxable_value") == 125.5
      assert Gstr1.field_value(invoice, "line_items[9].taxable_value") == nil
    end

    test "coerces only the existing numeric field set and leaves invoice numbers as strings" do
      assert Gstr1.coerce_correction("printed_total_taxable", "100.25") == 100.25
      assert Gstr1.coerce_correction("line_items[0].cgst_amount", "9") == 9.0
      assert Gstr1.coerce_correction("invoice_number", "1234") == "1234"
      assert Gstr1.coerce_correction("line_items[0].description", "9") == "9"
      assert Gstr1.coerce_correction("line_items[0].taxable_value", "9x") == "9x"
    end

    test "sums only extracted numeric line-item values without rounding" do
      invoice = %{
        "line_items" => [
          %{
            "taxable_value" => 100.25,
            "cgst_amount" => 9.02,
            "sgst_amount" => 9.02,
            "igst_amount" => nil
          },
          %{
            "taxable_value" => 50,
            "cgst_amount" => "4.5",
            "sgst_amount" => 0,
            "igst_amount" => 9.5
          }
        ]
      }

      assert Gstr1.extracted_totals(invoice) == %{taxable: 150.25, tax: 27.54}
    end
  end

  # Reproduction baselines against real filed returns. `raw` is the first-pass
  # score; nil means "run it, just don't assert a number yet". These lock in
  # current behavior — change them deliberately when a rule is fixed.
  @baselines %{
    {"breeze", "2026-05"} => 87.34,
    {"breeze", "2026-01"} => 92.14,
    {"caltech", "2025-10"} => 55.79,
    {"caltech", "2025-11"} => 69.52,
    {"caltech", "2025-12"} => 53.23,
    {"caltech", "2026-01"} => 57.84
  }

  describe "reproduction against filed returns (replays tmp/eval artifacts)" do
    for {{client, period}, expected} <- @baselines do
      @tag client: client, period: period, expected: expected
      test "#{client} #{period} derives to the #{expected}% baseline" do
        pages_dir = Path.join([@eval_root, "#{unquote(period)}-#{unquote(client)}", "pages"])

        filed_glob =
          Path.join([@fixtures_root, unquote(client), unquote(period), "returns_*.json"])

        cond do
          not File.dir?(pages_dir) ->
            # Captured extraction artifacts are gitignored; skip on cold checkout.
            assert true

          [filed_path] = Path.wildcard(filed_glob) ->
            invoices = load_invoices(pages_dir)
            filed = filed_path |> File.read!() |> Jason.decode!()
            derived = Gstr1.derive(invoices, filed)
            result = Gstr1Diff.diff(derived, filed)
            assert_in_delta result["score"], unquote(expected), 0.01
        end
      end
    end
  end

  defp load_invoices(pages_dir) do
    pages_dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&(&1 |> File.read!() |> Jason.decode!() |> Gstr1.normalize_invoice()))
  end

  defp seq_invoice(number) do
    Gstr1.normalize_invoice(%{
      "data" => %{
        "invoice_number" => number,
        "invoice_date" => "04.05.2026",
        "seller" => %{"gstin" => "33AEWPH4158J1Z3"},
        "buyer" => %{"gstin" => "33AABCP9487A1ZG"},
        "line_items" => [
          %{
            "taxable_value" => 1000,
            "cgst_rate" => 9,
            "cgst_amount" => 90,
            "sgst_rate" => 9,
            "sgst_amount" => 90
          }
        ]
      }
    })
  end
end
