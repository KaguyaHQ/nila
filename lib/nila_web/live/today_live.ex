defmodule NilaWeb.TodayLive do
  use NilaWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Today")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      page_title={@page_title}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
    >
      <div id="today-page" class="mx-auto max-w-3xl space-y-6">
        <.page_header eyebrow="Cockpit" title="Today">
          Your work surface. The classification and review queues land here as the
          CA engine comes online.
        </.page_header>

        <.card class="space-y-3">
          <h2 class="text-base-content text-h4 font-semibold">Nothing to review yet</h2>
          <p class="text-base-content/60 text-small">
            Ingest a bank statement or document to get started — the assistant can
            help you find anything already uploaded.
          </p>
          <div class="pt-1">
            <.link
              navigate={~p"/assistant"}
              class="bg-base-100 border-base-300 hover:bg-base-200 rounded-field text-base-content/75 text-small inline-flex h-10 items-center justify-center border px-4 font-semibold transition"
            >
              Open the assistant
            </.link>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
