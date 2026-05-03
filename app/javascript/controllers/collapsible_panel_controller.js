import { Controller } from "@hotwired/stimulus"

const COLLAPSED_CLASSES = ["max-h-0", "overflow-hidden", "opacity-0"]
const EXPANDED_CLASSES = ["max-h-[2000px]", "opacity-100"]

export default class extends Controller {
  static targets = ["checkbox", "panel"]

  connect() {
    this.applyState()
  }

  toggle() {
    this.applyState()
  }

  applyState() {
    const expanded = this.checkboxTarget.checked

    this.checkboxTarget.setAttribute("aria-expanded", expanded.toString())
    this.panelTarget.setAttribute("aria-hidden", (!expanded).toString())
    this.panelTarget.inert = !expanded

    COLLAPSED_CLASSES.forEach((cls) => this.panelTarget.classList.toggle(cls, !expanded))
    EXPANDED_CLASSES.forEach((cls) => this.panelTarget.classList.toggle(cls, expanded))
  }
}
