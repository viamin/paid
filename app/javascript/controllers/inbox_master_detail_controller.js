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
  static targets = ["list", "detailSection", "row", "copyStatus"]
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
    this.boundReloadCollection = this.reloadCollection.bind(this)
    window.addEventListener("popstate", this.boundReloadCollection)
    this.syncPaneVisibility()
  }

  disconnect() {
    this.mediaQuery?.removeEventListener("change", this.boundResetOnDesktop)
    window.removeEventListener("popstate", this.boundReloadCollection)
  }

  detailOpenValueChanged() {
    this.syncPaneVisibility()
  }

  // @spec OPERATOR-INBOX-025
  open(event) {
    // The route changes on selection now, but we still update the mobile
    // pane state and row highlight immediately so the click feels responsive
    // before the navigation completes.
    const placeholder = this.detailSectionTarget.querySelector("[data-inbox-detail-placeholder]")
    if (placeholder) placeholder.textContent = "Loading item…"
    this.highlightRow(event.currentTarget)
    this.detailOpenValue = true
  }

  // @spec OPERATOR-INBOX-026
  async copyLink(event) {
    const path = event.currentTarget.dataset.inboxMasterDetailCopyLinkUrl
    if (!path) return

    const url = new URL(path, window.location.origin).toString()

    try {
      await window.navigator.clipboard.writeText(url)
      this.announceCopyResult("Link copied.")
    } catch (clipboardError) {
      try {
        this.copyWithSelection(url)
        this.announceCopyResult("Link copied.")
      } catch (fallbackError) {
        this.reportCopyFailure(clipboardError, fallbackError)
        this.announceCopyResult("Copy failed.")
      }
    }
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

  // A frame navigation with `advance` changes the history URL while keeping
  // this collection document alive. On Back, the browser restores the URL but
  // not the frame's earlier HTML, so reload the collection and let the server
  // select its canonical first entry again.
  // @spec OPERATOR-INBOX-026
  reloadCollection() {
    if (window.location.pathname === this.element.dataset.inboxCollectionPath) {
      window.location.reload()
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
      // The inbox list partial paints `hover:bg-gray-50` on every
      // non-selected row at render time. Keep it mutually exclusive with
      // the active-row class set so the newly-selected row doesn't keep a
      // gray hover affordance and the just-deselected row doesn't lose it.
      row.classList.toggle("hover:bg-gray-50", !selected)
    })
  }

  copyWithSelection(url) {
    const selection = document.createElement("textarea")
    selection.value = url
    selection.setAttribute("readonly", "")
    selection.classList.add("sr-only")
    const previouslyFocused = document.activeElement
    document.body.append(selection)
    selection.select()

    try {
      if (document.execCommand("copy") !== true) throw new Error("Clipboard copy failed")
    } finally {
      selection.remove()
      previouslyFocused?.focus()
    }
  }

  announceCopyResult(message) {
    if (this.hasCopyStatusTarget) this.copyStatusTarget.textContent = message
  }

  reportCopyFailure(clipboardError, fallbackError) {
    window.console?.warn(
      "inbox-master-detail#copyLink: clipboard write failed",
      { clipboardError, fallbackError }
    )
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
