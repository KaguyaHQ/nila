export const KeyboardShortcuts = {
  mounted() {
    const help = this.el.querySelector('[popover]')
    const toggle = this.el.querySelector('input[type="checkbox"]')
    toggle.checked = localStorage.getItem('nila-shortcuts-enabled') !== 'false'
    this.openHelp = () => {
      if (document.querySelector("dialog:modal")) return
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
      if (event.defaultPrevented || event.repeat || event.isComposing || event.altKey || localStorage.getItem('nila-shortcuts-enabled') === 'false') return
      if ((event.ctrlKey || event.metaKey) && event.key === 'Enter' && !event.shiftKey) {
        if (document.querySelector(':popover-open')) return
        const dialog = event.target.closest('dialog:modal')
        const form = dialog?.querySelector('form[data-shortcut-save]')
        if (!form || form.matches('.phx-submit-loading') || form.closest('[inert]')) return
        const submitter = [...form.elements].find(el => el.type === 'submit' && !el.disabled)
        if (!submitter) return
        event.preventDefault()
        form.requestSubmit(submitter)
        return
      }
      if (event.ctrlKey || event.metaKey) return
      if (event.target.closest('input, textarea, select, [contenteditable]:not([contenteditable="false"]), [role="combobox"], [role="listbox"], [role="tablist"], [role="slider"]')) return
      if (document.querySelector(':popover-open, dialog:modal')) return
      const dialogs = [...document.querySelectorAll('[role="dialog"]')].filter(el => el.getClientRects().length)
      if (dialogs.length) return
      if (event.key === '?') {
        event.preventDefault()
        this.openHelp()
      } else if (!event.shiftKey) {
        const selector = event.key === '/' ? '[data-shortcut-search]' : event.key.toLowerCase() === 'u' ? '[data-shortcut-upload]' : event.key.toLowerCase() === 'e' ? '[data-shortcut-edit]' : null
        const target = selector && [...document.querySelectorAll(selector)].find(el =>
          el.getClientRects().length && getComputedStyle(el).visibility === 'visible' &&
          !el.matches(':disabled, [disabled], [readonly]') &&
          !el.closest('[inert], [aria-disabled="true"], [aria-hidden="true"]')
        )
        if (target) {
          event.preventDefault()
          if (event.key === '/') { target.focus(); target.select() }
          else target.click()
          return
        }
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
