defmodule NilaWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs.

  `render_errors` is configured with `layout: false`, so the templates in
  `error_html/` carry their own document. They deliberately do not reach for the
  root layout, so an error page can still render if the public layout fails.
  """
  use NilaWeb, :html

  embed_templates "error_html/*"

  # Statuses without a template (403, 429, …) keep the plain text page derived
  # from the template name. Reached via `Phoenix.Template`'s fallback, which only
  # calls `render/2` when no function of the template's name exists.
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end

  # A garbage 2KB URL must not wreck the layout, and the error plug does not
  # always supply a conn — the dev preview route and `render_to_string/4` in
  # tests render these templates assign-less.
  @path_limit 72

  defp requested_path(assigns) do
    case assigns[:conn] do
      %Plug.Conn{request_path: path} when is_binary(path) and path != "" -> truncate(path)
      _ -> "—"
    end
  end

  defp truncate(path) do
    if String.length(path) > @path_limit,
      do: String.slice(path, 0, @path_limit) <> "…",
      else: path
  end

  # The error document: head, moonlight ground, and the centred column both
  # pages compose into.
  attr :page_title, :string, required: true
  slot :inner_block, required: true

  defp shell(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" data-theme="light">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="robots" content="noindex" />
        <title>{@page_title}</title>

        <%!-- Un-digested on purpose, same as the root layout: favicons want a
              constant URL and Plug.Static's `only` list allows these names. --%>
        <link rel="icon" href="/favicon.ico" sizes="32x32" />
        <link rel="icon" href="/favicon.svg" type="image/svg+xml" />
        <link rel="stylesheet" href={~p"/assets/css/app.css"} />
      </head>

      <body class="moonlight text-base-content">
        <main class="py-canvas mx-auto flex min-h-screen w-full max-w-xl flex-col justify-center px-4 sm:px-6">
          <.link href={~p"/"} class="hover:text-ink mb-canvas text-ink-subtle transition-colors">
            <.logo class="h-5 w-auto" />
          </.link>

          <div class="space-y-region">
            {render_slot(@inner_block)}
          </div>
        </main>
      </body>
    </html>
    """
  end

  # The status numeral, set in the display serif. `moon` gives the 404 the
  # display step; a 500 is our fault and takes the quieter one.
  attr :moon, :boolean, default: false
  slot :inner_block, required: true

  defp numeral(assigns) do
    ~H"""
    <p class={[
      "font-display flex items-baseline leading-none font-normal",
      (@moon && "text-base-content text-hero") || "text-h4 text-ink-subtle"
    ]}>
      {render_slot(@inner_block)}
    </p>
    """
  end

  # The 404's `0`, drawn as a crescent — Nila is the moon, and this is the one
  # screen where the brand pun gets to be literal. A masked cut-out rather than
  # an overlapping disc in the page color, because the ground behind it is a
  # gradient. Sized in `em` against the flanking digits: no utility can express
  # "the cap height of the font this inherits", and the parent's
  # `items-baseline` sets the disc on the digits' baseline.
  defp crescent(assigns) do
    ~H"""
    <svg
      viewBox="0 0 100 100"
      fill="currentColor"
      aria-hidden="true"
      style="width:0.68em;height:0.68em"
      phx-no-format
    >
      <mask id="nila-error-crescent">
        <circle cx="50" cy="50" r="49" fill="white" />
        <circle cx="79" cy="30" r="42" fill="black" />
      </mask>
      <circle cx="50" cy="50" r="49" mask="url(#nila-error-crescent)" />
    </svg>
    """
  end
end
