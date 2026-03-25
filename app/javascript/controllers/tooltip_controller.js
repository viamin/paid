import { Controller } from "@hotwired/stimulus"

// Manages a tappable tooltip (info icon) for touch/hybrid devices.
// The JS guard mirrors the template's CSS media query exactly:
//   @media (hover:hover) and (pointer:fine) and (not (any-pointer:coarse))
// When matched (typically non-touch desktops), the icon is CSS-hidden and the
// native `title` attribute handles tooltips — no JS listeners are attached.
export default class extends Controller {
  static targets = ["content"]

  connect() {
    this.boundHide = this.hide.bind(this)
    this.boundKeydown = this.handleKeydown.bind(this)
    this.boundFocusOut = this.handleFocusOut.bind(this)

    // Mirror the exact CSS media query used to hide the info icon in the
    // template. When this query matches, the icon is CSS-hidden and the
    // native `title` tooltip handles everything — no JS needed.
    this.iconHiddenByCSS = window.matchMedia(
      "(hover: hover) and (pointer: fine) and (not (any-pointer: coarse))"
    ).matches
  }

  toggle() {
    // Skip JS when the info icon is hidden via CSS (pure hover/fine-pointer
    // desktops). Hybrid touch/hover devices still get the JS tooltip.
    if (this.iconHiddenByCSS) return

    const isHidden = this.contentTarget.classList.toggle("hidden")
    const expanded = !isHidden
    this.#updateAria(expanded)

    if (expanded) {
      this.#positionTooltip()
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

  #positionTooltip() {
    const button = this.element.querySelector("button[aria-controls]")
    if (!button) return

    const rect = button.getBoundingClientRect()
    this.contentTarget.style.top = `${rect.bottom + 4}px`
    this.contentTarget.style.left = `${rect.left}px`
  }

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
