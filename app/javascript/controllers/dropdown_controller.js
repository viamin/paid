import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["menu", "button"]

  connect() {
    this.boundCloseOnOutsideClick = this.closeOnOutsideClick.bind(this)
    this.boundCloseOnEscape = this.closeOnEscape.bind(this)
    this.boundCloseOnNavigate = this.close.bind(this)

    document.addEventListener("click", this.boundCloseOnOutsideClick)
    document.addEventListener("keydown", this.boundCloseOnEscape)
    document.addEventListener("turbo:before-visit", this.boundCloseOnNavigate)

    this.close()
  }

  disconnect() {
    document.removeEventListener("click", this.boundCloseOnOutsideClick)
    document.removeEventListener("keydown", this.boundCloseOnEscape)
    document.removeEventListener("turbo:before-visit", this.boundCloseOnNavigate)
  }

  toggle(event) {
    event.preventDefault()
    event.stopPropagation()

    if (this.isOpen()) {
      this.close()
    } else {
      this.open()
    }
  }

  close() {
    this.menuTarget.classList.add("hidden")
    this.buttonTarget.setAttribute("aria-expanded", "false")
  }

  open() {
    this.menuTarget.classList.remove("hidden")
    this.buttonTarget.setAttribute("aria-expanded", "true")
  }

  closeOnOutsideClick(event) {
    if (this.element.contains(event.target)) {
      return
    }

    this.close()
  }

  closeOnEscape(event) {
    if (event.key !== "Escape") {
      return
    }

    this.close()
  }

  isOpen() {
    return !this.menuTarget.classList.contains("hidden")
  }
}
