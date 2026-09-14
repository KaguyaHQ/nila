// One sequential Tab stop among primary row links; native table/link semantics
// and embedded controls remain unchanged.
export const TableRowNavigation = {
  mounted() {
    this.onFocus = event => {
      if (this.links().includes(event.target)) {
        this.activeHref = event.target.getAttribute("href")
        this.sync()
      }
    }
    this.onPreference = () => this.sync()
    this.onKeydown = event => {
      if (event.defaultPrevented || event.isComposing || event.ctrlKey || event.metaKey || event.altKey || event.shiftKey) return
      if (event.key !== "ArrowUp" && event.key !== "ArrowDown") return
      if (!this.enabled()) return
      const links = this.links()
      const index = links.indexOf(event.target)
      if (index < 0) return
      event.preventDefault()
      const next = links[index + (event.key === "ArrowDown" ? 1 : -1)]
      if (next) {
        next.focus({preventScroll: true})
        next.scrollIntoView({block: "nearest", inline: "nearest"})
      }
    }
    this.el.addEventListener("keydown", this.onKeydown)
    this.el.addEventListener("focusin", this.onFocus)
    window.addEventListener("change", this.onPreference)
    window.addEventListener("storage", this.onPreference)
    this.sync()
  },
  enabled() {
    return localStorage.getItem("nila-shortcuts-enabled") !== "false"
  },
  links() {
    return [...this.el.querySelectorAll("a[data-table-row-link]")].filter(item =>
      item.closest("table") === this.el && item.getClientRects().length &&
      getComputedStyle(item).visibility !== "hidden" && !item.closest('[inert], [hidden], [aria-disabled="true"]')
    )
  },
  sync() {
    const links = this.links()
    const active = links.find(link => link.getAttribute("href") === this.activeHref) || links[0]
    this.activeHref = active?.getAttribute("href")
    for (const link of links) link.tabIndex = !this.enabled() || link === active ? 0 : -1
  },
  beforeUpdate() {
    this.hadFocus = this.links().includes(document.activeElement)
  },
  updated() {
    this.sync()
    if (this.hadFocus && document.activeElement === document.body) {
      this.links().find(link => link.tabIndex === 0)?.focus({preventScroll: true})
    }
    this.hadFocus = false
  },
  destroyed() {
    this.el.removeEventListener("keydown", this.onKeydown)
    this.el.removeEventListener("focusin", this.onFocus)
    window.removeEventListener("change", this.onPreference)
    window.removeEventListener("storage", this.onPreference)
  },
}
