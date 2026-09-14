let savedPosition = null
const registerLocation = el => {
  return JSON.stringify([el.dataset.registerPath, el.dataset.registerQuery || "", el.dataset.registerFilter || "all"])
}

// Preserve the working row only when opening an invoice from this register.
export const SalesRegisterPosition = {
  mounted() {
    this.enterResults = () => {
      const search = this.el.querySelector("[data-shortcut-search]")
      if (this.pendingQuery == null || document.activeElement !== search || search.value !== this.pendingQuery) return
      // Wait for the rows belonging to this query, rather than entering stale results.
      if ((this.el.dataset.registerQuery || "") !== this.pendingQuery) return
      this.pendingQuery = null
      const first = this.el.querySelector("#sales-period-invoices a[data-table-row-link]")
      if (first) {
        first.focus({preventScroll: true})
        first.scrollIntoView({block: "nearest", inline: "nearest"})
      }
    }
    this.onSearchKey = event => {
      if (!event.target.matches("[data-shortcut-search]")) return
      if (event.key === "Escape" || event.key === "Tab") this.pendingQuery = null
      if (event.key !== "ArrowDown" || event.defaultPrevented || event.isComposing || event.ctrlKey || event.metaKey || event.altKey || event.shiftKey) return
      if (localStorage.getItem("nila-shortcuts-enabled") === "false") return
      event.preventDefault()
      this.pendingQuery = event.target.value
      this.enterResults()
    }
    this.cancelEntry = () => { this.pendingQuery = null }
    this.el.addEventListener("keydown", this.onSearchKey)
    this.el.addEventListener("input", this.cancelEntry)
    this.el.addEventListener("focusout", this.cancelEntry)

    this.remember = event => {
      const link = event.target.closest("a")
      const row = link?.closest("#sales-period-invoices tr[id]")
      if (!row || event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) return
      const scroller = this.el.closest("main")
      savedPosition = {url: registerLocation(this.el), rowId: row.id,
        top: scroller?.scrollTop || 0, windowTop: window.scrollY}
    }
    this.el.addEventListener("click", this.remember)
    if (savedPosition?.url === registerLocation(this.el)) {
      const position = savedPosition
      savedPosition = null
      requestAnimationFrame(() => requestAnimationFrame(() => {
        if (!this.el.isConnected) return
        document.getElementById(position.rowId)?.querySelector("a")?.focus({preventScroll: true})
        const scroller = this.el.closest("main")
        if (scroller) scroller.scrollTop = position.top
        window.scrollTo(0, position.windowTop)
      }))
    }
  },
  updated() {
    this.enterResults()
  },
  destroyed() {
    this.el.removeEventListener("keydown", this.onSearchKey)
    this.el.removeEventListener("input", this.cancelEntry)
    this.el.removeEventListener("focusout", this.cancelEntry)
    this.el.removeEventListener("click", this.remember)
  },
}
