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
    this.boundKeydown = this.handleKeydown.bind(this)
    this.boundFocusOut = this.handleFocusOut.bind(this)

    document.addEventListener("click", this.boundHide)
    document.addEventListener("keydown", this.boundKeydown)
    this.element.addEventListener("focusout", this.boundFocusOut)
  }

  disconnect() {
    document.removeEventListener("click", this.boundHide)
    document.removeEventListener("keydown", this.boundKeydown)
    this.element.removeEventListener("focusout", this.boundFocusOut)
  }

  handleKeydown(event) {
    if (event.key === "Escape" || event.key === "Esc") {
      if (!this.contentTarget.classList.contains("hidden")) {
        this.contentTarget.classList.add("hidden")
        this.#updateAria(false)
      }
    }
  }

  handleFocusOut(event) {
    const nextFocusedElement = event.relatedTarget

    // Only hide when focus moves completely outside the tooltip component.
    if (!nextFocusedElement || !this.element.contains(nextFocusedElement)) {
      if (!this.contentTarget.classList.contains("hidden")) {
        this.contentTarget.classList.add("hidden")
        this.#updateAria(false)
      }
    }
  }

  #updateAria(expanded) {
    const button = this.element.querySelector("button[aria-controls]")
    if (button) button.setAttribute("aria-expanded", expanded)
    this.contentTarget.setAttribute("aria-hidden", !expanded)
  }
}
