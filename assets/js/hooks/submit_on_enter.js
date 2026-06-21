const MAX_HEIGHT = 192

export const SubmitOnEnter = {
  mounted() {
    this.resize = () => {
      this.el.style.height = "auto"
      const next = Math.min(this.el.scrollHeight, MAX_HEIGHT)
      this.el.style.height = `${next}px`
      this.el.style.overflowY = this.el.scrollHeight > MAX_HEIGHT ? "auto" : "hidden"
    }

    this.prefill = (event) => {
      this.el.value = event.detail.text || ""
      this.resize()
      this.el.focus()
    }

    this.el.addEventListener("input", this.resize)
    this.el.addEventListener("nila:assistant-prefill", this.prefill)
    this.el.addEventListener("keydown", (event) => {
      if (event.key === "Enter" && !event.shiftKey) {
        event.preventDefault()
        const form = this.el.closest("form")
        if (form) {
          form.requestSubmit()
        }
      }
    })

    this.resize()
  },

  updated() {
    this.resize()
  },

  destroyed() {
    this.el.removeEventListener("input", this.resize)
    this.el.removeEventListener("nila:assistant-prefill", this.prefill)
  },
}
