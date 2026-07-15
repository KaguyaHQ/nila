defmodule Nila.Gst.WorkingsTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.{Recon, Workings}

  @gstin "33AAACS1234A1Z9"

  defp books(attrs) do
    Map.merge(
      %{
        "id" => "page_01",
        "vendor_name" => "Sharma Steels",
        "vendor_gstin" => @gstin,
        "invoice_number" => "INV-001",
        "invoice_date" => ~D[2025-04-15],
        "taxable_paise" => 1_000_000,
        "tax_paise" => %{"cgst" => 90_000, "sgst" => 90_000, "igst" => 0},
        "total_paise" => 1_180_000
      },
      attrs
    )
  end

  defp g2b(attrs) do
    Map.merge(
      %{
        "vendor_gstin" => @gstin,
        "vendor_name" => "SHARMA STEELS",
        "invoice_number" => "INV-001",
        "invoice_date" => ~D[2025-04-15],
        "taxable_paise" => 1_000_000,
        "tax_paise" => %{"cgst" => 90_000, "sgst" => 90_000, "igst" => 0},
        "total_paise" => 1_180_000,
        "pos" => "33"
      },
      attrs
    )
  end

  # A recon where the books invoice number disagrees with the 2B: same GSTIN,
  # value and date match, numbers differ -> lands in needs_human with the 2B as
  # a candidate (the Bikezone shape).
  defp mismatch_recon do
    b = books(%{"invoice_number" => "1134"})
    g = g2b(%{"invoice_number" => "CHN-SER-1134"})
    Recon.reconcile([b], [g])
  end

  defp ref(recon) do
    [entry] = recon["needs_human"]
    entry["candidates"] |> List.first() |> Recon.gstr2b_ref()
  end

  test "no resolutions re-derives the same buckets" do
    recon = mismatch_recon()
    result = Workings.materialize(recon, [])

    assert length(result["needs_human"]) == 1
    assert result["matched"] == []
  end

  test "confirm_pair moves the exception into matched" do
    recon = mismatch_recon()

    result =
      Workings.materialize(recon, [
        %{
          "verb" => "confirm_pair",
          "books_id" => "page_01",
          "gstr2b_ref" => ref(recon),
          "payload" => %{}
        }
      ])

    assert [row] = result["matched"]
    assert row["books"]["id"] == "page_01"
    assert "human_confirmed" in row["match_basis"]
    assert result["needs_human"] == []
    assert result["in_2b_not_books"] == []
  end

  test "reject_pair keeps it unmatched and drops the candidate" do
    recon = mismatch_recon()

    result =
      Workings.materialize(recon, [
        %{
          "verb" => "reject_pair",
          "books_id" => "page_01",
          "gstr2b_ref" => ref(recon),
          "payload" => %{}
        }
      ])

    assert [entry] = result["needs_human"]
    assert entry["candidates"] == []
    assert result["matched"] == []
  end

  test "correct_field lets the real engine auto-match" do
    recon = mismatch_recon()

    result =
      Workings.materialize(recon, [
        %{
          "verb" => "correct_field",
          "books_id" => "page_01",
          "gstr2b_ref" => nil,
          "payload" => %{"field" => "invoice_number", "from" => "1134", "to" => "CHN-SER-1134"}
        }
      ])

    assert [row] = result["matched"]
    assert "invoice_number" in row["match_basis"]
    refute "human_confirmed" in row["match_basis"]
  end

  test "latest resolution wins: reject then confirm ends matched" do
    recon = mismatch_recon()
    r = ref(recon)

    result =
      Workings.materialize(recon, [
        %{"verb" => "reject_pair", "books_id" => "page_01", "gstr2b_ref" => r, "payload" => %{}},
        %{"verb" => "confirm_pair", "books_id" => "page_01", "gstr2b_ref" => r, "payload" => %{}}
      ])

    assert [_] = result["matched"]
  end

  test "confirming a 2B already machine-matched to another books row never double-counts it" do
    # A and B are two different books invoices. A matches 2B X exactly (engine).
    # B is a near-miss that lands in needs_human with X as candidate. Human
    # confirms B <-> X. X must end up matched to exactly ONE books row, and the
    # displaced row must not vanish.
    a = books(%{"id" => "a", "invoice_number" => "CHN-SER-1134"})
    b = books(%{"id" => "b", "invoice_number" => "1134"})
    x = g2b(%{"invoice_number" => "CHN-SER-1134"})

    recon = Recon.reconcile([a, b], [x])
    # A auto-matched X; B fell to in_books_not_2b (X was consumed).
    assert [matched_row] = recon["matched"]
    assert get_in(matched_row, ["books", "id"]) == "a"
    r = Recon.gstr2b_ref(matched_row["gstr2b"])

    result =
      Workings.materialize(recon, [
        %{"verb" => "confirm_pair", "books_id" => "b", "gstr2b_ref" => r, "payload" => %{}}
      ])

    # X matched to exactly one books row (b), and a is not lost.
    matched_books = Enum.map(result["matched"], &get_in(&1, ["books", "id"]))
    assert matched_books == ["b"]
    all_books = Workings.books_invoices(result) |> Enum.map(& &1["id"]) |> Enum.sort()
    assert all_books == ["a", "b"]
    assert "a" in Enum.map(result["in_books_not_2b"], &get_in(&1, ["books", "id"]))
  end

  test "a confirm also rejected is ignored" do
    recon = mismatch_recon()
    r = ref(recon)

    result =
      Workings.materialize(recon, [
        %{"verb" => "confirm_pair", "books_id" => "page_01", "gstr2b_ref" => r, "payload" => %{}},
        %{"verb" => "reject_pair", "books_id" => "page_01", "gstr2b_ref" => r, "payload" => %{}}
      ])

    assert result["matched"] == []
    assert [entry] = result["needs_human"]
    assert entry["candidates"] == []
  end
end
