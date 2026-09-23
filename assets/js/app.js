// Public pages use normal HTTP navigation; product interactions live in React.
import "phoenix_html"

document.addEventListener("click", (event) => {
  const button = event.target.closest("[data-dismiss-flash]")
  if (button) document.getElementById(button.dataset.dismissFlash)?.remove()
})
