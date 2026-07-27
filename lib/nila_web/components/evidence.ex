defmodule NilaWeb.Components.Evidence do
  @moduledoc """
  Read-only viewer for a scanned document's page images.

  Two surfaces, one job — let a reviewer see the paper behind a line:

    * `evidence_frame/1` — the inline preview. An A4 page at any pane width is
      taller than the viewport, so this is never where reading happens; it is
      corroboration, sized to sit beside the thing it corroborates. It reserves
      its box before the bytes land (a page is ~3 MB) so selecting a row is not
      a layout jump followed by a flash.
    * `evidence_overlay/1` — where reading actually happens. Full screen, ink
      scrim, fit-height by default, click to step fit → 100% → 200% (the
      smudged-total case), Esc back to the surface underneath with its
      selection intact.
    * `evidence_unavailable/1` — the bill exists but its pages could not be
      rasterized. Distinct from "no bill was ever received", because only this
      one has a next step: the original file is still downloadable.

  Deliberately verbless. Resolution actions live in the queue's verb row; the
  moment a verb lands here there are two decision surfaces.
  """
  use Phoenix.Component

  import NilaWeb.Components.Button
  import NilaWeb.Components.Icon

  @doc """
  Inline page preview. `on_open` fires when the image is clicked (single click
  — a double click is undiscoverable), `on_page` carries a `page` value for
  multi-page documents.
  """
  attr :id, :string, required: true
  attr :images, :list, required: true
  attr :page, :integer, default: 0
  attr :label, :string, default: "Scanned bill"
  attr :on_open, :string, required: true
  attr :on_page, :string, required: true

  def evidence_frame(assigns) do
    assigns = assign(assigns, :count, length(assigns.images))

    ~H"""
    <div id={@id} class="space-y-2">
      <div class="flex items-baseline justify-between gap-2">
        <span class="text-base-content/60 text-label font-medium uppercase">{@label}</span>
        <.page_nav
          :if={@count > 1}
          id={"#{@id}-nav"}
          page={@page}
          count={@count}
          on_page={@on_page}
          tone="light"
        />
      </div>

      <button
        type="button"
        id={"#{@id}-open"}
        phx-click={@on_open}
        phx-hook=".EvidenceFrame"
        aria-label="Open the scanned bill full screen"
        class="bg-base-200 border-base-300 hover:border-primary/40 rounded-box relative block aspect-[1/1.414] w-full cursor-zoom-in overflow-hidden border transition"
      >
        <span class="absolute inset-0 flex items-center justify-center">
          <.icon
            name="hero-document-text"
            class="text-base-content/15 size-8 motion-safe:animate-pulse"
          />
        </span>
        <img
          src={Enum.at(@images, @page)}
          alt={page_alt(@label, @page, @count)}
          decoding="async"
          class="absolute inset-0 size-full object-contain"
        />
      </button>

      <p class="text-base-content/50 text-micro">Click to read it full screen.</p>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".EvidenceFrame">
        export default {
          mounted() { this.settle() },
          updated() { this.settle() },
          settle() {
            const img = this.el.querySelector("img")
            if (!img) return
            const fit = () => {
              if (!img.naturalWidth || !img.naturalHeight) return
              this.el.style.aspectRatio = `${img.naturalWidth} / ${img.naturalHeight}`
            }
            if (img.complete) fit()
            else img.addEventListener("load", fit, { once: true })
          }
        }
      </script>
    </div>
    """
  end

  @doc """
  Full-screen reader. The caller renders it with `:if` and owns open/page
  state; `on_close` must leave whatever is selected underneath untouched.
  """
  attr :id, :string, required: true
  attr :images, :list, required: true
  attr :page, :integer, default: 0
  attr :label, :string, default: "Scanned bill"
  attr :title, :string, default: nil
  attr :on_close, :string, required: true
  attr :on_page, :string, required: true

  def evidence_overlay(assigns) do
    assigns = assign(assigns, :count, length(assigns.images))

    ~H"""
    <div
      id={@id}
      class="bg-scrim/97 fixed inset-0 z-50 flex flex-col"
      phx-window-keydown={@on_close}
      phx-key="escape"
    >
      <div class="flex shrink-0 items-center justify-between gap-4 px-4 py-3">
        <span class="text-base-100 text-small min-w-0 truncate font-medium">{@title}</span>
        <div class="flex shrink-0 items-center gap-4">
          <.page_nav
            :if={@count > 1}
            id={"#{@id}-nav"}
            page={@page}
            count={@count}
            on_page={@on_page}
            tone="dark"
            keys
          />
          <button
            type="button"
            id={"#{@id}-close"}
            phx-click={@on_close}
            aria-label="Close the scanned bill"
            class="hover:text-base-100 rounded-field text-base-100/60 p-1 transition"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>
      </div>

      <%!-- The dim area around the bill dismisses, as it does in every image
            viewer a reviewer has ever used; the bill itself zooms. Both live on
            the stage so one listener can tell them apart by target. --%>
      <div
        id={"#{@id}-stage"}
        phx-hook=".EvidenceZoom"
        data-close-event={@on_close}
        class="flex flex-1 cursor-zoom-out overflow-auto px-4"
      >
        <img
          src={Enum.at(@images, @page)}
          alt={page_alt(@label, @page, @count)}
          decoding="async"
          class="m-auto max-h-full max-w-full cursor-zoom-in object-contain"
        />
      </div>

      <p class="text-base-100/50 text-micro shrink-0 px-4 py-3 text-center">
        Click the bill to zoom · click outside it or press Esc to close
      </p>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".EvidenceZoom">
        export default {
          mounted() {
            this.level = 0
            this.el.addEventListener("click", (event) => {
              if (event.target.tagName === "IMG") {
                this.level = (this.level + 1) % 3
                this.apply()
              } else {
                this.pushEvent(this.el.dataset.closeEvent)
              }
            })
          },
          updated() { this.level = 0; this.apply() },
          apply() {
            const img = this.el.querySelector("img")
            if (!img) return
            if (this.level === 0) {
              img.style.width = ""
              img.style.maxWidth = ""
              img.style.maxHeight = ""
              img.style.cursor = "zoom-in"
              return
            }
            const scale = this.level === 1 ? 1 : 2
            img.style.maxWidth = "none"
            img.style.maxHeight = "none"
            img.style.width = `${img.naturalWidth * scale}px`
            img.style.cursor = this.level === 2 ? "zoom-out" : "zoom-in"
          }
        }
      </script>
    </div>
    """
  end

  @doc """
  The bill arrived but its pages could not be rendered. Says what happened and
  offers the only next step there is — the original file.
  """
  attr :id, :string, required: true
  attr :source, :string, required: true
  attr :original_url, :string, default: nil
  attr :label, :string, default: "Scanned bill"

  def evidence_unavailable(assigns) do
    ~H"""
    <div id={@id} class="space-y-2">
      <span class="text-base-content/60 text-label font-medium uppercase">{@label}</span>
      <div class="border-base-300 rounded-box space-y-3 border border-dashed p-4">
        <p class="text-base-content text-small flex items-start gap-2 font-medium">
          <.icon name="hero-exclamation-triangle" class="text-warning mt-0.5 size-4 shrink-0" />
          <span>The pages of this bill couldn't be rendered.</span>
        </p>
        <p class="text-base-content/70 text-small">
          {@source} was read, so the numbers are here — but there's no scanned copy to check
          them against. Open the original before you decide this one.
        </p>
        <.button :if={@original_url} variant="outline" size="sm" href={@original_url} download>
          <.icon name="hero-arrow-down-tray" class="size-4" /> Open the original
        </.button>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :page, :integer, required: true
  attr :count, :integer, required: true
  attr :on_page, :string, required: true
  attr :tone, :string, required: true, values: ~w(light dark)
  attr :keys, :boolean, default: false

  defp page_nav(assigns) do
    ~H"""
    <div id={@id} class="flex items-center gap-1">
      <button
        type="button"
        id={"#{@id}-prev"}
        phx-click={@on_page}
        phx-value-page={@page - 1}
        phx-window-keydown={@keys && @on_page}
        phx-key="ArrowLeft"
        disabled={@page == 0}
        aria-label="Previous page"
        class={["rounded-field p-0.5 transition disabled:opacity-30", nav_tone(@tone)]}
      >
        <.icon name="hero-chevron-left-mini" class="size-4" />
      </button>
      <span class={["text-fine tabular-nums", count_tone(@tone)]}>{@page + 1}/{@count}</span>
      <button
        type="button"
        id={"#{@id}-next"}
        phx-click={@on_page}
        phx-value-page={@page + 1}
        phx-window-keydown={@keys && @on_page}
        phx-key="ArrowRight"
        disabled={@page == @count - 1}
        aria-label="Next page"
        class={["rounded-field p-0.5 transition disabled:opacity-30", nav_tone(@tone)]}
      >
        <.icon name="hero-chevron-right-mini" class="size-4" />
      </button>
    </div>
    """
  end

  defp nav_tone("dark"), do: "text-base-100/60 hover:text-base-100"
  defp nav_tone("light"), do: "text-base-content/60 hover:text-base-content"

  defp count_tone("dark"), do: "text-base-100/60"
  defp count_tone("light"), do: "text-base-content/50"

  defp page_alt(label, _page, 1), do: label
  defp page_alt(label, page, count), do: "#{label}, page #{page + 1} of #{count}"
end
