import { Controller } from "@hotwired/stimulus"

// Manages a mobile-only tappable tooltip (info icon).
// Desktop tooltips use the native HTML title attribute.
export default class extends Controller {
  static targets = ["content"]

  toggle() {
    const isHidden = this.contentTarget.classList.toggle("hidden")
    this.#updateAria(!isHidden)
  }

  hide(event) {
    if (!this.element.contains(event.target)) {
      this.contentTarget.classList.add("hidden")
      this.#updateAria(false)
    }
  }

  connect() {
    this.boundHide = this.hide.bind(this)
    document.addEventListener("click", this.boundHide)
  }

  disconnect() {
    document.removeEventListener("click", this.boundHide)
  }

  #updateAria(expanded) {
    const button = this.element.querySelector("button[aria-controls]")
    if (button) button.setAttribute("aria-expanded", expanded)
    this.contentTarget.setAttribute("aria-hidden", !expanded)
  }
}
