defmodule NilaWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use NilaWeb, :html

  embed_templates "page_html/*"

  @whatsapp_url "https://wa.me/918148183716?text=" <>
                  URI.encode_www_form(
                    "Hi, I run a CA firm and would like to test Nila with one filed month."
                  )

  def whatsapp_url, do: @whatsapp_url

  @doc """
  The marketing chrome — the ledger header and footer that frame every public
  page. Every public page wraps its body in this, so the paper, the red margin
  rule, and the heavy double borders are defined once and cannot drift apart.

  The `tagline` slot sits left of the header links on `md` and up; pages that
  don't set it just get the links.
  """
  slot :tagline, doc: "one line of positioning, shown in the header on wide screens"
  slot :inner_block, required: true

  def page_shell(assigns) do
    ~H"""
    <div class="bg-paper text-ink min-h-screen">
      <div class="mx-auto max-w-6xl px-4 sm:px-6">
        <header class="border-ink border-b-4 border-double">
          <div class="flex h-16 items-center justify-between">
            <a href="/" class="flex items-center">
              <.logo class="text-ink h-7 w-auto" />
            </a>
            <div class="flex items-center gap-5">
              <p :if={@tagline != []} class="text-fine text-ink/55 hidden md:block">
                {render_slot(@tagline)}
              </p>
              <.link
                navigate={~p"/users/log_in"}
                class="hover:text-ink text-ink/70 text-small font-medium transition"
              >
                Log in
              </.link>
              <.link
                href={whatsapp_url()}
                target="_blank"
                rel="noopener noreferrer"
                class="bg-ink rounded-field text-paper text-small inline-flex h-9 items-center px-4 font-semibold transition hover:opacity-85"
              >
                Arrange a test
              </.link>
            </div>
          </div>
        </header>

        <div class="relative">
          <div
            aria-hidden="true"
            class="border-redink/50 absolute inset-y-0 left-3 w-1 border-x sm:left-4 lg:left-40"
          >
          </div>

          {render_slot(@inner_block)}
        </div>

        <.page_footer />
      </div>
    </div>
    """
  end

  @doc """
  The shared marketing footer, with the legal and contact links.
  """
  def page_footer(assigns) do
    ~H"""
    <footer class="border-ink border-t-4 border-double">
      <div class="flex flex-col gap-4 py-8 sm:flex-row sm:items-center sm:justify-between">
        <a href="/" class="inline-flex items-center">
          <.logo class="text-ink h-6 w-auto" />
        </a>
        <nav class="text-small flex flex-wrap items-center gap-x-6 gap-y-2 font-medium">
          <.link
            navigate={~p"/contact"}
            class="hover:text-ink text-ink/75 transition"
          >
            Contact
          </.link>
          <.link
            navigate={~p"/privacy"}
            class="hover:text-ink text-ink/75 transition"
          >
            Privacy
          </.link>
          <.link
            navigate={~p"/terms"}
            class="hover:text-ink text-ink/75 transition"
          >
            Terms
          </.link>
        </nav>
      </div>
      <div class="text-ink/50 text-micro flex flex-col gap-2 pb-8 sm:flex-row sm:items-center sm:justify-between">
        <p>© 2026 Nila</p>
        <p>Operated by Kaguya Media Private Limited · Chennai, India</p>
      </div>
    </footer>
    """
  end
end
