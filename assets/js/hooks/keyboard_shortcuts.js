export const KeyboardShortcuts = {
  mounted() {
    const help = this.el.querySelector('[popover]')
    const toggle = this.el.querySelector('input[type="checkbox"]')
    toggle.checked = localStorage.getItem('nila-shortcuts-enabled') !== 'false'
    this.openHelp = () => {
      this.returnFocus = document.activeElement
      const menu = this.returnFocus?.closest('[popover]')
      if (menu) {
        this.returnFocus = document.querySelector(`[popovertarget="${menu.id}"]`)
        menu.hidePopover()
      }
      help.showPopover()
      help.querySelector('button').focus()
    }
    this.el.addEventListener('nila:show-shortcuts', this.openHelp)
    this.onToggle = event => {
      if (event.newState === 'closed') this.returnFocus?.focus({preventScroll: true})
    }
    help.addEventListener('toggle', this.onToggle)
    this.onChange = () => localStorage.setItem('nila-shortcuts-enabled', String(toggle.checked))
    toggle.addEventListener('change', this.onChange)
    this.onKey = event => {
      if (event.defaultPrevented || event.repeat || event.isComposing || event.ctrlKey || event.metaKey || event.altKey || localStorage.getItem('nila-shortcuts-enabled') === 'false') return
      if (event.target.closest('input, textarea, select, [contenteditable]:not([contenteditable="false"]), [role="combobox"], [role="listbox"], [role="tablist"], [role="slider"]')) return
      if (document.querySelector(':popover-open')) return
      const dialogs = [...document.querySelectorAll('[role="dialog"]')].filter(el => el.getClientRects().length)
      const invoiceReview = document.querySelector('#sales-bill-posting-review-keys')
      if (dialogs.length && !invoiceReview) return
      if (document.querySelector('#sales-bill-invoice-facts-sheet, #sales-bill-line-edit-sheet')) return
      if (event.key === '?') {
        event.preventDefault()
        this.openHelp()
      } else if (!invoiceReview && !dialogs.length && !event.shiftKey) {
        const id = event.key === '[' ? 'previous-filing-period' : event.key === ']' ? 'next-filing-period' : null
        const link = id && document.getElementById(id)
        if (link) { event.preventDefault(); link.click() }
      }
    }
    window.addEventListener('keydown', this.onKey)
  },
  destroyed() {
    window.removeEventListener('keydown', this.onKey)
    this.el.removeEventListener('nila:show-shortcuts', this.openHelp)
    this.el.querySelector('[popover]').removeEventListener('toggle', this.onToggle)
    this.el.querySelector('input[type="checkbox"]').removeEventListener('change', this.onChange)
  }
}
