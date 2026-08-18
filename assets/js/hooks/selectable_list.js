// Shared WAI-ARIA active-descendant behavior for searchable single-select lists.
// Focus stays in the input while Arrow keys move a virtual highlight; Enter
// activates the highlighted real link or button. LiveView remains responsible
// for filtering and DOM order.
export class SelectableListController {
  constructor(el, options = {}) {
    this.el = el
    this.inputSelector = options.inputSelector || "[data-selectable-input]"
    this.listSelector = options.listSelector || "[data-selectable-list]"
    this.optionSelector = options.optionSelector || "[data-selectable-option]"
    this.loop = options.loop ?? el.dataset.loop === "true"
    this.onPointerMove = event => this.pointerMove(event)
    this.el.addEventListener("pointermove", this.onPointerMove)
  }

  input() {
    return this.el.querySelector(this.inputSelector)
  }

  list() {
    return this.el.querySelector(this.listSelector)
  }

  allOptions() {
    return Array.from(this.el.querySelectorAll(this.optionSelector))
  }

  options() {
    return this.allOptions().filter(
      option => !option.hidden && option.dataset.disabled !== "true" && !option.disabled,
    )
  }

  refresh({activateFirst = false} = {}) {
    const input = this.input()
    const list = this.list()
    const options = this.allOptions()

    if (!input) return

    if (list && !list.id) list.id = `${this.el.id}-list`

    input.setAttribute("role", "combobox")
    input.setAttribute("aria-expanded", "true")
    input.setAttribute("aria-autocomplete", "list")

    if (list) {
      input.setAttribute("aria-controls", list.id)
      list.setAttribute("role", "listbox")
    }

    options.forEach((option, index) => {
      if (!option.id) option.id = `${this.el.id}-option-${index}`
      option.setAttribute("role", "option")
      option.setAttribute("tabindex", "-1")
      if (!option.hasAttribute("aria-selected")) option.setAttribute("aria-selected", "false")
    })

    this.setActive(activateFirst ? this.options()[0] : null, {scroll: false})
  }

  activeOption() {
    const id = this.activeId || this.input()?.getAttribute("aria-activedescendant")
    return id ? this.allOptions().find(option => option.id === id) || null : null
  }

  setActive(option, {scroll = true} = {}) {
    const input = this.input()
    this.activeId = option?.id || null

    this.allOptions().forEach(candidate => {
      const active = candidate === option
      candidate.toggleAttribute("data-active", active)
    })

    if (!input) return

    if (option) {
      input.setAttribute("aria-activedescendant", option.id)
      if (scroll) option.scrollIntoView({block: "nearest"})
    } else {
      input.removeAttribute("aria-activedescendant")
    }
  }

  move(delta) {
    const options = this.options()
    if (options.length === 0) return

    const current = options.indexOf(this.activeOption())
    let next = current === -1 ? (delta > 0 ? 0 : options.length - 1) : current + delta

    if (this.loop) {
      next = (next + options.length) % options.length
    } else {
      next = Math.max(0, Math.min(next, options.length - 1))
    }

    this.setActive(options[next])
  }

  first() {
    this.setActive(this.options()[0] || null)
  }

  last() {
    this.setActive(this.options().at(-1) || null)
  }

  activate({singleFallback = false} = {}) {
    const options = this.options()
    const target = this.activeOption() || (singleFallback && options.length === 1 ? options[0] : null)

    if (!target) return false

    target.click()
    return true
  }

  pointerMove(event) {
    if (event.pointerType && event.pointerType !== "mouse") return

    const option = event.target.closest?.(this.optionSelector)

    if (
      !option ||
      !this.el.contains(option) ||
      !this.options().includes(option) ||
      option === this.activeOption()
    ) {
      return
    }

    this.setActive(option, {scroll: false})
  }

  destroy() {
    this.el.removeEventListener("pointermove", this.onPointerMove)
  }
}

export const SelectableList = {
  mounted() {
    this.selection = new SelectableListController(this.el)
    this.selection.refresh({activateFirst: true})
    this.filterValue = this.el.dataset.filterValue

    this.onKeydown = event => {
      if (event.target !== this.selection.input()) return

      switch (event.key) {
        case "ArrowDown":
          event.preventDefault()
          this.selection.move(1)
          break
        case "ArrowUp":
          event.preventDefault()
          this.selection.move(-1)
          break
        case "Home":
        case "PageUp":
          event.preventDefault()
          this.selection.first()
          break
        case "End":
        case "PageDown":
          event.preventDefault()
          this.selection.last()
          break
        case "Enter":
          // If a debounced server filter has not rendered yet, allow the form's
          // phx-submit fallback to select from the current input value instead
          // of activating a stale highlighted row.
          if (
            this.el.dataset.filterValue !== undefined &&
            this.el.dataset.filterValue !== event.target.value
          ) {
            break
          }

          if (this.selection.activate()) event.preventDefault()
          break
      }
    }

    this.el.addEventListener("keydown", this.onKeydown)
  },

  updated() {
    const nextFilterValue = this.el.dataset.filterValue
    const filterChanged = this.filterValue !== nextFilterValue
    const previousActiveId = this.selection.activeId

    this.selection.refresh()

    const options = this.selection.options()
    const previous = options.find(option => option.id === previousActiveId)
    const active = filterChanged ? options[0] : previous || options[0]

    this.selection.setActive(active || null, {scroll: false})
    this.filterValue = nextFilterValue
  },

  destroyed() {
    this.el.removeEventListener("keydown", this.onKeydown)
    this.selection.destroy()
  },
}
