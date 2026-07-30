defmodule Nila.Eval.AdjudicationsTest do
  use ExUnit.Case, async: true

  alias Nila.Eval.Adjudications

  defp entry(overrides \\ %{}) do
    Map.merge(
      %{
        "scope" => "invoice_item",
        "key" => "33AABCP9487A1ZG|1|18",
        "field" => "txval",
        "filed" => 1000,
        "verdict" => "AUDITOR",
        "note" => "auditor rounds the bucket"
      },
      overrides
    )
  end

  defp write!(entries) do
    dir = Path.join(System.tmp_dir!(), "adj_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "x.json")
    File.write!(path, Jason.encode!(entries))
    on_exit(fn -> File.rm_rf(dir) end)
    path
  end

  defp load!(entries) do
    entries |> write!() |> File.read!() |> Jason.decode!() |> index()
  end

  # Mirrors `load/2`'s private indexing so validation can be tested without
  # writing into eval/.
  defp index(entries) do
    Map.new(entries, &{{&1["scope"], &1["key"], &1["field"]}, &1})
  end

  describe "verdict/2" do
    test "matches a row on scope, key and field" do
      row = %{
        "scope" => "invoice_item",
        "key" => "33AABCP9487A1ZG|1|18",
        "field" => "txval",
        "filed" => 1000
      }

      assert %{"verdict" => "AUDITOR"} = Adjudications.verdict(load!([entry()]), row)
    end

    test "an unadjudicated row has no verdict" do
      row = %{"scope" => "hsn", "key" => "998314|18", "field" => "txval", "filed" => 1000}

      assert Adjudications.verdict(load!([entry()]), row) == nil
    end

    test "a verdict stops applying once the filed value moves" do
      row = %{
        "scope" => "invoice_item",
        "key" => "33AABCP9487A1ZG|1|18",
        "field" => "txval",
        "filed" => 2000
      }

      assert Adjudications.verdict(load!([entry()]), row) == nil,
             "a verdict describes a value someone looked at, not a field path"
    end
  end

  describe "fixes/1" do
    test "flattens OCR_MISREAD fixes, single or list, and ignores other verdicts" do
      fix = %{
        "verb" => "correct_field",
        "target" => "1",
        "payload" => %{"field" => "line_items[0].taxable_value", "from" => 900, "to" => 1000}
      }

      second = put_in(fix, ["payload", "field"], "line_items[1].taxable_value")

      index =
        load!([
          entry(),
          entry(%{"key" => "a|2|18", "verdict" => "OCR_MISREAD", "fix" => fix}),
          entry(%{"key" => "a|3|18", "verdict" => "OCR_MISREAD", "fix" => [fix, second]})
        ])

      fixes = Adjudications.fixes(index)

      assert length(fixes) == 3
      assert Enum.all?(fixes, &(&1["verb"] == "correct_field"))
    end
  end

  describe "load/2 validation" do
    test "rejects an unknown verdict" do
      path = write!([entry(%{"verdict" => "PROBABLY_FINE"})])

      assert_raise ArgumentError, ~r/unknown verdict/, fn ->
        Adjudications.load_path(path)
      end
    end

    test "rejects OCR_MISREAD without a fix" do
      path = write!([entry(%{"verdict" => "OCR_MISREAD"})])

      assert_raise ArgumentError, ~r/needs a fix/, fn -> Adjudications.load_path(path) end
    end

    test "rejects a fix on a verdict that must not carry one" do
      fix = %{"verb" => "correct_field", "target" => "1", "payload" => %{"field" => "x"}}
      path = write!([entry(%{"verdict" => "OUR_BUG", "fix" => fix})])

      assert_raise ArgumentError, ~r/papers over the bug/, fn -> Adjudications.load_path(path) end
    end

    test "rejects a fix that is not a correct_field resolution" do
      fix = %{"verb" => "confirm_issue", "target" => "1", "payload" => %{"field" => "x"}}
      path = write!([entry(%{"verdict" => "OCR_MISREAD", "fix" => fix})])

      assert_raise ArgumentError, ~r/must be a correct_field/, fn ->
        Adjudications.load_path(path)
      end
    end

    test "rejects a fix missing the input-side field path" do
      fix = %{"verb" => "correct_field", "target" => "1", "payload" => %{}}
      path = write!([entry(%{"verdict" => "OCR_MISREAD", "fix" => fix})])

      assert_raise ArgumentError, ~r/payload.field/, fn -> Adjudications.load_path(path) end
    end

    test "an unadjudicated month loads as empty rather than failing" do
      assert Adjudications.load("nobody", "1999-01") == %{}
    end
  end
end
