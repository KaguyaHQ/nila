defmodule Nila.Eval.SourceQualityTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Nila.Eval.SourceQuality
  alias Nila.Gst.Extraction.Transcription

  test "reports pages worst-first by all-word average with unknown pages last" do
    transcription = %Transcription{
      pages: %{
        1 => page(1, 0.99),
        2 => page(2, 0.75),
        3 => page(3, nil)
      }
    }

    assert Enum.map(SourceQuality.pages(transcription), & &1["page"]) == [2, 1, 3]
  end

  test "aggregates top-level and nested table words" do
    transcription = %Transcription{
      pages: %{
        1 => %{
          number: 1,
          markdown: "",
          confidence: %{
            "average_page_confidence_score" => 0.85,
            "word_confidence_scores" => [
              %{"confidence" => 0.9},
              %{"confidence" => 0.8}
            ]
          },
          tables: [
            %{
              "word_confidence_scores" => [
                %{"confidence" => 0.6},
                %{"confidence" => 0.4},
                %{"confidence" => 0.2}
              ]
            }
          ]
        }
      }
    }

    assert [page] = SourceQuality.pages(transcription)
    assert page["provider_average_confidence_score"] == 0.85
    assert page["all_word_count"] == 5
    assert_in_delta page["all_word_average_confidence_score"], 0.58, 1.0e-12
    assert page["all_word_p10_confidence_score"] == 0.2
    assert_in_delta page["under_70_word_share"], 0.6, 1.0e-12
  end

  test "ignores out-of-range provider averages and preserves numeric endpoints" do
    transcription = %Transcription{
      pages: %{
        1 =>
          page(1, 1)
          |> put_in([:confidence, "average_page_confidence_score"], 1.2)
      }
    }

    assert [page] = SourceQuality.pages(transcription)
    assert page["provider_average_confidence_score"] == nil
    assert page["all_word_average_confidence_score"] == 1
    assert page["all_word_p10_confidence_score"] == 1
  end

  test "ignores malformed and out-of-range optional confidence telemetry" do
    transcription = %Transcription{
      pages: %{
        1 => %{
          number: 1,
          markdown: "",
          confidence: "broken",
          tables: [
            nil,
            %{
              "word_confidence_scores" => [
                "broken",
                %{"confidence" => "high"},
                %{"confidence" => -0.1},
                %{"confidence" => 0.6},
                %{"confidence" => 1.1}
              ]
            }
          ]
        }
      }
    }

    assert [page] = SourceQuality.pages(transcription)
    assert page["provider_average_confidence_score"] == nil
    assert page["all_word_count"] == 1
    assert page["all_word_average_confidence_score"] == 0.6
  end

  test "the task formats integer confidence endpoints" do
    dir =
      Path.join(System.tmp_dir!(), "nila-source-quality-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    File.write!(Path.join(dir, "meta.json"), Jason.encode!(%{"document" => "fixture"}))

    File.write!(
      Path.join(dir, "raw.json"),
      Jason.encode!(%{
        "pages" => [
          %{
            "index" => 0,
            "confidence_scores" => %{
              "average_page_confidence_score" => 1,
              "word_confidence_scores" => [
                %{"text" => "low", "confidence" => 0},
                %{"text" => "high", "confidence" => 1}
              ]
            }
          }
        ]
      })
    )

    output =
      capture_io(fn ->
        Mix.Tasks.Nila.Eval.run([
          "source-quality",
          "fixture",
          "--transcription-attempt",
          dir
        ])
      end)

    assert output =~ "100.00%"
    assert output =~ "50.00%"
    assert output =~ "0.00%"
  end

  test "loads the explicitly selected cached attempt" do
    dir =
      Path.join(System.tmp_dir!(), "nila-source-quality-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(Path.join(dir, "meta.json"), Jason.encode!(%{"document" => "fixture"}))

    File.write!(
      Path.join(dir, "raw.json"),
      Jason.encode!(%{
        "pages" => [
          %{
            "index" => 6,
            "confidence_scores" => %{
              "average_page_confidence_score" => 0.8,
              "word_confidence_scores" => [
                %{"text" => "invoice", "confidence" => 0.7},
                %{"text" => "total", "confidence" => 0.9}
              ]
            }
          }
        ]
      })
    )

    assert {:ok, report} = SourceQuality.report("fixture", transcription_attempt: dir)

    assert report.attempt == dir

    assert [page] = report.pages
    assert page["page"] == 7
    assert page["provider_average_confidence_score"] == 0.8
    assert page["all_word_average_confidence_score"] == 0.8
    assert page["all_word_p10_confidence_score"] == 0.7
    assert page["under_70_word_share"] == 0.0
    assert page["all_word_count"] == 2
  end

  test "rejects an explicit attempt from another document" do
    dir =
      Path.join(System.tmp_dir!(), "nila-source-quality-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    File.write!(Path.join(dir, "meta.json"), Jason.encode!(%{"document" => "other"}))

    assert {:error, {:transcription_attempt_mismatch, "fixture", "other"}} =
             SourceQuality.report("fixture", transcription_attempt: dir)
  end

  test "returns an error for a missing selected attempt" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "missing-nila-source-quality-#{System.unique_integer([:positive])}"
      )

    assert {:error, :enoent} =
             SourceQuality.report("attempt-name-is-unused", transcription_attempt: dir)
  end

  defp page(number, score) do
    %{
      number: number,
      markdown: "",
      tables: [],
      confidence: %{
        "average_page_confidence_score" => score,
        "word_confidence_scores" => if(score, do: [%{"confidence" => score}], else: [])
      }
    }
  end
end
