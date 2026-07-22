defmodule Nila.Gst.Sales.Gstr1Test do
  @moduledoc """
  Unit + reproduction tests for the GSTR-1 derivation engine.

  The unit tests are self-contained. The reproduction tests replay the real
  filed-return eval against the captured page artifacts in `tmp/eval/<period>-<client>/pages`
  (gitignored — see `docs/.plans/2026-07-06-gstr1-eval.md`). When those artifacts
  are absent (a cold checkout / CI), the reproduction cases skip rather than
  fail. The score baselines below lock in current behavior so future rule changes
  (HSN digit length, rounding convention) are made visible, test-first.
  """
  use ExUnit.Case, async: true

  Code.require_file("scripts/gstr1_eval_lib.exs")

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
            result = Gstr1Eval.diff(derived, filed)
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
