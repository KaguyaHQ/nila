let savedPosition = null
const registerLocation = el => {
  return JSON.stringify([el.dataset.registerPath, el.dataset.registerQuery || "", el.dataset.registerFilter || "all"])
}

// Preserve the working row only when opening an invoice from this register.
export const SalesRegisterPosition = {
  mounted() {
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
  destroyed() {
    this.el.removeEventListener("click", this.remember)
  },
}
