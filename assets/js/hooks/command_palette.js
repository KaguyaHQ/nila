// Global ⌘K command palette.
//
// Open/closed is *server state* (the component's `:open` assign) — the hook pushes
// "open"/"close" events rather than toggling a class, because a client-only class
// toggle is reverted by LiveView's DOM patch on the next render (e.g. while typing).
// Keyboard navigation over result rows stays client-side; rows are <.link navigate>
// anchors, so activating one is a `.click()` that LiveView turns into SPA navigation.
export const CommandPalette = {
  mounted() {
    this.trigger = document.getElementById("command-palette-trigger")
    this.activeIndex = -1
    this.open = this.isOpen()

    this.rows = () => Array.from(this.el.querySelectorAll("[data-palette-row]"))
    this.clearActive = () => this.rows().forEach((row) => row.removeAttribute("data-active"))

    this.setActive = (index) => {
      const rows = this.rows()
      this.clearActive()
      if (rows.length === 0) {
        this.activeIndex = -1
        return
      }
      this.activeIndex = (index + rows.length) % rows.length
      const row = rows[this.activeIndex]
      row.setAttribute("data-active", "")
      row.scrollIntoView({block: "nearest"})
    }

    this.onKeydown = (event) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault()
        this.pushEventTo(this.el, this.isOpen() ? "close" : "open", {})
        return
      }

      if (!this.isOpen()) return

      switch (event.key) {
        case "Escape":
          event.preventDefault()
          this.pushEventTo(this.el, "close", {})
          break
        case "ArrowDown":
          event.preventDefault()
          this.setActive(this.activeIndex + 1)
          break
        case "ArrowUp":
          event.preventDefault()
          this.setActive(this.activeIndex - 1)
          break
        case "Enter": {
          const rows = this.rows()
          const target =
            this.activeIndex >= 0 ? rows[this.activeIndex] : rows.length === 1 ? rows[0] : null
          if (target) {
            event.preventDefault()
            target.click()
          }
          break
        }
      }
    }

    this.onTrigger = () => this.pushEventTo(this.el, "open", {})
    this.onBackdrop = (event) => {
      if (event.target.closest("[data-palette-backdrop]")) {
        this.pushEventTo(this.el, "close", {})
      }
    }

    document.addEventListener("keydown", this.onKeydown)
    if (this.trigger) this.trigger.addEventListener("click", this.onTrigger)
    this.el.addEventListener("click", this.onBackdrop)
  },

  updated() {
    const open = this.isOpen()

    // Focus the input only on the closed -> open transition, so we don't
    // re-select text on every keystroke's re-render.
    if (open && !this.open) {
      const input = this.el.querySelector("[data-palette-input]")
      if (input) {
        input.focus()
        input.select()
      }
    }

    this.open = open
    // Result rows were re-rendered — drop any stale selection.
    this.activeIndex = -1
    this.clearActive()
  },

  destroyed() {
    document.removeEventListener("keydown", this.onKeydown)
    if (this.trigger) this.trigger.removeEventListener("click", this.onTrigger)
    this.el.removeEventListener("click", this.onBackdrop)
  },

  isOpen() {
    return this.el.dataset.open === "true"
  },
}
