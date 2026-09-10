defmodule Mix.Tasks.Nila.EvalTest do
  use ExUnit.Case, async: true

  test "retired OCR commands are rejected before starting the application" do
    for command <- ~w(extract score segment stability source-quality) do
      assert_raise Mix.Error, ~r/unknown command/, fn ->
        Mix.Tasks.Nila.Eval.run([command, "example"])
      end
    end
  end

  test "vision experiments reject missing pages and invalid run counts" do
    assert_raise Mix.Error, "vision-schema requires --pages", fn ->
      Mix.Tasks.Nila.Eval.run(["vision-schema", "example"])
    end

    assert_raise Mix.Error, "--runs must be positive", fn ->
      Mix.Tasks.Nila.Eval.run(["vision-schema-batch", "example", "--runs", "0"])
    end
  end
end
