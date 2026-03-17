import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["menu", "button"]

  connect() {
    this.listenersAttached = false

    if (!this.hasRequiredTargets()) {
      return
    }

    this.boundCloseOnOutsideClick = this.closeOnOutsideClick.bind(this)
    this.boundCloseOnEscape = this.closeOnEscape.bind(this)
    this.boundCloseOnNavigate = this.close.bind(this)

    document.addEventListener("click", this.boundCloseOnOutsideClick)
    document.addEventListener("keydown", this.boundCloseOnEscape)
    document.addEventListener("turbo:before-visit", this.boundCloseOnNavigate)
    this.listenersAttached = true

    this.close()
  }

  disconnect() {
    if (!this.listenersAttached) {
      return
    }

    document.removeEventListener("click", this.boundCloseOnOutsideClick)
    document.removeEventListener("keydown", this.boundCloseOnEscape)
    document.removeEventListener("turbo:before-visit", this.boundCloseOnNavigate)
    this.listenersAttached = false
  }

  toggle(event) {
    if (!this.hasRequiredTargets()) {
      return
    }

    event.preventDefault()
    event.stopPropagation()

    if (this.isOpen()) {
      this.close()
    } else {
      this.open()
    }
  }

  close() {
    if (!this.hasRequiredTargets()) {
      return
    }

    this.menuTarget.classList.add("hidden")
    this.buttonTarget.setAttribute("aria-expanded", "false")
  }

  open() {
    if (!this.hasRequiredTargets()) {
      return
    }

    this.menuTarget.classList.remove("hidden")
    this.buttonTarget.setAttribute("aria-expanded", "true")
  }

  closeOnOutsideClick(event) {
    if (!this.hasRequiredTargets()) {
      return
    }

    if (this.element.contains(event.target)) {
      return
    }

    this.close()
  }

  closeOnEscape(event) {
    if (!this.hasRequiredTargets()) {
      return
    }

    if (event.key !== "Escape") {
      return
    }

    this.close()
  }

  isOpen() {
    if (!this.hasRequiredTargets()) {
      return false
    }

    return !this.menuTarget.classList.contains("hidden")
  }

  hasRequiredTargets() {
    return this.hasMenuTarget && this.hasButtonTarget
  }
}
