import {getDocument, GlobalWorkerOptions, TextLayer} from "../../vendor/pdfjs/pdf.min.mjs"
import workerSource from "../../vendor/pdfjs/worker_source"

let workerUrl

export const PdfViewer = {
  mounted() {
    workerUrl ||= URL.createObjectURL(new Blob([workerSource], {type: "text/javascript"}))
    GlobalWorkerOptions.workerSrc = workerUrl
    this.pages = JSON.parse(this.el.dataset.pages)
    this.index = 0
    this.zoom = 1
    this.revision = 0
    this.surface = this.el.querySelector("[data-pdf-surface]")
    this.status = this.el.querySelector("[data-pdf-status]")
    this.counter = this.el.querySelector("[data-pdf-counter]")
    this.onClick = event => {
      const action = event.target.closest("[data-pdf-action]")?.dataset.pdfAction
      if (!action || !this.pdf || this.failed) return
      if (action === "previous") this.index = Math.max(0, this.index - 1)
      if (action === "next") this.index = Math.min(this.pages.length - 1, this.index + 1)
      if (action === "in") this.zoom = Math.min(3, this.zoom + 0.25)
      if (action === "out") this.zoom = Math.max(0.5, this.zoom - 0.25)
      if (action === "fit") this.zoom = 1
      this.draw()
    }
    this.el.addEventListener("click", this.onClick)
    this.observer = new ResizeObserver(entries => {
      const width = Math.round(entries[0].contentRect.width)
      if (width === this.width) return
      this.width = width
      clearTimeout(this.resizeTimer)
      this.resizeTimer = setTimeout(() => { if (this.pdf && !this.failed) this.draw() }, 100)
    })
    this.observer.observe(this.surface)
    this.controls()
    this.loading = getDocument({url: this.el.dataset.url, isEvalSupported: false})
    this.loading.promise.then(pdf => {
      if (this.dead) return
      this.pdf = pdf
      if (this.pages.some(page => page > pdf.numPages)) throw Error("Source page is outside this PDF")
      this.draw()
    }).catch(() => {
      if (!this.dead) this.showFallback()
    })
  },
  controls() {
    for (const button of this.el.querySelectorAll("[data-pdf-action]")) {
      const action = button.dataset.pdfAction
      button.disabled = this.failed || !this.pdf || (action === "previous" && this.index === 0) ||
        (action === "next" && this.index === this.pages.length - 1) ||
        (action === "in" && this.zoom >= 3) || (action === "out" && this.zoom <= 0.5)
    }
    this.counter.textContent = `Page ${this.pages[this.index]} · ${this.index + 1} of ${this.pages.length}`
  },
  async draw() {
    const revision = ++this.revision
    this.controls()
    this.textLayer?.cancel()
    const textContainer = this.surface.querySelector("[data-pdf-text]")
    textContainer.replaceChildren()
    textContainer.hidden = true
    delete this.el.dataset.renderedPage
    this.status.hidden = false
    this.status.textContent = "Rendering PDF…"
    try {
      // Cancel and finish any earlier render before reusing the canvas.
      const previous = this.renderTask
      previous?.cancel()
      if (previous) await previous.promise.catch(() => {})
      const page = await this.pdf.getPage(this.pages[this.index])
      if (this.dead || revision !== this.revision) return
      const base = page.getViewport({scale: 1})
      const viewport = page.getViewport({scale: Math.max(1, this.surface.clientWidth) / base.width * this.zoom})
      const ratio = Math.min(window.devicePixelRatio || 1, 2)
      const canvas = this.surface.querySelector("canvas")
      canvas.width = Math.ceil(viewport.width * ratio)
      canvas.height = Math.ceil(viewport.height * ratio)
      canvas.style.width = `${viewport.width}px`
      canvas.style.height = `${viewport.height}px`
      const pageContainer = this.surface.querySelector("[data-pdf-page]")
      pageContainer.style.width = `${viewport.width}px`
      pageContainer.style.height = `${viewport.height}px`
      textContainer.style.setProperty("--total-scale-factor", viewport.scale)
      this.renderTask = page.render({canvasContext: canvas.getContext("2d"), viewport, transform: [ratio, 0, 0, ratio, 0, 0]})
      await this.renderTask.promise
      if (this.dead || revision !== this.revision) return
      // Text uses the same CSS-pixel viewport as the canvas, not its HiDPI bitmap.
      // A text decoding failure must not take away the readable page image.
      try {
        const content = await page.getTextContent()
        if (this.dead || revision !== this.revision) return
        this.textLayer = new TextLayer({textContentSource: content, container: textContainer, viewport})
        await this.textLayer.render()
        if (this.dead || revision !== this.revision) return
        textContainer.hidden = false
      } catch (error) {
        if (this.dead || revision !== this.revision) return
        textContainer.replaceChildren()
      }
      this.status.hidden = true
      this.el.dataset.renderedPage = this.pages[this.index]
    } catch (error) {
      if (this.dead || revision !== this.revision || error.name === "RenderingCancelledException") return
      this.showFallback()
    }
  },
  showFallback() {
    this.failed = true
    this.renderTask?.cancel()
    this.textLayer?.cancel()
    this.surface.hidden = true
    this.el.querySelector("[data-pdf-fallback]").hidden = false
    this.status.hidden = false
    this.status.textContent = this.el.dataset.hasFallback === "true"
      ? "The PDF could not be opened. Showing the saved page image."
      : "The PDF could not be opened. Download the original to view it."
    for (const control of this.el.querySelectorAll("[data-pdf-action], [data-pdf-counter]")) control.hidden = true
    this.controls()
  },
  updated() {
    if (this.failed) this.showFallback()
    else this.controls()
  },
  destroyed() {
    this.dead = true
    this.revision++
    clearTimeout(this.resizeTimer)
    this.observer.disconnect()
    this.el.removeEventListener("click", this.onClick)
    this.renderTask?.cancel()
    this.textLayer?.cancel()
    this.loading?.destroy()
  },
}
