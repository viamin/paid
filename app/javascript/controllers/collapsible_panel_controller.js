import { Controller } from "@hotwired/stimulus"

const COLLAPSED_CLASSES = ["max-h-0", "overflow-hidden", "opacity-0"]
const EXPANDED_CLASSES = ["max-h-[2000px]", "opacity-100"]

export default class extends Controller {
  static targets = ["checkbox", "panel"]

  connect() {
    this.toggle()
  }

  toggle() {
    const expanded = this.checkboxTarget.checked

    this.checkboxTarget.setAttribute("aria-expanded", expanded.toString())
    this.panelTarget.hidden = !expanded
    this.panelTarget.setAttribute("aria-hidden", (!expanded).toString())

    COLLAPSED_CLASSES.forEach((className) => {
      this.panelTarget.classList.toggle(className, !expanded)
    })

    EXPANDED_CLASSES.forEach((className) => {
      this.panelTarget.classList.toggle(className, expanded)
    })
  }
}
