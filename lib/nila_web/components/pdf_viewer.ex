defmodule NilaWeb.Components.PdfViewer do
  use NilaWeb, :html

  attr :id, :string, required: true
  attr :url, :string, required: true
  attr :pages, :list, required: true
  attr :document_label, :string, default: "Invoice"

  attr :reading_width, :integer,
    default: nil,
    doc: "Optional initial page width cap in CSS pixels"

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
      data-document-label={@document_label}
      data-reading-width={@reading_width}
    >
      <div
        class="bg-panel-surface border-rule flex shrink-0 flex-wrap items-center gap-2 border-b px-3 py-2"
        role="toolbar"
        aria-label="PDF controls"
      >
        <div class="flex items-center gap-1">
          <.button
            size="xs"
            variant="ghost"
            data-pdf-action="previous"
            aria-label="Previous PDF page"
            title="Previous page (Page Up)"
          >
            <.icon name="hero-chevron-left" class="size-4" />
          </.button>
          <span
            data-pdf-counter
            class="text-ink-muted text-ui whitespace-nowrap tabular-nums"
            aria-live="polite"
          ></span>
          <.button
            size="xs"
            variant="ghost"
            data-pdf-action="next"
            aria-label="Next PDF page"
            title="Next page (Page Down)"
          >
            <.icon name="hero-chevron-right" class="size-4" />
          </.button>
        </div>
        <div class="border-rule flex items-center gap-1 border-l pl-2">
          <.button
            size="xs"
            variant="ghost"
            data-pdf-action="out"
            aria-label="Zoom out"
            title="Zoom out"
          >
            <.icon name="hero-minus" class="size-4" />
          </.button>
          <.button size="xs" variant="ghost" data-pdf-action="in" aria-label="Zoom in" title="Zoom in">
            <.icon name="hero-plus" class="size-4" />
          </.button>
          <.button size="xs" variant="ghost" data-pdf-action="fit" title="Fit page to pane width">Fit width</.button>
        </div>
        <div class="ml-auto">
          <.button
            size="xs"
            variant="ghost"
            href={@url}
            download
            aria-label="Download original"
            title="Download original"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" />
          </.button>
        </div>
      </div>

      <p data-pdf-status role="status" class="text-ink-muted text-ui px-3 py-2">Loading PDF…</p>

      <div data-pdf-fallback class="min-h-0 overflow-auto" hidden>{render_slot(@fallback)}</div>
      <div
        id={@id <> "-canvas"}
        phx-update="ignore"
        data-pdf-surface
        tabindex="0"
        role="region"
        aria-label={"#{@document_label} document. Page Up and Page Down jump between pages."}
        class="bg-quiet min-h-0 flex-1 overflow-auto p-3"
      >
        <div class="flex flex-col gap-4">
          <div
            :for={page <- if @pages == [], do: [1], else: @pages}
            data-pdf-page={page}
            class="bg-panel-surface nila-pdf-page relative mx-auto shrink-0"
          >
            <canvas
              aria-label={"Original #{String.downcase(@document_label)} PDF page #{page}"}
              class="block"
            ></canvas>
            <div data-pdf-text class="nila-pdf-text-layer"></div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
