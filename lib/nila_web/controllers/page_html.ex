defmodule NilaWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use NilaWeb, :html

  embed_templates "page_html/*"

  @whatsapp_url "https://wa.me/918148183716?text=" <>
                  URI.encode_www_form(
                    "Hi, I’d like to try Nila free with one client’s sales bills."
                  )

  def whatsapp_url, do: @whatsapp_url

  attr :flash, :map, required: true
  slot :inner_block, required: true

  def page_shell(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="landing text-ink min-h-screen">
      <.public_header />
      {render_slot(@inner_block)}
      <.page_footer />
    </div>
    """
  end

  attr :inverted, :boolean, default: false
  attr :class, :any, default: nil

  def public_header(assigns) do
    ~H"""
    <header class={@class}>
      <div class="mx-auto flex h-20 max-w-5xl items-center justify-between px-6">
        <.link navigate={~p"/"} class="inline-flex items-center">
          <.logo class={["h-6 w-auto", @inverted && "text-inverse/90", !@inverted && "text-ink"]} />
        </.link>
        <.link
          navigate={~p"/users/log_in"}
          class={[
            "text-ui font-medium transition",
            @inverted && "hover:text-inverse text-inverse/60",
            !@inverted && "hover:text-ink text-ink-subtle"
          ]}
        >
          Log in
        </.link>
      </div>
    </header>
    """
  end

  attr :eyebrow, :string, required: true
  attr :title, :string, required: true
  attr :updated, :string, required: true
  slot :inner_block, required: true

  def legal_page(assigns) do
    ~H"""
    <main class="mx-auto max-w-5xl px-6 pt-16 pb-28 sm:pt-24 sm:pb-36">
      <header class="max-w-3xl">
        <p class="text-eyebrow text-ink-subtle font-semibold uppercase">{@eyebrow}</p>
        <h1 class="font-display text-statement mt-6 font-normal text-balance">{@title}</h1>
        <div class="mt-5">
          <.context_text tag="p">Last updated {@updated}</.context_text>
        </div>
      </header>
      <article class="mt-12 max-w-3xl space-y-10">
        {render_slot(@inner_block)}
      </article>
    </main>
    """
  end

  def page_footer(assigns) do
    ~H"""
    <footer class="mx-auto max-w-5xl px-6 pb-10">
      <div class="border-rule/60 flex flex-col items-center gap-4 border-t pt-8 sm:flex-row sm:justify-between">
        <.link navigate={~p"/"} class="inline-flex items-center">
          <.logo class="text-ink-subtle h-5 w-auto" />
        </.link>
        <nav class="text-ink-subtle text-ui flex items-center gap-6">
          <.link navigate={~p"/contact"} class="hover:text-ink transition">Contact</.link>
          <.link navigate={~p"/privacy"} class="hover:text-ink transition">Privacy</.link>
          <.link navigate={~p"/terms"} class="hover:text-ink transition">Terms</.link>
        </nav>
        <.context_text tag="p">© 2026 Nila · Kaguya Media Private Limited</.context_text>
      </div>
    </footer>
    """
  end
end
