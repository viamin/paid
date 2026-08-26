import { Controller } from "@hotwired/stimulus"

// Tracks whether the inbox detail pane is currently the visible pane on
// mobile. Visibility is driven by Tailwind responsive classes rendered on
// the server (`view=detail` URL param); the controller exists so click
// handlers can sync the in-page state when list links are followed inside
// the inbox-detail Turbo frame, and so the state survives across navigations
// inside the frame.
export default class extends Controller {
  static values = { detailOpen: Boolean }

  connect() {
    this.mediaQuery = window.matchMedia("(min-width: 1024px)")
    this.boundResetOnDesktop = this.resetOnDesktop.bind(this)
    this.mediaQuery.addEventListener("change", this.boundResetOnDesktop)
  }

  disconnect() {
    this.mediaQuery.removeEventListener("change", this.boundResetOnDesktop)
  }

  open() {
    this.detailOpenValue = true
  }

  close() {
    this.detailOpenValue = false
  }

  resetOnDesktop(event) {
    if (event.matches) this.detailOpenValue = false
  }
}