import { Controller } from "@hotwired/stimulus"

// Keeps the inbox list/detail panes in sync with the current mobile
// master-detail state while leaving desktop split-pane rendering intact.
export default class extends Controller {
  static targets = ["list", "detailSection"]
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

  open() {
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

  show(element) {
    element.classList.remove("hidden")
    element.classList.add("block")
  }

  hide(element) {
    element.classList.remove("block")
    element.classList.add("hidden")
  }
}
