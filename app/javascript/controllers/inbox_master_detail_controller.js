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
    // The route changes on selection now, but we still update the mobile
    // pane state and row highlight immediately so the click feels responsive
    // before the navigation completes.
    this.highlightRow(event.currentTarget)
    this.detailOpenValue = true
  }

  close() {
    this.detailOpenValue = false
  }

  resetOnDesktop(event) {
    if (event.matches) {
      this.detailOpenValue = false
    } else {
      this.syncPaneVisibility()
    }
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
