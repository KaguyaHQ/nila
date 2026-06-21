// Sheets-grade keyboard flow for the quote line-item grid: Enter never submits
// the form from a line input — with the picker open it picks the highlighted
// item (arrows move, Escape closes); otherwise it jumps to the next row's
// description, appending a row from the last one.
export const QuoteLineGrid = {
  mounted() {
    this.activeIndex = 0
    this.focusLastOnUpdate = false
    this.el.addEventListener("keydown", e => this.onKeydown(e))
  },

  updated() {
    if (this.focusLastOnUpdate) {
      this.focusLastOnUpdate = false
      const inputs = this.descriptionInputs()
      inputs[inputs.length - 1]?.focus()
    }

    // Server re-renders (typing) reset the highlight to the top match;
    // arrow moves are client-only and don't pass through here.
    this.activeIndex = 0
    this.applyHighlight()
  },

  onKeydown(e) {
    const options = this.pickerOptions()

    if (e.key === "Escape" && options.length) {
      this.pushEventTo(this.el, "close-item-picker", {})
      return
    }

    if ((e.key === "ArrowDown" || e.key === "ArrowUp") && options.length) {
      e.preventDefault()
      const delta = e.key === "ArrowDown" ? 1 : -1
      this.activeIndex = Math.min(
        Math.max(this.activeIndex + delta, 0),
        options.length - 1
      )
      this.applyHighlight()
      return
    }

    if (e.key !== "Enter" || !e.target.matches("input, select")) return

    e.preventDefault()

    if (options.length) {
      options[this.activeIndex]?.click()
      return
    }

    const row = e.target.closest("[data-line-row]")
    if (!row) return

    const rows = Array.from(this.el.querySelectorAll("[data-line-row]"))
    const next = rows[rows.indexOf(row) + 1]

    if (next) {
      next.querySelector("[data-line-description]")?.focus()
    } else if (this.rowHasDescription(row)) {
      // Only grow the grid when the last row holds something, so
      // Enter on an empty row can't pile up blank lines.
      this.focusLastOnUpdate = true
      this.pushEventTo(this.el, "add-line-item", {})
    }
  },

  rowHasDescription(row) {
    const input = row.querySelector("[data-line-description]")
    return !!input && input.value.trim() !== ""
  },

  descriptionInputs() {
    return Array.from(this.el.querySelectorAll("[data-line-description]"))
  },

  pickerOptions() {
    return Array.from(this.el.querySelectorAll("[data-picker-option]"))
  },

  applyHighlight() {
    this.pickerOptions().forEach((option, index) => {
      if (index === this.activeIndex) {
        option.setAttribute("data-active", "")
        option.scrollIntoView({block: "nearest"})
      } else {
        option.removeAttribute("data-active")
      }
    })
  },
}
