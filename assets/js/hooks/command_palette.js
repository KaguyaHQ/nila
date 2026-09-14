import {SelectableList} from "./selectable_list"

// Local filtering follows Petal's command-palette pattern: hide items in place,
// hide empty headings, and reapply the query after a LiveView patch. Keep Nila's
// existing keyboard controller and native dialog as the owners of navigation.
const matches = (text, query) => query.split(/\s+/).every(word => text.includes(word))
const months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

export const CommandPalette = {
  mounted() {
    SelectableList.mounted.call(this)
    this.onInput = event => {
      if (event.target === this.selection.input()) this.filter()
    }
    // With no LiveView search event, never let Enter reload the page when
    // there are no matches.
    this.onSubmit = event => event.preventDefault()
    this.el.addEventListener("input", this.onInput)
    this.el.addEventListener("submit", this.onSubmit)
    this.filter()
  },

  beforeUpdate() {
    this.savedQuery = this.selection.input()?.value || ""
    this.savedActiveId = this.selection.activeId
  },

  updated() {
    this.selection.input().value = this.savedQuery ?? this.selection.input().value
    this.selection.refresh()
    this.selection.activeId = this.savedActiveId
    this.filter()
  },

  filter() {
    const input = this.selection.input()
    const query = input.value.trim().toLowerCase()
    const changed = query !== this.lastQuery
    this.lastQuery = query
    // Satisfy the shared controller's stale-server-filter guard synchronously.
    this.el.dataset.filterValue = input.value
    const currentYear = this.el.dataset.currentPeriod.slice(0, 4)
    const year = query.match(/\b(\d{4})\b/)?.[1] || currentYear

    for (const item of this.selection.allOptions()) {
      let text = item.dataset.commandSearch.toLowerCase()
      const original = item.dataset.commandPeriod
      let show
      if (original) {
        const month = original.slice(5)
        const period = query ? `${year}-${month}` : original
        const label = `${months[Number(month) - 1]} ${period.slice(0, 4)}`
        item.querySelector("[data-command-label]").textContent = label
        item.setAttribute("href", item.dataset.commandPath.replace(original, period))
        text = `${label} ${period}`.toLowerCase()
        show = query ? matches(text, query) : item.dataset.commandSuggested === "true"
      } else {
        show = matches(text, query)
      }
      item.hidden = !show
    }

    const visible = this.selection.options()
    for (const heading of this.el.querySelectorAll("[data-command-heading]")) {
      heading.hidden = !visible.some(item => item.dataset.commandGroup === heading.dataset.commandHeading)
    }
    this.el.querySelector("[data-command-empty]").hidden = visible.length > 0
    const previous = visible.find(item => item.id === this.selection.activeId)
    this.selection.setActive(changed ? visible[0] : previous || visible[0], {scroll: false})
  },

  destroyed() {
    this.el.removeEventListener("input", this.onInput)
    this.el.removeEventListener("submit", this.onSubmit)
    SelectableList.destroyed.call(this)
  },
}
