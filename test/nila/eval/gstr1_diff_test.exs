defmodule Nila.Eval.Gstr1DiffTest do
  @moduledoc """
  Synthetic-fixture coverage for the differ.

  Deliberately not the real corpus: those artifacts are gitignored, so a test
  keyed on them reports "skipped" as if it were "passed" everywhere but one
  machine. These run anywhere, with no client data in git.
  """
  use ExUnit.Case, async: true

  alias Nila.Eval.Gstr1Diff

  defp return(opts \\ []) do
    %{
      "b2b" => [
        %{
          "ctin" => "33AABCP9487A1ZG",
          "inv" => [
            %{
              "inum" => "1",
              "idt" => "04-05-2026",
              "val" => Keyword.get(opts, :val, 1180),
              "pos" => "33",
              "rchrg" => "N",
              "inv_typ" => "R",
              "chksum" => Keyword.get(opts, :chksum, "abc"),
              "itms" => [
                %{
                  "num" => 1,
                  "itm_det" => %{
                    "rt" => 18,
                    "txval" => Keyword.get(opts, :txval, 1000),
                    "camt" => 90,
                    "samt" => 90,
                    "iamt" => 0,
                    "csamt" => 0
                  }
                }
              ]
            }
          ]
        }
      ],
      "hsn" => %{"hsn_b2b" => [], "hsn_b2c" => []},
      "doc_issue" => %{"doc_det" => []}
    }
  end

  describe "rows/2" do
    test "an identical return matches every compared field" do
      rows = Gstr1Diff.rows(return(), return())

      assert Enum.all?(rows, & &1["match"])
      assert %{"score" => 100.0} = Gstr1Diff.score(rows)
    end

    test "carries scope, key and both sides so a mismatch is readable without the score" do
      rows = Gstr1Diff.rows(return(txval: 900), return())
      row = Enum.find(rows, &(&1["field"] == "txval"))

      assert row["scope"] == "invoice_item"
      assert row["key"] == "33AABCP9487A1ZG|1|18"
      assert row["derived"] == 900
      assert row["filed"] == 1000
      refute row["match"]
    end

    test "portal bookkeeping fields are not compared" do
      rows = Gstr1Diff.rows(return(chksum: "different"), return())

      assert Enum.all?(rows, & &1["match"])
      refute Enum.any?(rows, &(&1["field"] == "chksum"))
    end

    test "an invoice missing from one side still produces rows, with that side nil" do
      rows = Gstr1Diff.rows(%{"b2b" => []}, return())
      invoice_rows = Enum.filter(rows, &(&1["scope"] in ["invoice", "invoice_item"]))

      assert length(invoice_rows) > 0
      assert Enum.all?(invoice_rows, &is_nil(&1["derived"]))
    end

    # Pinned because it flatters a missing invoice: `nil` numifies to 0, so a
    # filed row of 0 "agrees" with an invoice we never produced. Every baseline
    # was measured under this rule, so it is behaviour to change deliberately
    # with the numbers re-measured, not to quietly fix.
    test "a nil side matches a filed zero, so missing invoices score better than nothing" do
      rows = Gstr1Diff.rows(%{"b2b" => []}, return())

      csamt = Enum.find(rows, &(&1["field"] == "csamt"))
      assert csamt["derived"] == nil and csamt["filed"] == 0
      assert csamt["match"], "nil vs filed 0 currently counts as agreement"

      txval = Enum.find(rows, &(&1["field"] == "txval"))
      refute txval["match"], "a non-zero filed amount still fails"
    end
  end

  describe "tolerances" do
    test "amounts must agree to the paise" do
      assert [%{"match" => true}] = txval_rows(1000.005)
      assert [%{"match" => false}] = txval_rows(1000.5)
    end

    test "the invoice total tolerates the auditor's whole-rupee rounding" do
      assert [%{"match" => true}] = val_rows(1180.4)
      assert [%{"match" => false}] = val_rows(1182.0)
    end

    test "numbers compare by value across string and numeric encodings" do
      assert [%{"match" => true}] = txval_rows("1000")
      assert [%{"match" => true}] = txval_rows("1,000.00")
    end
  end

  defp txval_rows(value) do
    return(txval: value)
    |> Gstr1Diff.rows(return())
    |> Enum.filter(&(&1["field"] == "txval"))
  end

  defp val_rows(value) do
    return(val: value)
    |> Gstr1Diff.rows(return())
    |> Enum.filter(&(&1["field"] == "val"))
  end

  describe "score/1" do
    test "an empty comparison scores zero rather than dividing by nothing" do
      assert %{"score" => score, "total" => 0} = Gstr1Diff.score([])
      assert score == 0.0
    end

    test "mismatches are carried alongside the percentage" do
      rows = Gstr1Diff.rows(return(txval: 900), return())

      %{"mismatches" => mismatches, "matches" => matches, "total" => total} =
        Gstr1Diff.score(rows)

      assert length(mismatches) == total - matches
      assert Enum.all?(mismatches, &(&1["match"] == false))
    end
  end

  describe "HSN code length" do
    defp with_hsn(rows) do
      %{"b2b" => [], "hsn" => %{"hsn_b2b" => rows}, "doc_issue" => %{"doc_det" => []}}
    end

    defp hsn(code, txval, opts \\ []) do
      %{
        "hsn_sc" => code,
        "rt" => 18,
        "txval" => txval,
        "camt" => Keyword.get(opts, :camt, 0),
        "samt" => Keyword.get(opts, :samt, 0),
        "iamt" => Keyword.get(opts, :iamt, 0)
      }
    end

    test "the same classification written to different digit counts agrees" do
      ours = with_hsn([hsn("998719", 1000)])
      theirs = with_hsn([hsn("9987", 1000)])

      assert Enum.all?(Gstr1Diff.rows(ours, theirs), & &1["match"]),
             "9987 is 998719 read to fewer digits, not a different product"
    end

    test "several specific codes roll into the summary row they belong to" do
      ours = with_hsn([hsn("998717", 400), hsn("998719", 600)])
      theirs = with_hsn([hsn("9987", 1000)])

      rows = Gstr1Diff.rows(ours, theirs)

      assert Enum.all?(rows, & &1["match"])
      assert Enum.find(rows, &(&1["field"] == "txval"))["derived"] == 1000.0
    end

    test "a real gap survives the roll-up" do
      ours = with_hsn([hsn("998717", 400), hsn("998719", 500)])
      theirs = with_hsn([hsn("9987", 1000)])

      txval = Enum.find(Gstr1Diff.rows(ours, theirs), &(&1["field"] == "txval"))

      refute txval["match"], "rolling up must not hide missing money"
      assert txval["derived"] == 900.0
    end

    test "genuinely different classifications still disagree" do
      ours = with_hsn([hsn("996519", 1000)])
      theirs = with_hsn([hsn("998719", 1000)])

      refute Enum.all?(Gstr1Diff.rows(ours, theirs), & &1["match"]),
             "a courier code and a maintenance code are not the same row"
    end

    test "the same rate is required, not just the same code" do
      ours = with_hsn([%{hsn("998719", 1000) | "rt" => 5}])
      theirs = with_hsn([hsn("9987", 1000)])

      refute Enum.all?(Gstr1Diff.rows(ours, theirs), & &1["match"])
    end

    test "tax amounts roll up with the taxable value" do
      ours = with_hsn([hsn("998717", 400, camt: 36), hsn("998719", 600, camt: 54)])
      theirs = with_hsn([hsn("9987", 1000, camt: 90)])

      assert Enum.all?(Gstr1Diff.rows(ours, theirs), & &1["match"])
    end
  end

  describe "policy/0" do
    test "records the comparison rules a score depends on" do
      policy = Gstr1Diff.policy()

      assert policy["tolerance"] == 0.01
      assert policy["val_tolerance"] == 1.0
      assert "chksum" in policy["ignored_invoice_fields"]
      assert policy["hsn_comparison"] =~ "shorter"
    end
  end
end
