// LiveView owns visibility; native dialog owns modality. Keep the dialog open
// while a close request is in flight, until the server removes it.
const modals = []
let focusBeforePatch = null
let popoversBeforePatch = null
export const captureModalFocus = () => {
  focusBeforePatch = document.activeElement
  popoversBeforePatch = [...document.querySelectorAll(":popover-open")]
}
const topModal = () => modals.findLast(hook => hook.el.isConnected && hook.el.open)

// DOM moves during a LiveView patch can remove a dialog from the top layer
// without clearing `open`. Restore the affected stack in its opening order.
export function restoreModalStack() {
  const focus = focusBeforePatch || document.activeElement
  const popovers = popoversBeforePatch || [...document.querySelectorAll(":popover-open")]
  focusBeforePatch = null
  popoversBeforePatch = null
  const active = modals.filter(hook => hook.el.isConnected)
  const firstMoved = active.findIndex(hook => !hook.el.matches(":modal"))
  if (firstMoved === -1) return
  for (const hook of active.slice(firstMoved)) {
    hook.el.close()
    hook.el.showModal()
  }
  for (const popover of popovers) {
    if (popover.isConnected && active.at(-1).el.contains(popover) && !popover.matches(":popover-open")) {
      popover.showPopover()
    }
  }
  if (focus?.isConnected && active.at(-1).el.contains(focus)) focus.focus({preventScroll: true})
}

export const Modal = {
  mounted() {
    this.previousFocus = focusBeforePatch || document.activeElement
    this.returnFocus = this.el.dataset.returnFocus
    this.requestClose = () => {
      if (topModal() !== this) return
      this.liveSocket.execJS(this.el, this.el.dataset.onClose)
    }
    this.onCancel = event => {
      if (event.target !== this.el) return
      event.preventDefault()
      event.stopPropagation()
      this.nativeCancelPending = !event.cancelable
      if (this.el.dataset.closeOnEscape !== "false") this.requestClose()
    }
    this.onKeyDown = event => {
      if (event.key !== "Escape" || event.defaultPrevented || topModal() !== this) return
      // Let a nested native popover consume Escape before its enclosing dialog.
      if (this.el.querySelector(":popover-open")) return
      event.preventDefault()
      event.stopPropagation()
      if (this.el.dataset.closeOnEscape !== "false") this.requestClose()
    }
    this.onClose = event => {
      if (event.target !== this.el || !this.el.isConnected || this.el.open) return
      // close() also fires during stack repair. Those queued events arrive after
      // showModal(), and are ignored above. A real native close must reach LiveView.
      restoreModalStack()
      if (!this.nativeCancelPending) this.liveSocket.execJS(this.el, this.el.dataset.onClose)
      this.nativeCancelPending = false
    }
    this.onPointerDown = event => {
      this.startedOnScrim = event.target === this.el
    }
    this.onClick = event => {
      if (this.startedOnScrim && event.target === this.el && this.el.dataset.variant !== "workbench") {
        this.requestClose()
      }
      this.startedOnScrim = false
    }
    this.el.addEventListener("cancel", this.onCancel)
    this.el.addEventListener("keydown", this.onKeyDown)
    this.el.addEventListener("close", this.onClose)
    this.el.addEventListener("pointerdown", this.onPointerDown)
    this.el.addEventListener("click", this.onClick)
    modals.push(this)
    this.el.showModal()
  },

  updated() {
    this.returnFocus = this.el.dataset.returnFocus
    // Native open state is reconciled once, after the entire patch, so a lower
    // dialog cannot accidentally reopen above the active one.
  },

  destroyed() {
    this.el.removeEventListener("cancel", this.onCancel)
    this.el.removeEventListener("keydown", this.onKeyDown)
    this.el.removeEventListener("close", this.onClose)
    this.el.removeEventListener("pointerdown", this.onPointerDown)
    this.el.removeEventListener("click", this.onClick)
    modals.splice(modals.indexOf(this), 1)
    const returnTarget = (this.returnFocus && document.querySelector(this.returnFocus)) || this.previousFocus
    // If a parent disappears first, its child should eventually return to the
    // parent's trigger rather than a now-detached control inside that parent.
    for (const hook of modals) {
      if (this.el.contains(hook.previousFocus)) hook.previousFocus = returnTarget
    }
    this.el.close()
    // Wait until the whole patch (including nested removals) has finished.
    queueMicrotask(() => {
      const top = topModal()?.el
      const target = (this.returnFocus && document.querySelector(this.returnFocus)) ||
        (this.previousFocus?.id && document.getElementById(this.previousFocus.id)) || this.previousFocus
      if (target?.isConnected && (!top || top.contains(target))) {
        target.focus({preventScroll: true})
      } else if (top && !top.contains(document.activeElement)) {
        top.querySelector(".nila-modal-panel, button")?.focus({preventScroll: true})
      }
    })
  },
}
