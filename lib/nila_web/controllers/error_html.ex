defmodule NilaWeb.ErrorHTML do
  @moduledoc "Static React error documents, independent of the application and Vite at runtime."

  def render(template, _assigns) when template in ["404.html", "500.html"] do
    status = String.trim_trailing(template, ".html")
    path = Application.app_dir(:nila, "priv/static/frontend/error-#{status}.html")

    case File.read(path) do
      {:ok, document} -> Phoenix.HTML.raw(document)
      {:error, _reason} -> Phoenix.Controller.status_message_from_template(template)
    end
  end

  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end
