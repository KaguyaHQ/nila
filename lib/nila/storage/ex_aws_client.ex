defmodule Nila.Storage.ExAwsClient do
  @moduledoc """
  ExAws HTTP client backed by `Req`.

  Wraps `ExAws.Request.Req` to drop empty request bodies. Req >= 0.7 rewrites a
  GET into a POST whenever `:body` is non-nil, and ex_aws always passes `""`,
  which turns every S3 read into a POST.
  """

  @behaviour ExAws.Request.HttpClient

  @impl true
  def request(method, url, body \\ "", headers \\ [], http_opts \\ []) do
    ExAws.Request.Req.request(method, url, normalize_body(body), headers, http_opts)
  end

  defp normalize_body(""), do: nil
  defp normalize_body(body), do: body
end
