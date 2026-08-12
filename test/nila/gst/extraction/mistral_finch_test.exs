defmodule Nila.Gst.Extraction.MistralFinchTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Extraction.MistralFinch

  test "bounds the lifetime of idle Mistral connections" do
    assert %{start: {Finch, :start_link, [options]}} = MistralFinch.child_spec([])

    assert options[:name] == MistralFinch

    assert options[:pools] == %{
             default: [conn_max_idle_time: :timer.seconds(30)]
           }

    assert MistralFinch.req_options() == [finch: [name: MistralFinch]]
  end
end
