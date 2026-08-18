// Global ⌘K command palette.
//
// Open/closed is *server state* (the component's `:open` assign) — the hook pushes
// "open"/"close" events rather than toggling a class, because a client-only class
// toggle is reverted by LiveView's DOM patch on the next render (e.g. while typing).
// Keyboard navigation over result rows stays client-side; rows are <.link navigate>
// anchors, so activating one is a `.click()` that LiveView turns into SPA navigation.
import {SelectableListController} from "./selectable_list"

export const CommandPalette = {
  mounted() {
    this.trigger = document.getElementById("command-palette-trigger")
    this.open = this.isOpen()
    this.selection = new SelectableListController(this.el, {
      inputSelector: "[data-palette-input]",
      listSelector: "[data-palette-list]",
      optionSelector: "[data-palette-row]",
      loop: true,
    })
    this.selection.refresh()

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
          this.selection.move(1)
          break
        case "ArrowUp":
          event.preventDefault()
          this.selection.move(-1)
          break
        case "Home":
          event.preventDefault()
          this.selection.first()
          break
        case "End":
          event.preventDefault()
          this.selection.last()
          break
        case "Enter":
          if (this.selection.activate({singleFallback: true})) event.preventDefault()
          break
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
    this.selection.refresh()
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
