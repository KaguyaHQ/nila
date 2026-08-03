defmodule Nila.Gst.Hsn.DescriptionSignalTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Hsn.DescriptionSignal

  defp line(printed, official) do
    %{"description" => printed, "hsn_sac" => "998719", "hsn_description" => official}
  end

  describe "score_line/1" do
    test "inflected wording still matches — tariff headings and bills conjugate differently" do
      result =
        line("Refrigeration unit spare parts", "Parts of refrigerating equipment")
        |> DescriptionSignal.score_line()

      assert result.shared > 0
      assert result.score > 0.3
    end

    test "the measure cannot yet separate a real match from a colloquial one" do
      # This is the finding that keeps the signal dark, and it is worth stating
      # as an assertion rather than a hope. "AC service" is a perfectly correct
      # description of machinery maintenance, and it scores identically to a
      # genuine wording match. Promoting this to `advisory` — let alone
      # `required` — on the strength of the current measure would withhold
      # filings over a naming style.
      genuine =
        line("Refrigeration unit spare parts", "Parts of refrigerating equipment")
        |> DescriptionSignal.score_line()

      colloquial =
        line("AC service", "Maintenance and repair services of machinery and equipment")
        |> DescriptionSignal.score_line()

      assert colloquial.score == genuine.score
    end

    test "nothing to compare is nil, not a zero score" do
      refute DescriptionSignal.score_line(%{"description" => "Widget"})
      refute DescriptionSignal.score_line(%{"hsn_description" => "Official"})
      refute DescriptionSignal.score_line(line("", "Official wording"))

      # Grammatical filler only: no usable signal either way, and calling that a
      # conflict would be inventing evidence.
      refute DescriptionSignal.score_line(line("and of the", "Parts of machinery"))
    end
  end

  describe "observe/2" do
    test "emits one measurement for the batch and returns the invoices untouched" do
      handler = {__MODULE__, :signal, self()}

      :telemetry.attach_many(
        handler,
        [DescriptionSignal.event()],
        fn event, measurements, metadata, pid ->
          send(pid, {:signal, event, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      invoices = [
        %{
          "invoice_number" => "S-1",
          "line_items" => [
            line("Refrigeration unit", "Parts of refrigerating equipment"),
            # Not comparable: no official wording to compare against.
            %{"description" => "Freight", "hsn_sac" => "9965"}
          ]
        }
      ]

      assert DescriptionSignal.observe(invoices, %{track: :sales}) == invoices

      assert_receive {:signal, _event, measurements, metadata}

      # One event for the month, not one per line: this runs on every page
      # render and telemetry handlers are synchronous.
      assert measurements.lines == 1
      assert is_float(measurements.mean_score)
      assert metadata.track == :sales

      # The per-line detail still travels, so a handler can score the corpus.
      assert [%{invoice: "S-1", official: "Parts of refrigerating equipment"}] = metadata.scored

      refute_receive {:signal, _event, _measurements, _metadata}
    end
  end

  describe "the staging contract" do
    test "the signal raises no issue and touches no line" do
      # Stage 1 is shadow. Precision has not been demonstrated, so nothing here
      # may reach a reviewer: no issue code, no annotation, no gating. The next
      # stage is advisory, and only after that, required.
      invoices = [
        %{
          "invoice_number" => "S-2",
          "line_items" => [line("AC service", "Maintenance and repair services of machinery")]
        }
      ]

      observed = DescriptionSignal.observe(invoices)

      assert observed == invoices

      # Nothing to compare means no event at all, rather than an event
      # reporting a zero nobody measured.
      assert DescriptionSignal.observe([%{"line_items" => [%{"description" => "Freight"}]}]) ==
               [%{"line_items" => [%{"description" => "Freight"}]}]

      refute Nila.Gst.Issues.known_codes() |> Enum.any?(&(&1 =~ "description_conflict"))
    end
  end
end
