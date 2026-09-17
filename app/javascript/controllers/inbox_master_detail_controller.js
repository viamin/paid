import { Controller } from "@hotwired/stimulus"

// Keeps the inbox list/detail panes in sync with the current mobile
// master-detail state while leaving desktop split-pane rendering intact.
//
// The selected-row class set is sourced from each row's
// `data-active-classes` attribute, which the inbox list partial sets from
// `MasterDetailLayoutHelper#master_detail_active_row_classes`. The
// `chat-session-list` controller reads the same attribute, so a future
// tweak to the shared active-row treatment lives in one place.
// @spec OPERATOR-INBOX-003 @spec OPERATOR-INBOX-003A @spec LIST-DETAIL-003
export default class extends Controller {
  static targets = ["list", "detailSection", "row"]
  static values = { detailOpen: Boolean }

  // @spec OPERATOR-INBOX-003A
  initialize() {
    // Stimulus can invoke value-change callbacks (detailOpenValueChanged)
    // before connect() runs, so the media query must exist from the moment
    // the controller is instantiated, not just once connected.
    this.mediaQuery = window.matchMedia("(min-width: 1024px)")
    this.boundResetOnDesktop = this.resetOnDesktop.bind(this)
  }

  connect() {
    this.mediaQuery.addEventListener("change", this.boundResetOnDesktop)
    this.syncPaneVisibility()
  }

  disconnect() {
    this.mediaQuery?.removeEventListener("change", this.boundResetOnDesktop)
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
      const selected = row === clicked
      const activeClasses = (row.dataset.activeClasses || "").split(/\s+/).filter(Boolean)
      activeClasses.forEach((cls) => row.classList.toggle(cls, selected))
    })
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
