import { Controller } from "@hotwired/stimulus"

// Wraps a group of native <details> nav disclosures. Native <details> gives
// us open/close for free, but not outside-click dismissal, Escape dismissal,
// or closing sibling disclosures when one opens — this controller restores
// that behavior without reintroducing the old dropdown_controller's manual
// open-state bookkeeping.
export default class extends Controller {
  static targets = ["disclosure"]

  connect() {
    this.boundCloseOnOutsideClick = this.closeOnOutsideClick.bind(this)
    this.boundCloseOnEscape = this.closeOnEscape.bind(this)
    this.boundCloseAll = this.closeAll.bind(this)
    this.boundCloseSiblings = this.closeSiblings.bind(this)

    document.addEventListener("click", this.boundCloseOnOutsideClick)
    document.addEventListener("keydown", this.boundCloseOnEscape)
    document.addEventListener("turbo:before-visit", this.boundCloseAll)
    this.disclosureTargets.forEach((disclosure) => disclosure.addEventListener("toggle", this.boundCloseSiblings))
  }

  disconnect() {
    document.removeEventListener("click", this.boundCloseOnOutsideClick)
    document.removeEventListener("keydown", this.boundCloseOnEscape)
    document.removeEventListener("turbo:before-visit", this.boundCloseAll)
    this.disclosureTargets.forEach((disclosure) => disclosure.removeEventListener("toggle", this.boundCloseSiblings))
  }

  closeSiblings(event) {
    if (!event.target.open) return

    this.disclosureTargets.forEach((disclosure) => {
      if (disclosure !== event.target) disclosure.open = false
    })
  }

  closeOnOutsideClick(event) {
    this.disclosureTargets.forEach((disclosure) => {
      if (disclosure.open && !disclosure.contains(event.target)) disclosure.open = false
    })
  }

  closeOnEscape(event) {
    if (event.key !== "Escape") return

    this.closeAll()
  }

  closeAll() {
    this.disclosureTargets.forEach((disclosure) => {
      disclosure.open = false
    })
  }
}
