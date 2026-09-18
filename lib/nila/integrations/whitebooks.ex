defmodule Nila.Integrations.Whitebooks do
  @moduledoc """
  Whitebooks GST API: taxpayer lookup, authentication, and notices.

  Returns the successful provider envelope unchanged. Notice and authentication
  payloads must be mapped from verified responses, not inferred from field names.
  HTTP 200 alone does not mean success: Whitebooks uses `status_cd` in the body.
  """

  @base_url "https://api.whitebooks.in"

  def search_taxpayer(gstin), do: request("/public/search", [gstin: gstin], %{}, public?: true)

  def taxpayer_facts(
        %{"data" => %{"gstin" => gstin, "lgnm" => name, "sts" => status} = data},
        gstin
      )
      when is_binary(name) and is_binary(status) do
    trade_name = data["tradeNam"]

    if String.trim(name) != "" and String.trim(status) != "" and
         (is_nil(trade_name) or is_binary(trade_name)) do
      {:ok,
       %{
         legal_name: String.trim(name),
         trade_name: trade_name,
         registration_status: String.trim(status),
         # Keep taxpayer evidence only, never credentials or auth envelopes.
         payload:
           Map.take(data, ~w(gstin lgnm tradeNam sts rgdt cxdt dty ctb stj ctj pradr adadr nba))
       }}
    else
      {:error, :unexpected_response}
    end
  end

  def taxpayer_facts(_, _), do: {:error, :unexpected_response}

  def request_otp(account), do: request("/authentication/otprequest", [], account)

  def authenticate(account, otp),
    do: request("/authentication/authtoken", [otp: otp], account, session?: true)

  def refresh(account),
    do: request("/authentication/refreshtoken", [], account, session?: true)

  def list_notices(account, %Date{} = date) do
    request(
      "/notices/noticelist",
      [gstin: account.gstin, date: Calendar.strftime(date, "%d/%m/%Y")],
      account,
      session?: true
    )
  end

  def notice_details(account, reference) do
    request("/notices/noticedetails", [gstin: account.gstin, refId: reference], account,
      session?: true
    )
  end

  def download_document(account, document_id, %Date{} = issued_on) do
    request(
      "/all/docdwld",
      [gstin: account.gstin, id: document_id, retperiod: Calendar.strftime(issued_on, "%m%Y")],
      account,
      session?: true
    )
  end

  defp request(path, params, account, opts \\ []) do
    config = Application.get_env(:nila, __MODULE__, [])

    with :ok <- configured(config),
         {:ok, headers} <- account_headers(account, opts) do
      headers =
        headers ++
          [
            {"accept", "application/json"},
            {"client_id", config[:client_id]},
            {"client_secret", config[:client_secret]}
          ]

      options =
        Keyword.merge(config[:req_options] || [],
          headers: headers,
          params: Keyword.put(params, :email, config[:email]),
          # OTP requests have side effects despite being GETs. Let the user retry.
          retry: false,
          redirect: false,
          receive_timeout: 30_000
        )

      case Req.get((config[:base_url] || @base_url) <> path, options) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          result(body)

        {:ok, %{status: status}} ->
          {:error, {:http, status}}

        {:error, _reason} ->
          # Transport errors can contain a URL with an OTP. Never propagate it.
          {:error, :unavailable}
      end
    end
  end

  defp configured(config) do
    if Enum.all?([:client_id, :client_secret, :email], &present?(config[&1])),
      do: :ok,
      else: {:error, :not_configured}
  end

  defp account_headers(_account, public?: true), do: {:ok, []}

  defp account_headers(account, opts) do
    fields = [:gstin, :username, :ip_address] ++ if(opts[:session?], do: [:txn], else: [])

    if Enum.all?(fields, &present?(Map.get(account, &1))) and
         Regex.match?(~r/^\d{2}[A-Z0-9]{13}$/, account.gstin) do
      headers = [
        {"gst_username", account.username},
        {"state_cd", String.slice(account.gstin, 0, 2)},
        {"ip_address", account.ip_address}
      ]

      {:ok, if(opts[:session?], do: headers ++ [{"txn", account.txn}], else: headers)}
    else
      {:error, :invalid_account}
    end
  end

  defp result(%{"status_cd" => "1"} = body), do: {:ok, body}

  defp result(%{"status_cd" => "0", "error" => %{"errorCode" => code}})
       when is_binary(code) do
    if Regex.match?(~r/^[A-Z][A-Z0-9_]{1,63}$/, code),
      do: {:error, {:provider, code}},
      else: {:error, :unexpected_response}
  end

  defp result(%{"status_cd" => "0", "status_desc" => description}) do
    # Keep only the provider code: descriptions may echo supplied credentials.
    code =
      if is_binary(description),
        do: Regex.run(~r/\b(?:WB_ERR_\d+|[A-Z]+\d{3,})\b/, description),
        else: nil

    {:error, {:provider, if(code, do: hd(code), else: "unknown")}}
  end

  defp result(_body), do: {:error, :unexpected_response}

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
