defmodule Nila.Eval.SourceQualityFixtureTest do
  use ExUnit.Case, async: true

  @fixture "eval/source_quality/breeze-2025-10-purchase.json"

  test "pins the partial blind human source-quality review" do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    pages = fixture["pages"]

    assert fixture["version"] == 1
    assert fixture["document"] == "breeze-2025-10-purchase"

    assert fixture["document_sha256"] ==
             "c4c9982b0c0f6e02386d6ae0f4a612aee822a0fc4a34b9349869f9ff6d786d5b"

    refute fixture["complete"]
    assert fixture["reviewed_pages"] == 40
    assert fixture["total_pages"] == 57
    assert Enum.map(pages, & &1["page"]) == Enum.to_list(1..40)

    assert Enum.frequencies_by(pages, & &1["visual_quality"]) == %{
             "degraded" => 14,
             "good" => 25,
             "unusable" => 1
           }

    assert Enum.frequencies_by(pages, & &1["critical_readability"]) == %{
             "comfortable" => 24,
             "effortful" => 8,
             "unreliable" => 8
           }

    assert Enum.all?(pages, fn page ->
             page["visual_quality"] in ~w(good degraded unusable) and
               page["critical_readability"] in ~w(comfortable effortful unreliable)
           end)

    assert Enum.find(pages, &(&1["page"] == 5))
           |> Map.take(["visual_quality", "critical_readability"]) ==
             %{"visual_quality" => "good", "critical_readability" => "unreliable"}

    assert Enum.find(pages, &(&1["page"] == 10))
           |> Map.take(["visual_quality", "critical_readability"]) ==
             %{"visual_quality" => "unusable", "critical_readability" => "unreliable"}
  end
end
