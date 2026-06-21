// Unsaved-work guard: warns on hard exits (refresh/close) via beforeunload only
// while dirty, and mirrors the form into localStorage so any other interruption
// (sidebar click, dropped socket, crash) restores on return via "restore-draft".
// The server clears the snapshot on save/discard with "draft-guard:clear" —
// never the client guessing at outcomes.
const MAX_AGE_MS = 24 * 60 * 60 * 1000

export const QuoteDraftGuard = {
  mounted() {
    this.key = "nila:quote-draft:" + this.el.dataset.draftKey
    this.dirty = false
    this.devReload = false
    this.onBeforeUnload = e => {
      e.preventDefault()
      e.returnValue = ""
    }
    this.onInput = () => {
      this.markDirty()
      this.scheduleSnapshot()
    }
    this.el.addEventListener("input", this.onInput)
    this.el.addEventListener("change", this.onInput)

    // Dev only: phoenix_live_reload fires this on connect and reloads the
    // page on file change. A hot reload isn't the user leaving, so disarm
    // the prompt and keep it disarmed (markDirty re-checks devReload). The
    // event never exists in prod, so the guard stays fully armed there.
    window.addEventListener("phx:live_reload:attached", () => {
      this.devReload = true
      window.removeEventListener("beforeunload", this.onBeforeUnload)
    })
    this.handleEvent("draft-guard:clear", () => this.clear())

    const saved = this.read()
    if (saved && saved.qs !== this.serialize()) {
      this.markDirty()
      this.pushEventTo(this.el, "restore-draft", {data: saved.qs})
    }
  },

  // Server patches normalize what the user typed (reindexed rows,
  // autofills), so re-snapshot after them, not just on keystrokes.
  updated() {
    if (this.dirty) this.scheduleSnapshot()
  },

  destroyed() {
    clearTimeout(this.snapshotTimer)
    window.removeEventListener("beforeunload", this.onBeforeUnload)
  },

  markDirty() {
    if (!this.dirty) {
      this.dirty = true
      // Attached only while dirty: an always-on listener disables
      // the browser's back/forward cache. Skipped under dev live-reload
      // so a keystroke between connect and reload can't re-arm it.
      if (!this.devReload) {
        window.addEventListener("beforeunload", this.onBeforeUnload)
      }
    }
  },

  scheduleSnapshot() {
    clearTimeout(this.snapshotTimer)
    this.snapshotTimer = setTimeout(() => {
      try {
        localStorage.setItem(
          this.key,
          JSON.stringify({t: Date.now(), qs: this.serialize()})
        )
      } catch (_e) {}
    }, 400)
  },

  serialize() {
    return new URLSearchParams(new FormData(this.el)).toString()
  },

  read() {
    try {
      const saved = JSON.parse(localStorage.getItem(this.key))
      if (!saved || !saved.qs || Date.now() - saved.t > MAX_AGE_MS) {
        localStorage.removeItem(this.key)
        return null
      }
      return saved
    } catch (_e) {
      return null
    }
  },

  clear() {
    clearTimeout(this.snapshotTimer)
    try {
      localStorage.removeItem(this.key)
    } catch (_e) {}
    if (this.dirty) {
      this.dirty = false
      window.removeEventListener("beforeunload", this.onBeforeUnload)
    }
  },
}
