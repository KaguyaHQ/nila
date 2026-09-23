defmodule NilaWeb.WorkspaceNavigation do
  @moduledoc "Validated navigation memory shared by React and server-rendered routes."
  import Plug.Conn
  alias Nila.Clients
  @cookie "nila_workspace"
  def init(opts), do: opts
  def call(conn, :remember_path), do: remember_path(conn, [])

  def read(conn, scope) do
    conn = fetch_cookies(conn, signed: [@cookie])

    with %{user: %{id: user}, current_org: %{id: org}} <- scope,
         %{"user" => ^user, "org" => ^org, "workspace" => workspace} <- conn.cookies[@cookie],
         {:ok, workspace} <- validate(scope, workspace) do
      {conn, workspace}
    else
      _ -> {conn, nil}
    end
  end

  def validate(%{user: %{}, current_org: %{id: org}}, %{
        "clientId" => id,
        "period" => period,
        "section" => section
      })
      when is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807 and is_binary(period) and
             section in ["sales", "purchases"] do
    with true <- Regex.match?(~r/\A\d{4}-\d{2}\z/, period),
         {:ok, date} <- Date.from_iso8601(period <> "-01"),
         true <- date.year >= 2017,
         {:ok, _client} <- Clients.get_client(org, id) do
      {:ok, %{"clientId" => id, "period" => period, "section" => section}}
    else
      _ -> {:error, :invalid_workspace}
    end
  end

  def validate(_, _), do: {:error, :invalid_workspace}

  def put(conn, scope, workspace) do
    conn
    |> put_session(:current_client_id, workspace["clientId"])
    |> put_session(:workspace_navigation, workspace)
    |> put_resp_cookie(
      @cookie,
      %{"user" => scope.user.id, "org" => scope.current_org.id, "workspace" => workspace},
      sign: true,
      http_only: true,
      same_site: "Lax",
      secure: conn.scheme == :https,
      max_age: 60 * 60 * 24 * 60,
      path: "/"
    )
  end

  def from_path(path) do
    case Regex.run(~r/\A(?:\/app)?\/gst\/(\d+)\/(\d{4}-\d{2})\/(sales|purchases)(?:\/|$)/, path) do
      [_, id, period, section] ->
        %{"clientId" => String.to_integer(id), "period" => period, "section" => section}

      _ ->
        nil
    end
  end

  def path(workspace),
    do: "/app/gst/#{workspace["clientId"]}/#{workspace["period"]}/#{workspace["section"]}"

  def home(conn, scope) do
    {conn, workspace} = read(conn, scope)
    {conn, if(workspace, do: path(workspace), else: "/app/clients")}
  end

  def remember_path(conn, _opts) do
    scope = conn.assigns[:current_scope]

    with "GET" <- conn.method,
         {:ok, workspace} <- validate(scope, from_path(conn.request_path)) do
      {:ok, client} = Clients.get_client(scope.current_org.id, workspace["clientId"])

      conn
      |> put(scope, workspace)
      |> assign(:current_scope, %{scope | current_client: client, workspace_navigation: workspace})
    else
      _ -> conn
    end
  end
end
