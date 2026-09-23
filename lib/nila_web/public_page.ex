defmodule NilaWeb.PublicPage do
  @moduledoc "Build-time React pages served as HTML, with request-specific form values."
  import Plug.Conn
  import Phoenix.Controller, only: [html: 2]

  def render(conn, page, changeset \\ nil) do
    {content, styles} = content(page)

    errors =
      if changeset && changeset.action do
        changeset
        |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
          Enum.reduce(opts, message, fn {key, value}, text ->
            String.replace(text, "%{#{key}}", to_string(value))
          end)
        end)
        |> Enum.map_join("\n", fn {field, messages} ->
          "#{String.capitalize(to_string(field))}: #{Enum.join(messages, ", ")}"
        end)
      else
        ""
      end

    replacements = %{
      "__NILA_CSRF__" => Plug.CSRFProtection.get_csrf_token(),
      "__NILA_FLASH__" =>
        Enum.map_join(conn.assigns[:flash] || %{}, "\n", fn {_, text} -> text end),
      "__NILA_ERRORS__" => errors,
      "__NILA_NAME__" => value(changeset, :name),
      "__NILA_FIRM__" => value(changeset, :firm),
      "__NILA_PHONE__" => value(changeset, :phone)
    }

    body =
      Regex.replace(~r/__NILA_(?:CSRF|FLASH|ERRORS|NAME|FIRM|PHONE)__/, content["body"], fn key ->
        escape(replacements[key])
      end)

    path = if page == "home", do: "/", else: "/" <> String.replace(page, "_", "-")

    document = """
    <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <title>#{escape(content["title"])}</title><meta name="description" content="#{escape(content["description"])}">
    <link rel="canonical" href="https://nila.tax#{path}"><meta property="og:title" content="#{escape(content["title"])}"><meta property="og:description" content="#{escape(content["description"])}">
    <meta property="og:type" content="website"><meta property="og:url" content="https://nila.tax#{path}">
    <link rel="icon" href="/favicon.ico">#{styles}</head><body>#{body}#{animation_script(page)}</body></html>
    """

    conn |> put_resp_header("cache-control", "no-store") |> html(document)
  end

  defp content(page) do
    case Application.get_env(:nila, :vite_origin) do
      origin when is_binary(origin) ->
        response = Req.get!(origin <> "/__public/" <> page)
        if response.status != 200, do: raise("Public page preview failed: #{response.status}")
        {response.body, ~s(<link rel="stylesheet" href="#{origin}/src/index.css">)}

      nil ->
        root = Application.app_dir(:nila, "priv/static/frontend")
        pages = root |> Path.join("public-pages.json") |> File.read!() |> Jason.decode!()
        index = root |> Path.join("index.html") |> File.read!()

        styles =
          Regex.scan(~r/<link[^>]+rel="stylesheet"[^>]*>/, index) |> List.flatten() |> Enum.join()

        {Map.fetch!(pages, page), styles}
    end
  end

  defp animation_script("home") do
    case Application.get_env(:nila, :vite_origin) do
      origin when is_binary(origin) ->
        ~s(<script type="module" src="#{origin}/src/public/animate.ts"></script>)

      nil ->
        manifest =
          Application.app_dir(:nila, "priv/static/frontend/.vite/manifest.json")
          |> File.read!()
          |> Jason.decode!()

        file = manifest["src/public/animate.ts"]["file"]
        ~s(<script type="module" src="/frontend/#{file}"></script>)
    end
  end

  defp animation_script(_page), do: ""

  defp value(nil, _field), do: ""
  defp value(changeset, field), do: Ecto.Changeset.get_field(changeset, field) || ""
  defp escape(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
