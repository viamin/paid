import { Controller } from "@hotwired/stimulus"

// Manages a mobile-only tappable tooltip (info icon).
// Desktop (hover-capable) devices skip JS listeners entirely and rely on
// the native HTML `title` attribute — the info icon is hidden via
// `@media(hover:hover)` in the template.
export default class extends Controller {
  static targets = ["content"]

  connect() {
    this.boundHide = this.hide.bind(this)
    this.boundKeydown = this.handleKeydown.bind(this)
    this.boundFocusOut = this.handleFocusOut.bind(this)

    // On hover-capable devices the info icon is hidden via CSS, so no
    // listeners are needed — the native title tooltip handles everything.
    this.hoverDevice = window.matchMedia("(hover: hover)").matches
  }

  toggle() {
    // On hover-capable devices the info icon is CSS-hidden, but guard here
    // too so hybrid touch/hover devices can't open a tooltip that lacks
    // close listeners (click-outside / Escape).
    if (this.hoverDevice) return

    const isHidden = this.contentTarget.classList.toggle("hidden")
    const expanded = !isHidden
    this.#updateAria(expanded)

    if (expanded) {
      this.#addGlobalListeners()
    } else {
      this.#removeGlobalListeners()
    }
  }

  hide(event) {
    if (!this.element.contains(event.target)) {
      this.#close()
    }
  }

  disconnect() {
    this.#removeGlobalListeners()
  }

  handleKeydown(event) {
    if (event.key === "Escape" || event.key === "Esc") {
      this.#close()
    }
  }

  handleFocusOut(event) {
    const nextFocusedElement = event.relatedTarget

    // Only hide when focus moves completely outside the tooltip component.
    if (!nextFocusedElement || !this.element.contains(nextFocusedElement)) {
      this.#close()
    }
  }

  // -- private ---------------------------------------------------------------

  #close() {
    if (!this.contentTarget.classList.contains("hidden")) {
      this.contentTarget.classList.add("hidden")
      this.#updateAria(false)
      this.#removeGlobalListeners()
    }
  }

  #addGlobalListeners() {
    document.addEventListener("click", this.boundHide)
    document.addEventListener("keydown", this.boundKeydown)
    this.element.addEventListener("focusout", this.boundFocusOut)
  }

  #removeGlobalListeners() {
    document.removeEventListener("click", this.boundHide)
    document.removeEventListener("keydown", this.boundKeydown)
    this.element.removeEventListener("focusout", this.boundFocusOut)
  }

  #updateAria(expanded) {
    const button = this.element.querySelector("button[aria-controls]")
    if (button) button.setAttribute("aria-expanded", expanded)
    this.contentTarget.setAttribute("aria-hidden", !expanded)
  }
}
