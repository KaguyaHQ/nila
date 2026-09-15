defmodule NilaWeb.Components.PdfViewer do
  use NilaWeb, :html

  attr :id, :string, required: true
  attr :url, :string, required: true
  attr :pages, :list, required: true

  slot :fallback

  def viewer(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="PdfViewer"
      class="flex h-full min-h-0 flex-col"
      data-has-fallback={if @fallback != [], do: "true", else: "false"}
      data-url={@url}
      data-pages={Jason.encode!(@pages)}
    >
      <div class="mb-3 flex flex-wrap items-center gap-2" role="toolbar" aria-label="PDF controls">
        <.button size="sm" variant="outline" data-pdf-action="previous" aria-label="Previous PDF page">←</.button>
        <span data-pdf-counter class="text-ink-muted text-ui" aria-live="polite"></span>
        <.button size="sm" variant="outline" data-pdf-action="next" aria-label="Next PDF page">→</.button>
        <.button size="sm" variant="outline" data-pdf-action="out" aria-label="Zoom out">−</.button>
        <.button size="sm" variant="outline" data-pdf-action="in" aria-label="Zoom in">+</.button>
        <.button size="sm" variant="outline" data-pdf-action="fit">Fit width</.button>
        <.button size="sm" variant="outline" href={@url} download>Download original</.button>
      </div>

      <p data-pdf-status role="status" class="text-ink-muted text-ui">Loading PDF…</p>

      <div data-pdf-fallback class="min-h-0 overflow-auto" hidden>{render_slot(@fallback)}</div>
      <div
        id={@id <> "-canvas"}
        phx-update="ignore"
        data-pdf-surface
        tabindex="0"
        role="region"
        aria-label="Invoice document. Page Up and Page Down jump between pages."
        class="min-h-0 flex-1 overflow-auto"
      >
        <div class="flex flex-col gap-4">
          <div :for={page <- @pages} data-pdf-page={page} class="relative shrink-0">
            <canvas aria-label={"Original invoice PDF page #{page}"} class="block"></canvas>
            <div data-pdf-text class="nila-pdf-text-layer"></div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
