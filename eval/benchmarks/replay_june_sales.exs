Code.require_file("../support/sales_replay.exs", __DIR__)

case System.argv() do
  [source, destination] ->
    Nila.Eval.SalesReplay.run(source, destination)

  _ ->
    raise "Usage: mix run --no-start eval/benchmarks/replay_june_sales.exs SAVED_RUN OUTPUT_DIR"
end
