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
    this.pageElements = [...this.surface.querySelectorAll("[data-pdf-page]")]
    this.tasks = []
    this.layers = []
    this.status = this.el.querySelector("[data-pdf-status]")
    this.counter = this.el.querySelector("[data-pdf-counter]")
    this.onClick = event => {
      const action = event.target.closest("[data-pdf-action]")?.dataset.pdfAction
      if (!action || !this.pdf || this.failed) return
      if (action === "previous") return this.jump(-1)
      if (action === "next") return this.jump(1)
      if (action === "in") this.zoom = Math.min(3, this.zoom + 0.25)
      if (action === "out") this.zoom = Math.max(0.5, this.zoom - 0.25)
      if (action === "fit") this.zoom = 1
      this.draw()
    }
    this.onKey = event => {
      if (!this.pdf || this.failed || event.defaultPrevented || event.isComposing || event.ctrlKey || event.metaKey || event.altKey || event.shiftKey) return
      if (event.target.closest("input, textarea, select, [contenteditable=true]")) return
      if (localStorage.getItem("nila-shortcuts-enabled") === "false") return
      if (event.key !== "PageDown" && event.key !== "PageUp") return
      event.preventDefault()
      event.stopPropagation()
      this.jump(event.key === "PageDown" ? 1 : -1)
    }
    this.onPointer = () => this.surface.focus({preventScroll: true})
    this.onScroll = () => {
      cancelAnimationFrame(this.scrollFrame)
      this.scrollFrame = requestAnimationFrame(() => this.trackPage())
    }
    this.el.addEventListener("click", this.onClick)
    this.el.addEventListener("keydown", this.onKey)
    this.surface.addEventListener("pointerdown", this.onPointer)
    this.surface.addEventListener("scroll", this.onScroll)
    this.observer = new ResizeObserver(entries => {
      const width = Math.round(entries[0].contentRect.width)
      if (width === this.width) return
      this.width = width
      clearTimeout(this.resizeTimer)
      this.resizeTimer = setTimeout(() => { if (this.pdfPages && !this.failed) this.draw() }, 100)
    })
    this.observer.observe(this.surface)
    this.controls()
    this.loading = getDocument({url: this.el.dataset.url, isEvalSupported: false})
    this.loading.promise.then(pdf => {
      if (this.dead) return
      this.pdf = pdf
      if (this.pages.some(page => page > pdf.numPages)) throw Error("Source page is outside this PDF")
      return Promise.all(this.pages.map(number => pdf.getPage(number))).then(pages => {
        if (this.dead) return
        this.pdfPages = pages
        return this.draw()
      })
    }).catch(() => {
      if (!this.dead) this.showFallback()
    })
  },
  controls() {
    for (const button of this.el.querySelectorAll("[data-pdf-action]")) {
      const action = button.dataset.pdfAction
      button.disabled = this.failed || !this.pdfPages || (action === "previous" && this.index === 0) ||
        (action === "next" && this.index === this.pages.length - 1) ||
        (action === "in" && this.zoom >= 3) || (action === "out" && this.zoom <= 0.5)
    }
    this.counter.textContent = `Page ${this.index + 1} of ${this.pages.length}`
  },
  pageTop(index) {
    return this.pageElements[index].getBoundingClientRect().top - this.surface.getBoundingClientRect().top + this.surface.scrollTop
  },
  jump(direction) {
    if (!this.pdfPages) return
    this.index = Math.max(0, Math.min(this.pages.length - 1, this.index + direction))
    this.surface.scrollTo({top: this.pageTop(this.index), behavior: "instant"})
    this.controls()
  },
  trackPage() {
    if (!this.pdfPages || this.failed) return
    const top = this.surface.scrollTop + 24
    let index = 0
    for (let i = 1; i < this.pages.length; i++) {
      if (this.pageTop(i) <= top) index = i
    }
    // The last page can be shorter than the pane and cannot reach its top.
    if (this.surface.scrollTop > 0 && this.surface.scrollTop + this.surface.clientHeight >= this.surface.scrollHeight - 2) index = this.pages.length - 1
    this.index = index
    this.controls()
  },
  cancelRendering() {
    this.tasks.forEach(task => task.cancel())
    this.layers.forEach(layer => layer.cancel())
  },
  async draw() {
    if (!this.pdfPages || this.failed || this.dead) return
    this.renderComplete = false
    const revision = ++this.revision
    const anchor = this.index
    const fraction = (this.surface.scrollTop - this.pageTop(anchor)) / Math.max(1, this.pageElements[anchor].clientHeight)
    const previous = this.tasks
    this.cancelRendering()
    this.tasks = []
    this.layers = []
    this.controls()
    delete this.el.dataset.renderedPage
    // A zoom redraw must not insert a status row and move the document pane.
    this.status.hidden = this.hasRendered === true
    this.status.textContent = "Rendering PDF…"
    try {
      await Promise.all(previous.map(task => task.promise.catch(() => {})))
      if (this.dead || revision !== this.revision) return
      const padding = getComputedStyle(this.surface)
      const availableWidth = this.surface.clientWidth - parseFloat(padding.paddingLeft) - parseFloat(padding.paddingRight)
      const viewports = this.pdfPages.map(page => page.getViewport({scale: Math.max(1, availableWidth) / page.getViewport({scale: 1}).width * this.zoom}))
      // Size all pages first so page jumps and scrolling do not shift as they render.
      this.pageElements.forEach((element, index) => {
        element.style.width = `${viewports[index].width}px`
        element.style.height = `${viewports[index].height}px`
        const text = element.querySelector("[data-pdf-text]")
        text.replaceChildren()
        text.hidden = true
      })
      this.surface.scrollTop = this.pageTop(anchor) + fraction * this.pageElements[anchor].clientHeight
      for (let i = 0; i < this.pdfPages.length; i++) {
        if (this.dead || revision !== this.revision) return
        const page = this.pdfPages[i], viewport = viewports[i]
        const element = this.pageElements[i]
        const canvas = element.querySelector("canvas")
        const text = element.querySelector("[data-pdf-text]")
        const ratio = Math.min(window.devicePixelRatio || 1, 2)
        canvas.width = Math.ceil(viewport.width * ratio)
        canvas.height = Math.ceil(viewport.height * ratio)
        canvas.style.width = `${viewport.width}px`
        canvas.style.height = `${viewport.height}px`
        text.style.setProperty("--total-scale-factor", viewport.scale)
        const task = page.render({canvasContext: canvas.getContext("2d"), viewport, transform: [ratio, 0, 0, ratio, 0, 0]})
        this.tasks.push(task)
        await task.promise
        if (this.dead || revision !== this.revision) return
        try {
          const content = await page.getTextContent()
          if (this.dead || revision !== this.revision) return
          const layer = new TextLayer({textContentSource: content, container: text, viewport})
          this.layers.push(layer)
          await layer.render()
          if (this.dead || revision !== this.revision) return
          text.hidden = false
        } catch (_) {
          if (this.dead || revision !== this.revision) return
          text.replaceChildren()
        }
      }
      this.renderComplete = true
      this.hasRendered = true
      this.status.hidden = true
      this.el.dataset.renderedPage = this.pages[this.index]
      this.trackPage()
    } catch (error) {
      if (this.dead || revision !== this.revision || error.name === "RenderingCancelledException") return
      this.showFallback()
    }
  },
  showFallback() {
    this.failed = true
    this.cancelRendering()
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
    else {
      this.controls()
      this.status.hidden = this.hasRendered === true || this.renderComplete === true
      if (!this.renderComplete) this.status.textContent = this.pdfPages ? "Rendering PDF…" : "Loading PDF…"
    }
  },
  destroyed() {
    this.dead = true
    this.revision++
    clearTimeout(this.resizeTimer)
    this.observer.disconnect()
    cancelAnimationFrame(this.scrollFrame)
    this.el.removeEventListener("click", this.onClick)
    this.el.removeEventListener("keydown", this.onKey)
    this.surface.removeEventListener("pointerdown", this.onPointer)
    this.surface.removeEventListener("scroll", this.onScroll)
    this.cancelRendering()
    this.loading?.destroy()
  },
}
