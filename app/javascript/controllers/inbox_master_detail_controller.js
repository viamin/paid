import { Controller } from "@hotwired/stimulus"

// Keeps the inbox list/detail panes in sync with the current mobile
// master-detail state while leaving desktop split-pane rendering intact.
export default class extends Controller {
  static targets = ["list", "detailSection", "row"]
  static values = { detailOpen: Boolean }

  connect() {
    this.mediaQuery = window.matchMedia("(min-width: 1024px)")
    this.boundResetOnDesktop = this.resetOnDesktop.bind(this)
    this.mediaQuery.addEventListener("change", this.boundResetOnDesktop)
    this.syncPaneVisibility()
  }

  disconnect() {
    this.mediaQuery.removeEventListener("change", this.boundResetOnDesktop)
  }

  detailOpenValueChanged() {
    this.syncPaneVisibility()
  }

  open(event) {
    // List row links navigate inside a Turbo Frame, so the list partial does
    // not re-render with the new selection. Move the active-row highlight
    // here so the visual selection follows the click without waiting for a
    // full-page reload.
    this.highlightRow(event.currentTarget)
    this.detailOpenValue = true
  }

  close() {
    this.detailOpenValue = false
  }

  resetOnDesktop(event) {
    if (event.matches) this.detailOpenValue = false
  }

  syncPaneVisibility() {
    if (!this.hasListTarget || !this.hasDetailSectionTarget) return

    if (this.mediaQuery.matches) {
      this.show(this.listTarget)
      this.show(this.detailSectionTarget)
      return
    }

    if (this.detailOpenValue) {
      this.hide(this.listTarget)
      this.show(this.detailSectionTarget)
    } else {
      this.show(this.listTarget)
      this.hide(this.detailSectionTarget)
    }
  }

  highlightRow(clicked) {
    if (!this.hasListTarget || !clicked) return

    this.rowTargets.forEach((row) => {
      row.classList.remove("bg-indigo-50")
      row.classList.add("hover:bg-gray-50")
    })

    clicked.classList.remove("hover:bg-gray-50")
    clicked.classList.add("bg-indigo-50")
  }

  show(element) {
    element.classList.remove("hidden")
    element.classList.add("block")
  }

  hide(element) {
    element.classList.remove("block")
    element.classList.add("hidden")
  }
}
