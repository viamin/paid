import { Controller } from "@hotwired/stimulus"

// Manages a mobile-only tappable tooltip (info icon).
// Desktop tooltips use the native HTML title attribute.
export default class extends Controller {
  static targets = ["content"]

  toggle(event) {
    event.stopPropagation()
    this.contentTarget.classList.toggle("hidden")
  }

  hide(event) {
    if (!this.element.contains(event.target)) {
      this.contentTarget.classList.add("hidden")
    }
  }

  connect() {
    this.boundHide = this.hide.bind(this)
    document.addEventListener("click", this.boundHide)
  }

  disconnect() {
    document.removeEventListener("click", this.boundHide)
  }
}
