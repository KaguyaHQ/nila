defmodule NilaWeb.GoTo do
  @moduledoc false

  def sales_home(%{id: client_id}) do
    "/app/gst/#{client_id}/#{period(nil, nil)}/sales"
  end

  def sales_home(_client), do: "/app/clients"

  def period(path, fallback) do
    uri = URI.parse(path || "")

    candidate =
      case Regex.run(~r"^/gst/\d+/(\d{4}-\d{2})(?:/|$)", uri.path || "") do
        [_, value] -> value
        _ -> URI.decode_query(uri.query || "")["period"] || fallback
      end

    case Date.from_iso8601("#{candidate}-01") do
      {:ok, date} -> Calendar.strftime(date, "%Y-%m")
      _ -> Nila.Gst.Filing.Calendar.closeable_period(Date.utc_today())
    end
  end

  def period_label(period), do: Calendar.strftime(Date.from_iso8601!(period <> "-01"), "%B %Y")

  def client_path(path, fallback, client_id) do
    current_period = period(path, fallback)
    uri = URI.parse(path || "")

    cond do
      uri.path == "/gst/upload" ->
        "/gst/upload?" <>
          URI.encode_query(%{
            "client_id" => client_id,
            "period" => current_period,
            "kind" => URI.decode_query(uri.query || "")["kind"] || "sales"
          })

      String.ends_with?(uri.path || "", "/sales/invoices") ->
        filter = URI.decode_query(uri.query || "")["filter"]
        base = "/gst/#{client_id}/#{current_period}/sales/invoices"

        if filter in ~w(all review_cases no_open_checks),
          do: base <> "?" <> URI.encode_query(%{filter: filter}),
          else: base

      true ->
        "/gst/#{client_id}/#{current_period}/sales"
    end
  end

  def destinations(client, path, fallback) do
    current = period(path, fallback)
    base = "/gst/#{client.id}/#{current}/sales"
    context = client.name <> " · " <> period_label(current)

    pages =
      [
        {"overview", "Period overview", base, "gst gstr-1 workings", context},
        {"register", "Sales register", base <> "/invoices", "sales bills invoices", context},
        {"upload", "Bring in invoices",
         "/gst/upload?" <>
           URI.encode_query(%{"client_id" => client.id, "period" => current, "kind" => "sales"}),
         "upload invoices", context},
        {"clients", "Client directory", "/clients", "clients", nil}
      ]
      |> Enum.map(fn {id, label, path, keywords, context} ->
        %{
          id: id,
          label: label,
          path: path,
          context: context,
          keywords: keywords,
          group: "Pages",
          heading: nil,
          period: nil,
          suggested: false
        }
      end)
      |> heading("Pages")

    date = Date.from_iso8601!(current <> "-01")

    suggestions = [
      Date.add(date, 32) |> Date.beginning_of_month(),
      date,
      Date.add(date, -1) |> Date.beginning_of_month()
    ]

    # One link per month. The browser can replace its year without changing
    # the client or destination supplied by Phoenix.
    months = suggestions ++ Enum.map(12..1//-1, &Date.new!(date.year, &1, 1))

    periods =
      months
      |> Enum.uniq_by(& &1.month)
      |> Enum.map(fn date ->
        value = Calendar.strftime(date, "%Y-%m")

        %{
          id: "period-#{date.month}",
          label: period_label(value),
          path: String.replace(client_path(path, fallback, client.id), current, value),
          context: client.name,
          keywords: value,
          group: "Periods",
          heading: nil,
          period: value,
          suggested: date in suggestions
        }
      end)
      |> heading("Periods")

    pages ++ periods
  end

  defp heading([], _), do: []
  defp heading([first | rest], title), do: [%{first | heading: title} | rest]
end
