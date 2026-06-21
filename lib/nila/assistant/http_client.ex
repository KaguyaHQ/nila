defmodule Nila.Assistant.HTTPClient do
  @moduledoc """
  HTTP seam for an OpenAI-compatible chat completions API. Lets tests inject
  a stub without taking on Mox as a dependency.
  """

  @callback post(url :: String.t(), body :: map(), headers :: map()) ::
              {:ok, %{status: integer(), body: map()}} | {:error, term()}

  @doc """
  POST a streaming (SSE) request, folding each event through `reducer`.

  `reducer` receives `(event, acc)` and returns the next accumulator, exactly
  like `Enum.reduce/3`. The final accumulator is returned alongside the
  response so callers never reach for the process dictionary.
  """
  @callback post_stream(
              url :: String.t(),
              body :: map(),
              headers :: map(),
              acc :: term(),
              reducer :: (map() | :done, term() -> term())
            ) ::
              {:ok, %{status: integer(), body: map()}, term()} | {:error, term()}

  def impl, do: Application.fetch_env!(:nila, Nila.Assistant) |> Keyword.fetch!(:http_client)
end
