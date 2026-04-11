import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["menu"]

  connect() {
    this.boundCloseOnOutsideClick = this.closeOnOutsideClick.bind(this)
    this.boundCloseOnEscape = this.closeOnEscape.bind(this)

    document.addEventListener("click", this.boundCloseOnOutsideClick)
    document.addEventListener("keydown", this.boundCloseOnEscape)
  }

  disconnect() {
    document.removeEventListener("click", this.boundCloseOnOutsideClick)
    document.removeEventListener("keydown", this.boundCloseOnEscape)
  }

  toggle(event) {
    event.stopPropagation()

    if (this.menuTarget.classList.contains("hidden")) {
      this.menuTarget.classList.remove("hidden")
    } else {
      this.menuTarget.classList.add("hidden")
    }
  }

  closeOnOutsideClick(event) {
    if (this.element.contains(event.target)) return

    this.menuTarget.classList.add("hidden")
  }

  closeOnEscape(event) {
    if (event.key !== "Escape") return

    this.menuTarget.classList.add("hidden")
  }
}
