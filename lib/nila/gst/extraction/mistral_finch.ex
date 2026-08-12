defmodule Nila.Gst.Extraction.MistralFinch do
  @moduledoc false

  @conn_max_idle_time :timer.seconds(30)

  @doc false
  def child_spec(_opts) do
    # This is deliberately narrower than a general "one Finch per provider"
    # policy. Nila's Mistral traffic reproduced a specific HTTP/1 failure:
    # Req.Finch checked out a connection idle for 40 minutes, sent the OCR body,
    # received no TCP packets at all, retransmitted, and eventually returned
    # `:closed`; the identical request over a fresh pool succeeded immediately.
    #
    # Finch cannot always observe that a peer, load balancer, NAT, or changed
    # network path has silently dropped its side of an idle socket. A finite
    # connection idle time makes Finch discard that socket during checkout and
    # establish a fresh one before sending bill data into it. Thirty seconds is
    # negligible next to an OCR call and intentionally changes no pool sizing or
    # concurrency behaviour.
    Supervisor.child_spec(
      {Finch, name: __MODULE__, pools: %{default: [conn_max_idle_time: @conn_max_idle_time]}},
      id: __MODULE__
    )
  end

  @doc false
  def req_options, do: [finch: [name: __MODULE__]]

  @doc false
  def conn_max_idle_time, do: @conn_max_idle_time
end
