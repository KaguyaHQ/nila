# Assistant latency

How to investigate why `Nila.Assistant` (NVIDIA Nemotron) takes N seconds to answer.

## TL;DR

`hello` round-trips in **6–19s** on `nvidia/nemotron-3-super-120b-a12b`. Three reasons, all upstream:

1. **Nemotron is a reasoning model.** Even a one-word reply ships 80–230 completion tokens, mostly hidden `reasoning_content` generated before any visible token.
2. **NVIDIA's "stream" is not a stream.** Every SSE chunk arrives at the end (`time_starttransfer` ≈ `time_total`). The streaming codepath in `lib/nila/assistant.ex` buys zero perceived latency.
3. **Variance is large.** Identical payload, three runs: 8.5s / 13.8s / 19.4s. Single samples mean nothing.

The "NVIDIA returned an answer N s" label in the LiveView trace is `elapsed_ms` measured around `call_api/2`. That's wall-clock for the round-trip, not BEAM overhead.

## Reproduce with curl

Confirms whether slowness is upstream vs. our code. Source `.env` for `NVIDIA_API_KEY`. The payload mirrors what `Nila.Assistant` sends: system prompt, the three tool schemas, `tool_choice: "auto"`.

```bash
set -a && source .env && set +a
curl -sS -w "\nTOTAL: %{time_total}s | TTFB: %{time_starttransfer}s\n" \
  -o /tmp/resp.json \
  -X POST "https://integrate.api.nvidia.com/v1/chat/completions" \
  -H "authorization: Bearer $NVIDIA_API_KEY" \
  -H "content-type: application/json" \
  -d @docs/runbooks/assistant-latency-payload.json
```

If `TOTAL` from curl is in the same band as the UI label, the latency is the NVIDIA endpoint and there's nothing to fix in our code. If curl is fast and the UI is slow, look at `call_stream_api/4` and the LiveView PubSub path.

For the streaming path add `"stream": true` to the JSON and `-N` to curl; the chunks still arrive at the end (that's NVIDIA's bug, not ours).

If you've changed the tool schemas in `lib/nila/assistant/tools.ex` since this runbook was last touched, regenerate the `"tools"` array from IEx:

```elixir
Nila.Assistant.Tools.specs()
|> Enum.map(fn s ->
  %{"type" => "function",
    "function" => %{"name" => s.name, "description" => s.description, "parameters" => s.input_schema}}
end)
|> Jason.encode!()
|> IO.puts()
```

Splice into the `"tools"` array in the JSON file.

## Knobs that actually help

In `config/config.exs` under `:nila, Nila.Assistant`:

- **Disable reasoning.** `extra_body: %{"chat_template_kwargs" => %{"thinking" => false}}`. Kills the chain-of-thought, which is the dominant cost. Trade-off is worse tool selection on ambiguous queries.
- **Swap model.** A smaller Nemotron or a non-reasoning model (Haiku 4.5, gpt-4o-mini, Groq Llama) returns `hello` in under 1s.
- **Lower `max_tokens`.** Currently 4096. Has no effect on short answers (model hits `stop` first); only matters when truncating long replies.

Prompt-size tweaks (shorter system prompt, fewer tools) don't help much because generation dominates, not prefill.

## What does NOT help

- Removing the streaming code. It's already free-running concurrently; the bottleneck is upstream generation.
- Caching prompts. NVIDIA's OpenAI-compatible endpoint doesn't expose cache control.
- Bumping `max_tool_iterations`. The loop already exits on `finish_reason: "stop"`.
