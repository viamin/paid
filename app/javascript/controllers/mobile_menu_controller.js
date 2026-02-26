import { Controller } from "@hotwired/stimulus"

// Toggles the mobile navigation menu open/closed
export default class extends Controller {
  static targets = ["menu", "openIcon", "closeIcon", "button"]

  connect() {
    this.mediaQuery = window.matchMedia("(min-width: 768px)")
    this.boundCloseOnDesktop = this.closeOnDesktop.bind(this)
    this.mediaQuery.addEventListener("change", this.boundCloseOnDesktop)

    this.boundCloseOnNavigate = this.close.bind(this)
    document.addEventListener("turbo:before-visit", this.boundCloseOnNavigate)

    this.updateAccessibilityState()
  }

  disconnect() {
    this.mediaQuery.removeEventListener("change", this.boundCloseOnDesktop)
    document.removeEventListener("turbo:before-visit", this.boundCloseOnNavigate)
  }

  toggle() {
    this.menuTarget.classList.toggle("hidden")
    this.openIconTarget.classList.toggle("hidden")
    this.closeIconTarget.classList.toggle("hidden")
    this.updateAccessibilityState()
  }

  close() {
    this.menuTarget.classList.add("hidden")
    this.openIconTarget.classList.remove("hidden")
    this.closeIconTarget.classList.add("hidden")
    this.updateAccessibilityState()
  }

  closeOnDesktop(event) {
    if (event.matches) {
      this.close()
    }
  }

  updateAccessibilityState() {
    const isVisible = !this.menuTarget.classList.contains("hidden") &&
      !this.mediaQuery.matches

    if (this.hasButtonTarget) {
      this.buttonTarget.setAttribute("aria-expanded", isVisible.toString())
    }

    this.menuTarget.setAttribute("aria-hidden", (!isVisible).toString())
  }
}
