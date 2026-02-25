import { Controller } from "@hotwired/stimulus"

// Toggles the mobile navigation menu open/closed
export default class extends Controller {
  static targets = ["menu", "openIcon", "closeIcon", "button"]

  connect() {
    this.updateAccessibilityState()
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

  updateAccessibilityState() {
    const isHidden = this.menuTarget.classList.contains("hidden")

    if (this.hasButtonTarget) {
      this.buttonTarget.setAttribute("aria-expanded", (!isHidden).toString())
    }

    this.menuTarget.setAttribute("aria-hidden", isHidden.toString())
  }
}
